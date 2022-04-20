import
  std/tables,
  test_env,
  stew/byteutils,
  chronicles,
  unittest2,
  nimcrypto,
  chronos,
  ./helper,
  ../../../nimbus/transaction,
  ../../../nimbus/rpc/rpc_types,
  ../../../nimbus/merge/mergeutils

type
  TestSpec* = object
    name*: string
    run*: proc(t: TestEnv): TestStatus
    ttd*: int64

const
  prevRandaoContractAddr = hexToByteArray[20]("0000000000000000000000000000000000000316")

template testCond(expr: untyped) =
  if not (expr):
    return TestStatus.Failed

template testCond(expr, body: untyped) =
  if not (expr):
    body
    return TestStatus.Failed

# Invalid Terminal Block in ForkchoiceUpdated:
# Client must reject ForkchoiceUpdated directives if the referenced HeadBlockHash does not meet the TTD requirement.
proc invalidTerminalBlockForkchoiceUpdated(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let
    gHash = Web3BlockHash t.gHeader.blockHash.data
    forkchoiceState = ForkchoiceStateV1(
      headBlockHash:      gHash,
      safeBlockHash:      gHash,
      finalizedBlockHash: gHash,
    )

  let res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceState)

  # Execution specification:
  # {payloadStatus: {status: INVALID_TERMINAL_BLOCK, latestValidHash: null, validationError: errorMessage | null}, payloadId: null}
  # either obtained from the Payload validation process or as a result of validating a PoW block referenced by forkchoiceState.headBlockHash
  testCond res.isOk

  let s = res.get()
  testCond s.payloadStatus.status == PayloadExecutionStatus.invalid_terminal_block
  testCond s.payloadStatus.latestValidHash.isNone
  testCond s.payloadId.isNone

  # ValidationError is not validated since it can be either null or a string message

# Invalid GetPayload Under PoW: Client must reject GetPayload directives under PoW.
proc invalidGetPayloadUnderPoW(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # We start in PoW and try to get an invalid Payload, which should produce an error but nothing should be disrupted.
  let id = PayloadID [1.byte, 2,3,4,5,6,7,8]
  let res = t.rpcClient.getPayloadV1(id)
  testCond res.isErr

# Invalid Terminal Block in NewPayload:
# Client must reject NewPayload directives if the referenced ParentHash does not meet the TTD requirement.
proc invalidTerminalBlockNewPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let gBlock = t.gHeader
  let payload = ExecutableData(
    parentHash:   gBlock.blockHash,
    stateRoot:    gBlock.stateRoot,
    receiptsRoot: BLANK_ROOT_HASH,
    number:       1,
    gasLimit:     gBlock.gasLimit,
    gasUsed:      0,
    timestamp:    gBlock.timestamp + 1.seconds,
    baseFeePerGas:gBlock.baseFee
  )
  let hashedPayload = customizePayload(payload, CustomPayload())
  let res = t.rpcClient.newPayloadV1(hashedPayload)

  # Execution specification:
  # {status: INVALID_TERMINAL_BLOCK, latestValidHash: null, validationError: errorMessage | null}
  # if terminal block conditions are not satisfied
  testCond res.isOk

  let s = res.get()
  testCond s.status == PayloadExecutionStatus.invalid_terminal_block
  testCond s.latestValidHash.isNone

proc unknownHeadBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  var randomHash: Hash256
  testCond nimcrypto.randomBytes(randomHash.data) == 32

  let clMock = t.clMock
  let forkchoiceStateUnknownHeadHash = ForkchoiceStateV1(
    headBlockHash:      BlockHash randomHash.data,
    safeBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
    finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash,
  )

  var res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash)
  testCond res.isOk

  let s = res.get()
  # Execution specification::
  # - {payloadStatus: {status: SYNCING, latestValidHash: null, validationError: null}, payloadId: null}
  #   if forkchoiceState.headBlockHash references an unknown payload or a payload that can't be validated
  #   because requisite data for the validation is missing
  testCond s.payloadStatus.status == PayloadExecutionStatus.syncing

  # Test again using PayloadAttributes, should also return SYNCING and no PayloadID
  let timestamp = uint64 clMock.latestExecutedPayload.timestamp
  let payloadAttr = PayloadAttributesV1(
    timestamp: Quantity(timestamp + 1)
  )

  res = t.rpcClient.forkchoiceUpdatedV1(forkchoiceStateUnknownHeadHash, some(payloadAttr))
  testCond res.isOk
  testCond s.payloadStatus.status == PayloadExecutionStatus.syncing
  testCond s.payloadId.isNone

proc unknownSafeBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomSafeBlockHash: Hash256
      doAssert nimcrypto.randomBytes(randomSafeBlockHash.data) == 32

      # Send forkchoiceUpdated with random SafeBlockHash
      let forkchoiceStateUnknownSafeHash = ForkchoiceStateV1(
        headBlockHash:      clMock.latestExecutedPayload.blockHash,
        safeBlockHash:      BlockHash randomSafeBlockHash.data,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash,
      )
      # Execution specification:
      # - This value MUST be either equal to or an ancestor of headBlockHash
      let res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownSafeHash)
      return res.isErr
  ))

  testCond produceSingleBlockRes

proc unknownFinalizedBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  let produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been broadcast
    onNewPayloadBroadcast: proc(): bool =
      # Generate a random SafeBlock hash
      var randomFinalBlockHash: Hash256
      doAssert nimcrypto.randomBytes(randomFinalBlockHash.data) == 32

      # Send forkchoiceUpdated with random SafeBlockHash
      let forkchoiceStateUnknownFinalizedHash = ForkchoiceStateV1(
        headBlockHash:      clMock.latestExecutedPayload.blockHash,
        safeBlockHash:      clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: BlockHash randomFinalBlockHash.data,
      )
      # Execution specification:
      # - This value MUST be either equal to or an ancestor of headBlockHash
      var res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownFinalizedHash)
      if res.isOk:
        return false

      # Test again using PayloadAttributes, should also return INVALID and no PayloadID
      let timestamp = uint64 clMock.latestExecutedPayload.timestamp
      let payloadAttr = PayloadAttributesV1(
        timestamp:  Quantity(timestamp + 1)
      )
      res = client.forkchoiceUpdatedV1(forkchoiceStateUnknownFinalizedHash, some(payloadAttr))
      return res.isErr
  ))

  testCond produceSingleBlockRes

proc preTTDFinalizedBlockHash(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let
    gHash = Web3BlockHash t.gHeader.blockHash.data
    forkchoiceState = ForkchoiceStateV1(
      headBlockHash:      gHash,
      safeBlockHash:      gHash,
      finalizedBlockHash: gHash,
    )
    client = t.rpcClient
    clMock = t.clMock

  var res = client.forkchoiceUpdatedV1(forkchoiceState)
  # TBD: Behavior on this edge-case is undecided, as behavior of the Execution client
  # if not defined on re-orgs to a point before the latest finalized block.

  res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
  testCond res.isOk
  let s = res.get()
  testCond s.payloadStatus.status == PayloadExecutionStatus.valid

proc badHashOnExecPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  type
    Shadow = ref object
      hash: Hash256

  let clMock = t.clMock
  let client = t.rpcClient
  let shadow = Shadow()

  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      var alteredPayload = clMock.latestPayloadBuilt
      var invalidPayloadHash = hash256(alteredPayload.blockHash)
      let lastByte = int invalidPayloadHash.data[^1]
      invalidPayloadHash.data[^1] = byte(not lastByte)
      shadow.hash = invalidPayloadHash
      alteredPayload.blockHash = BlockHash invalidPayloadHash.data
      let res = client.newPayloadV1(alteredPayload)
      # Execution specification::
      # - {status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null} if the blockHash validation has failed
      if res.isErr:
        return false
      let s = res.get()
      s.status == PayloadExecutionStatus.invalid_block_hash
  ))
  testCond produceSingleBlockRes

  # Lastly, attempt to build on top of the invalid payload
  produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      let payload = toExecutableData(clMock.latestPayloadBuilt)
      let alteredPayload = customizePayload(payload, CustomPayload(
        parentHash: some(shadow.hash),
      ))
      let res = client.newPayloadV1(alteredPayload)
      if res.isErr:
        return false
      # Response status can be ACCEPTED (since parent payload could have been thrown out by the client)
      # or INVALID (client still has the payload and can verify that this payload is incorrectly building on top of it),
      # but a VALID response is incorrect.
      let s = res.get()
      s.status != PayloadExecutionStatus.valid
  ))
  testCond produceSingleBlockRes

proc parentHashOnExecPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after the new payload has been obtained
    onGetPayload: proc(): bool =
      # Alter hash on the payload and send it to client, should produce an error
      var alteredPayload = clMock.latestPayloadBuilt
      alteredPayload.blockHash = alteredPayload.parentHash
      let res = client.newPayloadV1(alteredPayload)
      if res.isErr:
        return false
      # Execution specification::
      # - {status: INVALID_BLOCK_HASH, latestValidHash: null, validationError: null} if the blockHash validation has failed
      let s = res.get()
      s.status == PayloadExecutionStatus.invalid_block_hash
  ))
  testCond produceSingleBlockRes

proc invalidPayloadTestCaseGen(payloadField: string): proc (t: TestEnv): TestStatus =
  return proc (t: TestEnv): TestStatus =
    result = TestStatus.SKIPPED

# Test to verify Block information available at the Eth RPC after NewPayload
proc blockStatusExecPayload(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # TODO: Ideally, we would need to testCond that the newPayload returned VALID
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      # Latest block header available via Eth RPC should not have changed at this point
      if lastHash == clMock.latestExecutedPayload.blockHash or
        lastHash != clMock.latestForkchoice.headBlockHash or
        lastHash != clMock.latestForkchoice.safeBlockHash or
        lastHash != clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header incorrect after newPayload", hash=lastHash.toHex
        return false

      let nRes = client.blockNumber()
      if nRes.isErr:
        error "Unable to get latest block number", msg=nRes.error
        return false

      # Latest block number available via Eth RPC should not have changed at this point
      let latestNumber = nRes.get
      if latestNumber != clMock.latestFinalizedNumber:
        error "latest block number incorrect after newPayload",
          expected=clMock.latestFinalizedNumber,
          get=latestNumber
        return false

      return true
  ))
  testCond produceSingleBlockRes

proc blockStatusHeadBlock(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onHeadBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash == clMock.latestForkchoice.safeBlockHash or
         lastHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match HeadBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  testCond produceSingleBlockRes

proc blockStatusSafeBlock(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onSafeBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash != clMock.latestForkchoice.safeBlockHash or
         lastHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match SafeBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  testCond produceSingleBlockRes

proc blockStatusFinalizedBlock(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onFinalizedBlockForkchoiceBroadcast: proc(): bool =
      var lastHeader: EthBlockHeader
      var hRes = client.latestHeader(lastHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      let lastHash = BlockHash lastHeader.blockHash.data
      if lastHash != clMock.latestForkchoice.headBlockHash or
         lastHash != clMock.latestForkchoice.safeBlockHash or
         lastHash != clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match FinalizedBlock hash", hash=lastHash.toHex
        return false
      return true
  ))
  testCond produceSingleBlockRes

proc blockStatusReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a forkchoice with new HeadBlockHash has been broadcasted
    onHeadBlockForkchoiceBroadcast: proc(): bool =
      # Verify the client is serving the latest HeadBlock
      var currHeader: EthBlockHeader
      var hRes = client.latestHeader(currHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      var currHash = BlockHash currHeader.blockHash.data
      if currHash != clMock.latestForkchoice.headBlockHash or
         currHash == clMock.latestForkchoice.safeBlockHash or
         currHash == clMock.latestForkchoice.finalizedBlockHash:
        error "latest block header doesn't match HeadBlock hash", hash=currHash.toHex
        return false

      # Reorg back to the previous block (FinalizedBlock)
      let reorgForkchoice = ForkchoiceStateV1(
        headBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
        safeBlockHash:      clMock.latestForkchoice.finalizedBlockHash,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash
      )

      var res = client.forkchoiceUpdatedV1(reorgForkchoice)
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      var s = res.get()
      if s.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Incorrect status returned after a HeadBlockHash reorg", status=s.payloadStatus.status
        return false

      if s.payloadStatus.latestValidHash.isNone:
        error "Cannot get latestValidHash from payloadStatus"
        return false

      var latestValidHash = s.payloadStatus.latestValidHash.get
      if latestValidHash != reorgForkchoice.headBlockHash:
        error "Incorrect latestValidHash returned after a HeadBlockHash reorg",
          expected=reorgForkchoice.headBlockHash.toHex,
          get=latestValidHash.toHex
        return false

      # testCond that we reorg to the previous block
      hRes = client.latestHeader(currHeader)
      if hRes.isErr:
        error "unable to get latest header", msg=hRes.error
        return false

      currHash = BlockHash currHeader.blockHash.data
      if currHash != reorgForkchoice.headBlockHash:
        error "`latest` block hash doesn't match reorg hash",
          expected=reorgForkchoice.headBlockHash.toHex,
          get=currHash.toHex
        return false

      # Send the HeadBlock again to leave everything back the way it was
      res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      s = res.get()
      if s.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Incorrect status returned after a HeadBlockHash reorg",
          status=s.payloadStatus.status
        return false

      if s.payloadStatus.latestValidHash.isNone:
        error "Cannot get latestValidHash from payloadStatus"
        return false

      latestValidHash = s.payloadStatus.latestValidHash.get
      if latestValidHash != clMock.latestForkchoice.headBlockHash:
        error "Incorrect latestValidHash returned after a HeadBlockHash reorg",
          expected=clMock.latestForkchoice.headBlockHash.toHex,
          get=latestValidHash.toHex
        return false
      return true
  ))
  testCond produceSingleBlockRes

proc reExecPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until this client catches up with latest PoS
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # How many Payloads we are going to re-execute
  var payloadReExecCount = 10

  # Create those blocks
  let produceBlockRes = t.clMock.produceBlocks(payloadReExecCount, BlockProcessCallbacks())
  testCond produceBlockRes

  # Re-execute the payloads
  let client = t.rpcClient
  var hRes = client.blockNumber()
  testCond hRes.isOk:
    error "unable to get blockNumber", msg=hRes.error

  let lastBlock = int(hRes.get)
  info "Started re-executing payloads at block", number=lastBlock

  let
    clMock = t.clMock
    start  = lastBlock - payloadReExecCount + 1

  for i in start..lastBlock:
    if clMock.executedPayloadHistory.hasKey(uint64 i):
      let payload = clMock.executedPayloadHistory[uint64 i]
      let res = client.newPayloadV1(payload)
      testCond res.isOk:
        error "FAIL (%s): Unable to re-execute valid payload", msg=res.error

      let s = res.get()
      testCond s.status == PayloadExecutionStatus.valid:
        error "Unexpected status after re-execute valid payload", status=s.status
    else:
      testCond true:
        error "(test issue) Payload does not exist", index=i

proc multipleNewCanonicalPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let clMock = t.clMock
  let client = t.rpcClient
  var produceSingleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    # Run test after a new payload has been obtained
    onGetPayload: proc(): bool =
      let payloadCount = 80
      let basePayload = toExecutableData(clMock.latestPayloadBuilt)
      var newPrevRandao: Hash256

      # Fabricate and send multiple new payloads by changing the PrevRandao field
      for i in 0..<payloadCount:
        doAssert nimcrypto.randomBytes(newPrevRandao.data) == 32
        let newPayload = customizePayload(basePayload, CustomPayload(
          prevRandao: some(newPrevRandao)
        ))

        let res = client.newPayloadV1(newPayload)
        if res.isErr:
          error "Unable to send new valid payload extending canonical chain", msg=res.error
          return false

        let s = res.get()
        if s.status != PayloadExecutionStatus.valid:
          error "Unexpected status after trying to send new valid payload extending canonical chain",
            status=s.status
          return false
      return true
  ))
  # At the end the CLMocker continues to try to execute fcU with the original payload, which should not fail
  testCond produceSingleBlockRes

proc outOfOrderPayloads(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # First prepare payloads on a first client, which will also contain multiple transactions

  # We will be also verifying that the transactions are correctly interpreted in the canonical chain,
  # prepare a random account to receive funds.
  const
    amountPerTx  = 1000.u256
    txPerPayload = 20
    payloadCount = 10

  var recipient: EthAddress
  doAssert nimcrypto.randomBytes(recipient) == 20

  let clMock = t.clMock
  let client = t.rpcClient
  var produceBlockRes = clMock.produceBlocks(payloadCount, BlockProcessCallbacks(
    # We send the transactions after we got the Payload ID, before the CLMocker gets the prepared Payload
    onPayloadProducerSelected: proc(): bool =
      for i in 0..<txPerPayload:
        let tx = t.makeNextTransaction(recipient, amountPerTx)
        let res = client.sendTransaction(tx)
        if res.isErr:
          error "Unable to send transaction"
          return false
      return true
  ))
  testCond produceBlockRes

  let expectedBalance = amountPerTx * u256(payloadCount*txPerPayload)

  # testCond balance on this first client
  let balRes = client.balanceAt(recipient)
  testCond balRes.isOk:
    error "Error while getting balance of funded account"

  let bal = balRes.get()
  testCond expectedBalance == bal

  # TODO: this section need multiple client

proc transactionReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  # Create transactions that modify the state in order to testCond after the reorg.
  const
    txCount      = 5
    contractAddr = hexToByteArray[20]("0000000000000000000000000000000000000317")

  var
    receipts: array[txCount, rpc_types.ReceiptObject]
    txs: array[txCount, Transaction]

  let
    client = t.rpcClient
    clMock = t.clMock

  for i in 0..<txCount:
    # Data is the key where a `1` will be stored
    let data = i.u256
    let tx = t.makeNextTransaction(contractAddr, 0.u256, data.toBytesBE)
    txs[i] = tx

    # Send the transaction
    let res = client.sendTransaction(tx)
    testCond res.isOk:
      error "Unable to send transaction", msg=res.error

    # Produce the block containing the transaction
    var blockRes = clMock.produceSingleBlock(BlockProcessCallbacks())
    testCond blockRes

    # Get the receipt
    let rr = client.txReceipt(rlpHash(tx))
    testCond rr.isOk:
      error "Unable to obtain transaction receipt", msg=rr.error

    receipts[i] = rr.get()

  for i in 0..<txCount:
    # The sstore contract stores a `1` to key specified in data
    let storageKey = i.u256

    var rr = client.storageAt(contractAddr, storageKey)
    testCond rr.isOk:
      error "Could not get storage", msg=rr.error

    let valueWithTxApplied = rr.get()
    testCond valueWithTxApplied == 1.u256
    if valueWithTxApplied != 1.u256:
      error "Expected storage not set after transaction", valueWithTxApplied
      return

    # Get value at a block before the tx was included
    let number = UInt256.fromHex(receipts[i].blockNumber.string).truncate(uint64)
    var reorgBlock: EthBlockHeader
    let blockRes = client.headerByNumber(number - 1, reorgBlock)
    rr = client.storageAt(contractAddr, storageKey, reorgBlock.blockNumber)
    testCond rr.isOk:
      error "could not get storage", msg= rr.error

    let valueWithoutTxApplied = rr.get()
    testCond valueWithoutTxApplied == 0.u256:
      error "Storage not unset before transaction!", valueWithoutTxApplied

    # Re-org back to a previous block where the tx is not included using forkchoiceUpdated
    let rHash = Web3BlockHash reorgBlock.blockHash.data
    let reorgForkchoice = ForkchoiceStateV1(
      headBlockHash:      rHash,
      safeBlockHash:      rHash,
      finalizedBlockHash: rHash,
    )

    var res = client.forkchoiceUpdatedV1(reorgForkchoice)
    testCond res.isOk:
      error "Could not send forkchoiceUpdatedV1", msg=res.error

    var s = res.get()
    testCond s.payloadStatus.status == PayloadExecutionStatus.valid:
      error "Could not send forkchoiceUpdatedV1", status=s.payloadStatus.status

    # testCond storage again using `latest`, should be unset
    rr = client.storageAt( contractAddr, storageKey)
    testCond rr.isOk:
      error "could not get storage", msg= rr.error

    let valueAfterReOrgBeforeTxApplied = rr.get()
    testCond valueAfterReOrgBeforeTxApplied == 0.u256:
      error "Storage not unset after re-org", valueAfterReOrgBeforeTxApplied

    # Re-send latest forkchoice to test next transaction
    res = client.forkchoiceUpdatedV1(clMock.latestForkchoice)
    testCond res.isOk:
      error "Could not send forkchoiceUpdatedV1", msg=res.error

    s = res.get()
    testCond s.payloadStatus.status == PayloadExecutionStatus.valid:
      error "Could not send forkchoiceUpdatedV1", status=s.payloadStatus.status

proc testCondPrevRandaoValue(t: TestEnv, expectedPrevRandao: Hash256, blockNumber: uint64): bool =
  let storageKey = blockNumber.u256
  let client = t.rpcClient

  let res = client.storageAt(prevRandaoContractAddr, storageKey)
  if res.isErr:
    error "Unable to get storage", msg=res.error
    return false

  let opcodeValueAtBlock = Hash256(data: res.get().toBytesBE)
  if opcodeValueAtBlock != expectedPrevRandao:
    error "Storage does not match prevRandao",
      expected=expectedPrevRandao.data.toHex,
      get=opcodeValueAtBlock.data.toHex
    return false
  true

proc sidechainReorg(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test
  let produce5BlockRes = t.clMock.produceBlocks(5, BlockProcessCallbacks())
  testCond produce5BlockRes

  let
    client = t.rpcClient
    clMock = t.clMock

  # Produce two payloads, send fcU with first payload, testCond transaction outcome, then reorg, testCond transaction outcome again

  # This single transaction will change its outcome based on the payload
  let tx = t.makeNextTransaction(prevRandaoContractAddr, 0.u256)
  let rr = client.sendTransaction(tx)
  testCond rr.isOk:
    error "Unable to send transaction", msg=rr.error

  let singleBlockRes = clMock.produceSingleBlock(BlockProcessCallbacks(
    onNewPayloadBroadcast: proc(): bool =
      # At this point the CLMocker has a payload that will result in a specific outcome,
      # we can produce an alternative payload, send it, fcU to it, and verify the changes
      var alternativePrevRandao: Hash256
      doAssert nimcrypto.randomBytes(alternativePrevRandao.data) == 32

      let timestamp = Quantity toUnix(clMock.latestFinalizedHeader.timestamp + 1.seconds)
      let payloadAttributes = PayloadAttributesV1(
        timestamp:             timestamp,
        prevRandao:            FixedBytes[32] alternativePrevRandao.data,
        suggestedFeeRecipient: Address clMock.nextFeeRecipient,
      )

      var res = client.forkchoiceUpdatedV1(clMock.latestForkchoice, some(payloadAttributes))
      if res.isErr:
        error "Could not send forkchoiceUpdatedV1", msg=res.error
        return false

      let s = res.get()
      let rr = client.getPayloadV1(s.payloadID.get())
      if rr.isErr:
        error "Could not get alternative payload", msg=rr.error
        return false

      let alternativePayload = rr.get()
      if alternativePayload.transactions.len == 0:
        error "alternative payload does not contain the prevRandao opcode tx"
        return false

      let rx = client.newPayloadV1(alternativePayload)
      if rx.isErr:
        error "Could not send alternative payload", msg=rx.error
        return false

      let alternativePayloadStatus = rx.get()
      if alternativePayloadStatus.status != PayloadExecutionStatus.valid:
        error "Alternative payload response returned Status!=VALID",
          status=alternativePayloadStatus.status
        return false

      # We sent the alternative payload, fcU to it
      let alternativeHeader = toBlockHeader(alternativePayload)
      let rHash = BlockHash alternativeHeader.blockHash.data
      let alternativeFcU = ForkchoiceStateV1(
        headBlockHash:      rHash,
        safeBlockHash:      clMock.latestForkchoice.safeBlockHash,
        finalizedBlockHash: clMock.latestForkchoice.finalizedBlockHash
      )

      res = client.forkchoiceUpdatedV1(alternativeFcU)
      if res.isErr:
        error "Could not send alternative fcU", msg=res.error
        return false

      let alternativeFcUResp = res.get()
      if alternativeFcUResp.payloadStatus.status != PayloadExecutionStatus.valid:
        error "Alternative fcU response returned Status!=VALID",
          status=alternativeFcUResp.payloadStatus.status
        return false

      # PrevRandao should be the alternative prevRandao we sent
      return testCondPrevRandaoValue(t, alternativePrevRandao, uint64 alternativePayload.blockNumber)
  ))

  testCond singleBlockRes
  # The reorg actually happens after the CLMocker continues,
  # verify here that the reorg was successful
  let latestBlockNum = cLMock.latestFinalizedNumber.uint64
  testCond testCondPrevRandaoValue(t, clMock.prevRandaoHistory[latestBlockNum], latestBlockNum)

proc suggestedFeeRecipient(t: TestEnv): TestStatus =
  result = TestStatus.OK

  # Wait until TTD is reached by this client
  let ok = waitFor t.clMock.waitForTTD()
  testCond ok

  # Amount of transactions to send
  const
    txCount = 20

  # Verify that, in a block with transactions, fees are accrued by the suggestedFeeRecipient
  var feeRecipient: EthAddress
  testCond nimcrypto.randomBytes(feeRecipient) == 20

  let
    client = t.rpcClient
    clMock = t.clMock

  # Send multiple transactions
  for i in 0..<txCount:
    # Empty self tx
    let tx = t.makeNextTransaction(vaultAccountAddr, 0.u256)
    let res = client.sendTransaction(tx)
    testCond res.isOk:
      error "unable to send transaction", msg=res.error

  # Produce the next block with the fee recipient set
  clMock.nextFeeRecipient = feeRecipient
  testCond clMock.produceSingleBlock(BlockProcessCallbacks())

  # Calculate the fees and testCond that they match the balance of the fee recipient
  var blockIncluded: EthBlock
  var rr = client.latestBlock(blockIncluded)
  testCond rr.isOk:
    error "unable to get latest block", msg=rr.error

  testCond blockIncluded.txs.len == txCount:
    error "not all transactions were included in block",
      expected=txCount,
      get=blockIncluded.txs.len

  testCond blockIncluded.header.coinbase == feeRecipient:
    error "feeRecipient was not set as coinbase",
      expected=feeRecipient.toHex,
      get=blockIncluded.header.coinbase.toHex

  var feeRecipientFees = 0.u256
  for tx in blockIncluded.txs:
    let effGasTip = tx.effectiveGasTip(blockIncluded.header.fee)
    let tr = client.txReceipt(rlpHash(tx))
    testCond tr.isOk:
      error "unable to obtain receipt", msg=tr.error

    let rec = tr.get()
    let gasUsed = UInt256.fromHex(rec.gasUsed.string)
    feeRecipientFees = feeRecipientFees  + effGasTip.u256 * gasUsed

  var br = client.balanceAt(feeRecipient)
  testCond br.isOk

  var feeRecipientBalance = br.get()
  testCond feeRecipientBalance == feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

  # Produce another block without txns and get the balance again
  clMock.nextFeeRecipient = feeRecipient
  testCond clMock.produceSingleBlock(BlockProcessCallbacks())

  br = client.balanceAt(feeRecipient)
  testCond br.isOk
  feeRecipientBalance = br.get()
  testCond feeRecipientBalance == feeRecipientFees:
    error "balance does not match fees",
      feeRecipientBalance, feeRecipientFees

proc prevRandaoOpcodeTx(t: TestEnv): TestStatus =
  result = TestStatus.OK

  let
    client = t.rpcClient
    clMock = t.clMock
    tx = t.makeNextTransaction(prevRandaoContractAddr, 0.u256)
    rr = client.sendTransaction(tx)

  testCond rr.isOk:
    error "Unable to send transaction", msg=rr.error

  # Wait until TTD is reached by this client
  let ok = waitFor clMock.waitForTTD()
  testCond ok

  # Ideally all blocks up until TTD must have a DIFFICULTY opcode tx in it
  let nr = client.blockNumber()
  testCond nr.isOk:
    error "Unable to get latest block number", msg=nr.error

  let ttdBlockNumber = nr.get()

  # Start
  for i in ttdBlockNumber..ttdBlockNumber:
    # First testCond that the block actually contained the transaction
    var blk: EthBlock
    let res = client.blockByNumber(i, blk)
    testCond res.isOk:
      error "Unable to get block", msg=res.error

    testCond blk.txs.len > 0:
      error "(Test issue) no transactions went in block"

    let storageKey = i.u256
    let rr = client.storageAt(prevRandaoContractAddr, storageKey)
    testCond rr.isOk:
      error "Unable to get storage", msg=rr.error

    let opcodeValueAtBlock = rr.get()
    testCond opcodeValueAtBlock == 2.u256:
      error "Incorrect difficulty value in block",
        expect=2,
        get=opcodeValueAtBlock

proc postMergeSync(t: TestEnv): TestStatus =
  result = TestStatus.SKIPPED
  # TODO: need multiple client

const engineTestList* = [
  TestSpec(
    name: "Invalid Terminal Block in ForkchoiceUpdated",
    run: invalidTerminalBlockForkchoiceUpdated,
    ttd: 1000000
  ),
  TestSpec(
    name: "Invalid GetPayload Under PoW",
    run: invalidGetPayloadUnderPoW,
    ttd: 1000000
  ),
  TestSpec(
    name: "Invalid Terminal Block in NewPayload",
    run:  invalidTerminalBlockNewPayload,
    ttd:  1000000,
  ),
  TestSpec(
    name: "Unknown HeadBlockHash",
    run:  unknownHeadBlockHash,
  ),
  TestSpec(
    name: "Unknown SafeBlockHash",
    run:  unknownSafeBlockHash,
  ),
  TestSpec(
    name: "Unknown FinalizedBlockHash",
    run:  unknownFinalizedBlockHash,
  ),
  TestSpec(
    name: "Pre-TTD ForkchoiceUpdated After PoS Switch",
    run:  preTTDFinalizedBlockHash,
    ttd:  2,
  ),
  TestSpec(
    name: "Bad Hash on NewPayload",
    run:  badHashOnExecPayload,
  ),
  TestSpec(
    name: "ParentHash==BlockHash on NewPayload",
    run:  parentHashOnExecPayload,
  ),
  TestSpec(
    name: "Invalid ParentHash NewPayload",
    run:  invalidPayloadTestCaseGen("ParentHash"),
  ),
  TestSpec(
    name: "Invalid StateRoot NewPayload",
    run:  invalidPayloadTestCaseGen("StateRoot"),
  ),
  TestSpec(
    name: "Invalid ReceiptsRoot NewPayload",
    run:  invalidPayloadTestCaseGen("ReceiptsRoot"),
  ),
  TestSpec(
    name: "Invalid Number NewPayload",
    run:  invalidPayloadTestCaseGen("Number"),
  ),
  TestSpec(
    name: "Invalid GasLimit NewPayload",
    run:  invalidPayloadTestCaseGen("GasLimit"),
  ),
  TestSpec(
    name: "Invalid GasUsed NewPayload",
    run:  invalidPayloadTestCaseGen("GasUsed"),
  ),
  TestSpec(
    name: "Invalid Timestamp NewPayload",
    run:  invalidPayloadTestCaseGen("Timestamp"),
  ),
  TestSpec(
    name: "Invalid PrevRandao NewPayload",
    run:  invalidPayloadTestCaseGen("PrevRandao"),
  ),
  TestSpec(
    name: "Invalid Incomplete Transactions NewPayload",
    run:  invalidPayloadTestCaseGen("RemoveTransaction"),
  ),
  TestSpec(
    name: "Invalid Transaction Signature NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Signature"),
  ),
  TestSpec(
    name: "Invalid Transaction Nonce NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Nonce"),
  ),
  TestSpec(
    name: "Invalid Transaction GasPrice NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/GasPrice"),
  ),
  TestSpec(
    name: "Invalid Transaction Gas NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Gas"),
  ),
  TestSpec(
    name: "Invalid Transaction Value NewPayload",
    run:  invalidPayloadTestCaseGen("Transaction/Value"),
  ),

  # Eth RPC Status on ForkchoiceUpdated Events
  TestSpec(
    name: "Latest Block after NewPayload",
    run:  blockStatusExecPayload,
  ),
  TestSpec(
    name: "Latest Block after New HeadBlock",
    run:  blockStatusHeadBlock,
  ),
  TestSpec(
    name: "Latest Block after New SafeBlock",
    run:  blockStatusSafeBlock,
  ),
  TestSpec(
    name: "Latest Block after New FinalizedBlock",
    run:  blockStatusFinalizedBlock,
  ),
  TestSpec(
    name: "Latest Block after Reorg",
    run:  blockStatusReorg,
  ),

  # Payload Tests
  TestSpec(
    name: "Re-Execute Payload",
    run:  reExecPayloads,
  ),
  TestSpec(
    name: "Multiple New Payloads Extending Canonical Chain",
    run:  multipleNewCanonicalPayloads,
  ),
  TestSpec(
    name: "Out of Order Payload Execution",
    run:  outOfOrderPayloads,
  ),

  # Transaction Reorg using Engine API
  TestSpec(
    name: "Transaction Reorg",
    run:  transactionReorg,
  ),
  TestSpec(
    name: "Sidechain Reorg",
    run:  sidechainReorg,
  ),

  # Suggested Fee Recipient in Payload creation
  TestSpec(
    name: "Suggested Fee Recipient Test",
    run:  suggestedFeeRecipient,
  ),

  # TODO: debug and fix
  # PrevRandao opcode tests
  TestSpec(
    name: "PrevRandao Opcode Transactions",
    run:  prevRandaoOpcodeTx,
    ttd:  10,
  ),

  # Multi-Client Sync tests
  TestSpec(
    name: "Sync Client Post Merge",
    run:  postMergeSync,
    ttd:  10,
  )
]