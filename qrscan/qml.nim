## QML integration: `NimQrScan.QrScanner` decodes frames from an abstract
## frame source and emits `tagFound`.
##
## The scanner doesn't know where frames come from. The host supplies a
## `FrameSource` when installing; a "source" is any integer handle the host
## chooses (e.g. a NimQtCamera FrameTap handle). Frames arrive through
## `deliverFrame`, and the scanner asks for the next one only after the previous
## result is in (pull model: at most one decode in flight).
##
## nimqml-seaqt can't register Nim types with QML, so QrScanner is a .qml
## component (qml/NimQrScan) driven by one Nim backend installed as the context
## property `nimQrScanBackend`.

import std/[algorithm, os, tables, strutils]
import results
import nimqml
import ./[types, worker]
import ./private/qml_shim

export results, types

const qmlImportDir* = currentSourcePath().parentDir().parentDir() / "qml"
  ## Directory to add to the QML import path; contains `NimQrScan/`.

const backendContextName* = "nimQrScanBackend"

type
  FrameSource* = object
    ## Supplied by the host; all calls happen on the GUI thread.
    attach*: proc(source, scanner: int) {.gcsafe, raises: [].}
      ## start delivering frames from `source` to `scanner` via deliverFrame()
    requestNext*: proc(source: int) {.gcsafe, raises: [].}
      ## deliver one more frame from `source` (pull model)
    detach*: proc(source: int) {.gcsafe, raises: [].}
      ## stop delivering frames from `source`

  ScannerEntry = ref object
    source: int
    scanning: bool
    inFlight: bool          ## its frame is being decoded
    waiting: bool           ## wants a decode turn
    waitSeq: int            ## place in line (lower = waiting longer)
    requested: bool         ## a requestNext is outstanding
    pending: Opt[DecodeJob] ## at most one held frame (the newest)
    dropped: int
    opts: DecodeOptions

proc drainOnGui() {.cdecl, gcsafe, raises: [].}
proc quitOnGui() {.cdecl, gcsafe, raises: [].}

proc onWorkerReady() {.gcsafe, raises: [], nimcall.} =
  ## Worker thread: wake the GUI thread to collect the result.
  shimPostToGui(drainOnGui)

QtObject:
  type QrScanBackend* = ref object of QObject
    scanners: Table[int, ScannerEntry]
    nextHandle: int
    worker: DecodeWorker
    frames: FrameSource
    hasFrames: bool
    shutDown: bool
    nextWaitSeq: int
    pumping: bool
    pumpAgain: bool

  proc setup(self: QrScanBackend)
  proc delete(self: QrScanBackend)
  proc shutdown(self: QrScanBackend)

  proc newQrScanBackend*(): QrScanBackend =
    new(result, delete)
    result.setup
    result.nextHandle = 1
    result.worker = newDecodeWorker(onWorkerReady)
    # Stop and join the worker before the application object goes away.
    shimOnAboutToQuit(quitOnGui)

  proc setup(self: QrScanBackend) =
    self.QObject.setup

  proc delete(self: QrScanBackend) =
    self.shutdown()
    self.QObject.delete

  proc shutdown(self: QrScanBackend) =
    ## Detaches every source and stops/joins the worker (finishing a decode in
    ## flight). Afterwards frames are ignored. Idempotent.
    if self.shutDown:
      return
    self.shutDown = true
    if self.hasFrames:
      for e in self.scanners.values:
        if e.source != 0:
          self.frames.detach(e.source)
    self.scanners.clear()
    self.worker.stop()

  proc isShutDown*(self: QrScanBackend): bool =
    self.shutDown

  proc workerRunning*(self: QrScanBackend): bool =
    self.worker.isRunning

  proc scanResult*(self: QrScanBackend, handle: int, text: string, decodeMs: float) {.signal.}
  proc scanError*(self: QrScanBackend, handle: int, message: string) {.signal.}

  proc entry(self: QrScanBackend, handle: int): ScannerEntry =
    self.scanners.getOrDefault(handle, nil)

  # Scheduling. All scanners share one decode worker, which decodes one frame
  # at a time. Fairness is applied when a frame is *admitted* to the worker:
  # every scanner holds at most one frame (its newest), and whenever the worker
  # is free it takes the held frame of the scanner that has waited longest. A
  # scanner that just got a result joins the back of the line. Frame requests
  # go out in line order, but a source answering instantly can't jump ahead of
  # an older scanner whose frame arrives later: that frame is held and wins
  # the next turn.

  proc enqueue(self: QrScanBackend, e: ScannerEntry) =
    ## Joins the back of the line.
    inc self.nextWaitSeq
    e.waitSeq = self.nextWaitSeq
    e.waiting = true

  proc admit(self: QrScanBackend) =
    ## Starts decoding the held frame of the longest-waiting scanner.
    if self.worker.busy:
      return
    var next: ScannerEntry = nil
    for e in self.scanners.values:
      if e.pending.isSome and e.waiting and e.scanning and not e.inFlight and
          (next == nil or e.waitSeq < next.waitSeq):
        next = e
    if next == nil:
      return
    var job = next.pending.get
    if self.worker.submit(job):
      next.pending = Opt.none(DecodeJob)
      next.waiting = false
      next.inFlight = true

  proc requestFrames(self: QrScanBackend) =
    ## Asks waiting scanners without a held frame for one, in line order.
    if self.shutDown or not self.hasFrames:
      return
    var line: seq[ScannerEntry]
    for e in self.scanners.values:
      if e.waiting and e.scanning and not e.inFlight and not e.requested and
          e.pending.isNone and e.source != 0:
        line.add e
    line.sort(proc(a, b: ScannerEntry): int = cmp(a.waitSeq, b.waitSeq))
    for e in line:
      e.requested = true
      self.frames.requestNext(e.source) # may deliver synchronously (re-enters pump)

  proc pump(self: QrScanBackend) =
    ## admit + requestFrames; re-entrant calls (synchronous sources) are folded
    ## into the outer loop.
    if self.shutDown:
      return
    if self.pumping:
      self.pumpAgain = true
      return
    self.pumping = true
    while true:
      self.pumpAgain = false
      self.admit()
      self.requestFrames()
      if not self.pumpAgain:
        break
    self.pumping = false

  proc createScanner(self: QrScanBackend): int {.slot.} =
    let h = self.nextHandle
    inc self.nextHandle
    self.scanners[h] = ScannerEntry(scanning: true, opts: DecodeOptions.init())
    h

  proc destroyScanner(self: QrScanBackend, handle: int) {.slot.} =
    let e = self.entry(handle)
    if e == nil:
      return
    if self.hasFrames and e.source != 0:
      self.frames.detach(e.source)
    self.scanners.del(handle) # a late result for this handle is dropped

  proc bindSource(self: QrScanBackend, handle: int, source: int) {.slot.} =
    ## source 0 = none.
    let e = self.entry(handle)
    if e == nil or e.source == source:
      return
    if self.hasFrames and e.source != 0:
      self.frames.detach(e.source)
    e.source = source
    e.requested = false
    e.pending = Opt.none(DecodeJob)
    if self.hasFrames and source != 0:
      self.frames.attach(source, handle)
      if not e.inFlight:
        self.enqueue(e)
      self.pump()

  proc setScanning(self: QrScanBackend, handle: int, on: bool) {.slot.} =
    let e = self.entry(handle)
    if e == nil or e.scanning == on:
      return
    e.scanning = on
    if on:
      if not e.inFlight:
        self.enqueue(e)
      self.pump()
    else:
      # Frames answering an outstanding request are ignored while paused, so
      # forget it: resuming asks again.
      e.waiting = false
      e.requested = false
      e.pending = Opt.none(DecodeJob)

  proc setOptions(self: QrScanBackend, handle: int, tryHarder: bool, tryRotate: bool,
                  tryInvert: bool, formatsCsv: string) {.slot.} =
    let e = self.entry(handle)
    if e == nil:
      return
    e.opts.tryHarder = tryHarder
    e.opts.tryRotate = tryRotate
    e.opts.tryInvert = tryInvert
    var formats: set[BarcodeFormat]
    for name in formatsCsv.split(','):
      for f in BarcodeFormat:
        if $f == name.strip:
          formats.incl f
    e.opts.formats = formats # empty = QR codes

  proc scannerCount*(self: QrScanBackend): int {.slot.} =
    self.scanners.len

  proc deliver(self: QrScanBackend, handle: int, data: openArray[byte],
               width, height, rowStride: int) =
    let e = self.entry(handle)
    if self.shutDown or e == nil:
      return
    e.requested = false # any delivery answers the outstanding request
    if not e.scanning:
      return
    if e.inFlight:
      inc e.dropped # its own result comes first; it asks again afterwards
      return
    if not e.waiting:
      self.enqueue(e) # a frame without a request: join the line
    if e.pending.isSome:
      inc e.dropped # replaced by the newer frame
    var job = DecodeJob(id: handle, width: width, height: height, rowStride: rowStride,
                        opts: e.opts, data: newSeq[byte](data.len))
    if data.len > 0:
      copyMem(addr job.data[0], unsafeAddr data[0], data.len)
    e.pending = Opt.some(job)
    self.pump()

  proc drain(self: QrScanBackend) =
    while true:
      let r = self.worker.tryTakeResult()
      if r.isNone:
        break
      let outcome = r.get
      let e = self.entry(outcome.id)
      if e == nil:
        continue # scanner destroyed while decoding
      e.inFlight = false
      # A scanner paused while its frame was decoding (e.g. the dialog closed)
      # gets no late results.
      if e.scanning:
        if outcome.error.isSome:
          self.scanError(outcome.id, outcome.error.get.msg)
        for code in outcome.codes:
          self.scanResult(outcome.id, code.text, outcome.decodeMs)
      if self.entry(outcome.id) != nil and e.scanning:
        self.enqueue(e) # back of the line
    self.pump()

var backend {.threadvar.}: QrScanBackend

proc qrScanBackend*(): QrScanBackend =
  ## The GUI thread's backend, created on first use.
  if backend == nil:
    backend = newQrScanBackend()
  backend

proc drainOnGui() {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    if backend != nil:
      backend.drain()

proc shutdownQrScan*() {.gcsafe, raises: [].} =
  ## Stops the backend's worker (also done automatically on aboutToQuit).
  {.cast(gcsafe), cast(raises: []).}:
    if backend != nil:
      backend.shutdown()

proc quitOnGui() {.cdecl, gcsafe, raises: [].} =
  shutdownQrScan()

proc deliverFrame*(scanner: int, data: openArray[byte], width, height, rowStride: int) {.
    gcsafe, raises: [].} =
  ## Host → scanner, on the GUI thread. Copies the frame and starts decoding it.
  ## Ignored for unknown or paused scanners and while a decode is in flight.
  {.cast(gcsafe), cast(raises: []).}:
    if backend != nil:
      backend.deliver(scanner, data, width, height, rowStride)

proc installOnEngine*(engine: pointer, frames: FrameSource) {.raises: [].} =
  ## For C++ hosts: `engine` is a QQmlEngine*. Adds the NimQrScan import path and
  ## the `nimQrScanBackend` context property. The first install's frame source
  ## is kept; all engines share the GUI thread's backend.
  {.cast(raises: []).}:
    let b = qrScanBackend()
    if not b.hasFrames:
      b.frames = frames
      b.hasFrames = true
    shimQmlInstall(engine, qmlImportDir.cstring, backendContextName.cstring,
                   cast[pointer](b.vptr))

proc install*(engine: QQmlApplicationEngine, frames: FrameSource) =
  ## For Nim (nimqml) hosts.
  installOnEngine(cast[pointer](engine.vptr), frames)
