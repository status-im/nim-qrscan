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

import std/[os, tables, strutils]
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
    inFlight: bool
    wantsFrame: bool ## waiting for its turn to request a frame
    waitSeq: int     ## queue position (lower = waiting longer); kept across drops
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

  proc entry(self: QrScanBackend, handle: int): ScannerEntry =
    self.scanners.getOrDefault(handle, nil)

  proc requestNext(self: QrScanBackend, e: ScannerEntry) =
    if not self.shutDown and self.hasFrames and e.scanning and not e.inFlight and e.source != 0:
      self.frames.requestNext(e.source)

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
    if self.hasFrames and source != 0:
      self.frames.attach(source, handle)
      self.requestNext(e)

  proc setScanning(self: QrScanBackend, handle: int, on: bool) {.slot.} =
    let e = self.entry(handle)
    if e == nil or e.scanning == on:
      return
    e.scanning = on
    self.requestNext(e)

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
    if self.shutDown or e == nil or not e.scanning:
      return
    if e.inFlight:
      inc e.dropped # its own result will request the next frame
      return
    if self.worker.busy:
      # Another scanner's decode holds the shared worker. The request this
      # frame answered is used up: wait for another turn, keeping the place in
      # line (waitSeq is unchanged).
      inc e.dropped
      e.wantsFrame = true
      return
    var job = DecodeJob(id: handle, width: width, height: height, rowStride: rowStride,
                        opts: e.opts, data: newSeq[byte](data.len))
    if data.len > 0:
      copyMem(addr job.data[0], unsafeAddr data[0], data.len)
    if self.worker.submit(job):
      e.inFlight = true
    else:
      inc e.dropped
      e.wantsFrame = true # keeps its place in line

  proc enqueue(self: QrScanBackend, e: ScannerEntry) =
    ## Joins the back of the line of scanners waiting for a frame.
    inc self.nextWaitSeq
    e.waitSeq = self.nextWaitSeq
    e.wantsFrame = true

  proc serveWaiting(self: QrScanBackend) =
    ## While the shared worker is free, asks the scanner that has waited
    ## longest for a frame. A source may deliver synchronously from
    ## requestNext, making the worker busy again: the others keep their place.
    while not self.worker.busy:
      var next: ScannerEntry = nil
      for e in self.scanners.values:
        if e.wantsFrame and not e.inFlight and e.scanning and e.source != 0 and
            (next == nil or e.waitSeq < next.waitSeq):
          next = e
      if next == nil:
        break
      next.wantsFrame = false
      self.requestNext(next)

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
      for code in outcome.codes:
        self.scanResult(outcome.id, code.text, outcome.decodeMs)
      # Back of the line, so scanners waiting since earlier go first.
      self.enqueue(e)
    self.serveWaiting()

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
