# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Worker peers scheduler template
## ===============================
##
## Public descriptors

import
  eth/[common/eth_types, p2p]

{.push raises: [Defect].}

type
  BuddyRunState* = enum
    Running = 0             ## Running, default state
    Stopped                 ## Stopped or about stopping
    ZombieStop              ## Abandon/ignore (wait for pushed out of LRU table)
    ZombieRun               ## Extra zombie state to potentially recover from

  BuddyCtrl* = object
    ## Control and state settings
    runState: BuddyRunState ## Access with getters
    multiOk*: bool          ## Triggers `runSingle()` mode unless `true`

  BuddyRef*[S,W] = ref object
    ## Worker peer state descriptor.
    ctx*: CtxRef[S]         ## Shared data descriptor back reference
    peer*: Peer             ## Reference to eth p2pProtocol entry
    ctrl*: BuddyCtrl        ## Control and state settings
    data*: W                ## Worker peer specific data

  CtxRef*[S] = ref object
    ## Shared state among all syncing peer workers (aka buddies.)
    buddiesMax*: int        ## Max number of buddies
    chain*: AbstractChainDB ## Block chain database (no need for `Peer`)
    poolMode*: bool         ## Activate `runPool()` workers if set `true`
    data*: S                ## Shared context for all worker peers

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc `$`*[S,W](worker: BuddyRef[S,W]): string =
  $worker.peer & "$" & $worker.ctrl.runState

# ------------------------------------------------------------------------------
# Public getters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc state*(ctrl: BuddyCtrl): BuddyRunState =
  ## Getter (logging only, details of `BuddyCtrl` are private)
  ctrl.runState

proc running*(ctrl: BuddyCtrl): bool =
  ## Getter, if `true` if `ctrl.state()` is `Running`
  ctrl.runState == Running

proc stopped*(ctrl: BuddyCtrl): bool =
  ## Getter, if `true`, if `ctrl.state()` is not `Running`
  ctrl.runState in {Stopped, ZombieStop, ZombieRun}

proc zombie*(ctrl: BuddyCtrl): bool =
  ## Getter, `true` if `ctrl.state()` is `Zombie` (i.e. not `running()` and
  ## not `stopped()`)
  ctrl.runState in {ZombieStop, ZombieRun}

# ------------------------------------------------------------------------------
# Public setters, `BuddyRunState` execution control functions
# ------------------------------------------------------------------------------

proc `zombie=`*(ctrl: var BuddyCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = ZombieRun
    of Stopped:
      ctrl.runState = ZombieStop
    else:
      discard
  else:
    case ctrl.runState:
    of ZombieRun:
      ctrl.runState = Running
    of ZombieStop:
      ctrl.runState = Stopped
    else:
      discard

proc `stopped=`*(ctrl: var BuddyCtrl; value: bool) =
  ## Setter
  if value:
    case ctrl.runState:
    of Running:
      ctrl.runState = Stopped
    else:
      discard
  else:
    case ctrl.runState:
    of Stopped:
      ctrl.runState = Running
    else:
      discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------