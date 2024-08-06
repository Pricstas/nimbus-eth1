# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sugar],
  eth/common,
  ../../../network/state/[state_content, state_utils, state_gossip],
  ./world_state

type OffersBuilder* = object
  worldState: WorldStateRef
  blockHash: BlockHash
  accountTrieOffers: seq[AccountTrieOfferWithKey]
  contractTrieOffers: seq[ContractTrieOfferWithKey]
  contractCodeOffers: seq[ContractCodeOfferWithKey]

proc init*(T: type OffersBuilder, worldState: WorldStateRef, blockHash: BlockHash): T =
  T(worldState: worldState, blockHash: blockHash)

proc toTrieProof(proof: seq[seq[byte]]): TrieProof =
  TrieProof.init(proof.map((node) => TrieNode.init(node)))

proc buildAccountTrieNodeOffer(
    builder: var OffersBuilder, address: EthAddress, proof: TrieProof
) =
  try:
    let
      path = removeLeafKeyEndNibbles(
        Nibbles.init(worldState.toAccountKey(address).data, isEven = true), proof[^1]
      )
      offerKey = AccountTrieNodeKey.init(path, keccakHash(proof[^1].asSeq()))
      offerValue = AccountTrieNodeOffer.init(proof, builder.blockHash)

    builder.accountTrieOffers.add(offerValue.withKey(offerKey))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen

proc buildContractTrieNodeOffer(
    builder: var OffersBuilder,
    address: EthAddress,
    slotHash: SlotKeyHash,
    storageProof: TrieProof,
    accountProof: TrieProof,
) =
  try:
    let
      path = removeLeafKeyEndNibbles(
        Nibbles.init(slotHash.data, isEven = true), storageProof[^1]
      )
      offerKey =
        ContractTrieNodeKey.init(address, path, keccakHash(storageProof[^1].asSeq()))
      offerValue =
        ContractTrieNodeOffer.init(storageProof, accountProof, builder.blockHash)

    builder.contractTrieOffers.add(offerValue.withKey(offerKey))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen

proc buildContractCodeOffer(
    builder: var OffersBuilder,
    address: EthAddress,
    code: seq[byte],
    accountProof: TrieProof,
) =
  let
    #bytecode = Bytelist.init(code) # This fails to compile for some reason
    bytecode = List[byte, MAX_BYTECODE_LEN](code)
    offerKey = ContractCodeKey.init(address, keccakHash(code))
    offerValue = ContractCodeOffer.init(bytecode, accountProof, builder.blockHash)

  builder.contractCodeOffers.add(offerValue.withKey(offerKey))

proc buildBlockOffers*(builder: var OffersBuilder) =
  for address, proof in builder.worldState.updatedAccountProofs():
    let accountProof = toTrieProof(proof)
    builder.buildAccountTrieNodeOffer(address, accountProof)

    for slotHash, sProof in builder.worldState.updatedStorageProofs(address):
      let storageProof = toTrieProof(sProof)
      builder.buildContractTrieNodeOffer(address, slotHash, storageProof, accountProof)

    let code = builder.worldState.getUpdatedBytecode(address)
    if code.len() > 0:
      builder.buildContractCodeOffer(address, code, accountProof)

proc getAccountTrieOffers*(builder: OffersBuilder): lent seq[AccountTrieOfferWithKey] =
  builder.accountTrieOffers

proc getContractTrieOffers*(
    builder: OffersBuilder
): lent seq[ContractTrieOfferWithKey] =
  builder.contractTrieOffers

proc getContractCodeOffers*(
    builder: OffersBuilder
): lent seq[ContractCodeOfferWithKey] =
  builder.contractCodeOffers
