# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/strutils,
  pkg/[chronos, chronicles, eth/common, stint],
  ../../../../utils/prettify,
  ../../../types

logScope:
  topics = "ticker"

type
  TickerFlareStatsUpdater* = proc: TickerFlareStats {.gcsafe, raises: [].}
    ## Full sync state update function

  TickerFlareStats* = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    stateTop*: BlockNumber
    base*: BlockNumber
    least*: BlockNumber
    final*: BlockNumber
    beacon*: BlockNumber

    hdrUnprocTop*: BlockNumber
    nHdrUnprocessed*: uint64
    nHdrUnprocFragm*: int
    nHdrStaged*: int
    hdrStagedTop*: BlockNumber

    blkUnprocTop*: BlockNumber
    nBlkUnprocessed*: uint64
    nBlkUnprocFragm*: int
    nBlkStaged*: int
    blkStagedBottom*: BlockNumber

    reorg*: int

  TickerRef* = ref object
    ## Ticker descriptor object
    nBuddies: int
    started: Moment
    visited: Moment
    prettyPrint: proc(t: TickerRef) {.gcsafe, raises: [].}
    flareCb: TickerFlareStatsUpdater
    lastStats: TickerFlareStats

const
  tickerStartDelay = chronos.milliseconds(100)
  tickerLogInterval = chronos.seconds(1)
  tickerLogSuppressMax = chronos.seconds(100)

# ------------------------------------------------------------------------------
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

proc flareTicker(t: TickerRef) {.gcsafe.} =
  let
    data = t.flareCb()
    now = Moment.now()

  if data != t.lastStats or
     tickerLogSuppressMax < (now - t.visited):
    let
      T = data.stateTop.toStr
      B = data.base.toStr
      L = data.least.toStr
      F = data.final.toStr
      Z = data.beacon.toStr

      hS = if data.nHdrStaged == 0: "n/a"
           else: data.hdrStagedTop.toStr & "(" & $data.nHdrStaged & ")"
      hU = if data.nHdrUnprocFragm == 0: "n/a"
           else: data.hdrUnprocTop.toStr & "(" &
                 data.nHdrUnprocessed.toSI & "," & $data.nHdrUnprocFragm & ")"

      bS = if data.nBlkStaged == 0: "n/a"
           else: data.blkStagedBottom.toStr & "(" & $data.nBlkStaged & ")"
      bU = if data.nBlkUnprocFragm == 0: "n/a"
           else: data.blkUnprocTop.toStr & "(" &
                 data.nBlkUnprocessed.toSI & "," & $data.nBlkUnprocFragm & ")"

      reorg = data.reorg
      peers = t.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.lastStats = data
    t.visited = now

    info "State", up, peers, T, B, L, F, Z, hS, hU, bS, bU, reorg, mem

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  t.prettyPrint(t)
  t.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(t: TickerRef; at: Moment) =
  if t.flareCb.isNil:
    debug "Stopped", nBuddies=t.nBuddies
  else:
    # Store the `runLogTicker()` in a closure to avoid some garbage collection
    # memory corruption issues that might occur otherwise.
    discard setTimer(at, proc(ign: pointer) = runLogTicker(t))

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type TickerRef; cb: TickerFlareStatsUpdater): T =
  ## Constructor
  result = TickerRef(
    prettyPrint: flareTicker,
    flareCb:     cb,
    started:     Moment.now())
  result.setLogTicker Moment.fromNow(tickerStartDelay)

proc destroy*(t: TickerRef) =
  ## Stop ticker unconditionally
  if not t.isNil:
    t.flareCb = TickerFlareStatsUpdater(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc startBuddy*(t: TickerRef) =
  ## Increment buddies counter and start ticker unless running.
  if not t.isNil:
    if t.nBuddies <= 0:
      t.nBuddies = 1
    else:
      t.nBuddies.inc
    debug "Start buddy", nBuddies=t.nBuddies

proc stopBuddy*(t: TickerRef) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  if not t.isNil:
    if 0 < t.nBuddies:
      t.nBuddies.dec
    debug "Stop buddy", nBuddies=t.nBuddies

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
