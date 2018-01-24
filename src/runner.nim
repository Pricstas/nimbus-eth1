import
  strformat, strutils, tables, macros,
  constants, bigints, errors, logging, vm_state,
  vm / [gas_meter, stack, code_stream, memory, message, value], db / chain, computation, opcode, opcode_values, utils / [header, address],
  logic / [arithmetic, comparison]

var opcodes = initOpcodes:
  Op.Add: GAS_VERY_LOW add
  Op.Sub: GAS_VERY_LOW sub
  Op.Mul: GAS_LOW      mul
  Op.Div: GAS_LOW      divide

var mem = newMemory(pow(1024.int256, 2))

var to = toCanonicalAddress(cstring"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
var sender = toCanonicalAddress(cstring"0xcd1722f3947def4cf144679da39c4c32bdc35681")

var code = cstring""

var msg = newMessage(
  25.int256,
  1.int256,
  to,
  sender,
  0.int256,
  cstring"",
  code,
  MessageOptions(depth: 1.int256))

var c = BaseComputation(
  vmState: BaseVMState(
    prevHeaders: @[],
    chaindb: BaseChainDB(),
    blockHeader: Header(),
    name: "zero"),
  msg: msg,
  memory: mem,
  stack: newStack(),
  gasMeter: newGasMeter(msg.gas),
  code: newCodeStream(code),
  children: @[],
  rawOutput: cstring"",
  returnData: cstring"",
  error: nil,
  logEntries: @[],
  shouldEraseReturnData: false,
  accountsToDelete: initTable[cstring, cstring](),
  opcodes: opcodes,
  precompiles: initTable[cstring, Opcode]())

# var c2 = c.applyComputation(c.vmState, c.msg)

macro runOpcodes*(computation: untyped, program: untyped): untyped =
  # runOpcodes(c):
  #   stack: @[Value..]
  #   
  #   Op
  #   Op
  #
  # becomes
  #
  # c.stack.push(Value) ..
  #
  # c.getOpcodeFn(Op).run(c)
  # echo c.stack ..
  var stack = nnkStmtList.newTree()
  for child in program[0][1][0][1]:
    let push = quote:
      `computation`.stack.push(`child`)
    stack.add(push)

  var ops = nnkStmtList.newTree()
  for z, op in program:
    if z > 0:
      let run = quote:
        `computation`.getOpcodeFn(`op`).run(`computation`)
        echo `computation`.stack
      ops.add(run)

  result = nnkStmtList.newTree(stack, ops)

# useful for testing simple cases
runOpcodes(c):
  stack: @[2.vint, 2.vint, 2.vint]

  Op.Add
  Op.Mul

