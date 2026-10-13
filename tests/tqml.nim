## QML QrScanner over a synthetic frame source: no camera, no nim-qtcamera.

import std/[unittest, os, tables, monotimes, times]
import nimqml
import ../qrscan/qml
import ./[qrgen, testutils]

putEnv("QT_QPA_PLATFORM", "offscreen")

QtObject:
  type Reporter = ref object of QObject
    found: seq[string]
    scannerHandle: int
    otherHandle: int

  proc setup(self: Reporter)
  proc delete(self: Reporter)

  proc newReporter(): Reporter =
    new(result, delete)
    result.setup

  proc setup(self: Reporter) =
    self.QObject.setup

  proc delete(self: Reporter) =
    self.QObject.delete

  proc ready(self: Reporter, handle: int) {.slot.} =
    self.scannerHandle = handle

  proc readyOther(self: Reporter, handle: int) {.slot.} =
    self.otherHandle = handle

  proc foundTag(self: Reporter, tag: string) {.slot.} =
    self.found.add tag

  proc setScanning*(self: Reporter, on: bool) {.signal.}
  proc destroyScanner*(self: Reporter) {.signal.}

# --- synthetic frame source (the host's job in real apps) -----------------
var
  syncSource = 0                # a source that answers requestNext synchronously
  syncFrame: GrayImage
  attached: Table[int, int]     # source -> scanner
  requests: Table[int, int]     # source -> pending frame requests
  queue: Table[int, seq[GrayImage]]

let testFrames = FrameSource(
  attach: proc(source, scanner: int) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: attached[source] = scanner,
  requestNext: proc(source: int) {.gcsafe, raises: [].} =
    {.cast(gcsafe), cast(raises: []).}:
      requests.mgetOrPut(source, 0).inc
      if source == syncSource and source in attached: # frame already available
        deliverFrame(attached[source], syncFrame.data, syncFrame.width,
                     syncFrame.height, syncFrame.rowStride),
  detach: proc(source: int) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: attached.del(source))

proc pump(source: int) =
  ## Delivers queued frames while the scanner has asked for one.
  while requests.getOrDefault(source) > 0 and queue.getOrDefault(source).len > 0 and
      source in attached:
    dec requests[source]
    let g = queue[source][0]
    queue[source].delete(0)
    deliverFrame(attached[source], g.data, g.width, g.height, g.rowStride)

proc slowFrameWithCode(text: string): GrayImage =
  ## Large and noisy: decoding takes long enough to still be running when the
  ## test acts on another scanner, yet still finds `text`.
  result = GrayImage(width: 2600, height: 2600, rowStride: 2600,
                     data: newSeq[byte](2600 * 2600)).withNoise(127, 5)
  let qr = qrImage(text, scale = 6)
  for y in 0 ..< qr.height:
    for x in 0 ..< qr.width:
      result.data[(1200 + y) * 2600 + 1200 + x] = qr.data[y * qr.rowStride + x]

proc waitFor(cond: proc(): bool, timeoutMs = 3000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    processEvents()
    if cond():
      return true
    sleep(2)
  cond()

const source = 7

let app = newQGuiApplication()
let engine = newQQmlApplicationEngine()
install(engine, testFrames)
let reporter = newReporter()
engine.setRootContextProperty("reporter", newQVariant(reporter))
engine.loadData("""
import QtQuick
import NimQrScan 1.0
Item {
  Loader {
    id: loader
    sourceComponent: Component {
      QrScanner {
        frameSource: 7
        onTagFound: tag => reporter.foundTag(tag)
        Component.onCompleted: reporter.ready(handle)
      }
    }
  }
  QrScanner {
    // a second scanner sharing the backend's one decode worker
    frameSource: 8
    Component.onCompleted: reporter.readyOther(handle)
  }
  Connections { target: reporter; function onSetScanning(on) { loader.item.scanning = on } }
  Connections { target: reporter; function onDestroyScanner() { loader.active = false } }
}
""")
processEvents()

suite "qml QrScanner":
  test "attach and first request on bind":
    check reporter.scannerHandle > 0
    check attached.getOrDefault(source) == reporter.scannerHandle
    check requests.getOrDefault(source) == 1

  test "decodes a delivered frame":
    queue[source] = @[qrImage("qml-scan")]
    pump(source)
    check waitFor(proc(): bool = reporter.found.len == 1)
    check reporter.found == @["qml-scan"]
    check waitFor(proc(): bool = requests.getOrDefault(source) == 1) # asks for the next frame

  test "pull model keeps one decode in flight": # Review Focus 1
    reporter.found.setLen(0)
    requests[source] = 0
    let g = qrImage("burst")
    for i in 0 ..< 30: # a source misbehaving: frames without requests
      deliverFrame(reporter.scannerHandle, g.data, g.width, g.height, g.rowStride)
    check waitFor(proc(): bool = reporter.found.len >= 1)
    for i in 0 ..< 50:
      processEvents()
      sleep(2)
    check reporter.found == @["burst"] # one decode, the rest dropped
    check requests.getOrDefault(source) == 1 # exactly one new request

  test "scanning false stops requesting":
    requests[source] = 0
    reporter.setScanning(false)
    processEvents()
    queue[source] = @[qrImage("paused")]
    let before = reporter.found.len
    deliverFrame(reporter.scannerHandle, queue[source][0].data, queue[source][0].width,
                 queue[source][0].height, queue[source][0].rowStride)
    for i in 0 ..< 50:
      processEvents()
      sleep(2)
    check reporter.found.len == before # not scanning: frame ignored
    check requests.getOrDefault(source) == 0
    reporter.setScanning(true)
    check waitFor(proc(): bool = requests.getOrDefault(source) == 1)
    pump(source)
    check waitFor(proc(): bool = reporter.found.len == before + 1)

  test "a frame dropped while another scanner decodes is requested again": # final review I1
    let a = reporter.otherHandle  # source 8
    let b = reporter.scannerHandle # source 7
    check a > 0
    let slow = slowFrameWithCode("from-a")
    deliverFrame(a, slow.data, slow.width, slow.height, slow.rowStride) # worker busy with A
    requests[source] = 0
    let g = qrImage("from-b")
    deliverFrame(b, g.data, g.width, g.height, g.rowStride) # dropped: worker busy
    check waitFor(proc(): bool = "from-a" in reporter.found or requests.getOrDefault(source) > 0, 20_000)
    # once A's decode is done, B must be asked for a new frame (no stall)
    check waitFor(proc(): bool = requests.getOrDefault(source) == 1, 20_000)
    queue[source] = @[g]
    pump(source)
    check waitFor(proc(): bool = "from-b" in reporter.found, 20_000)

  test "a synchronously fed scanner doesn't starve a waiting one": # review: fairness
    let a = reporter.otherHandle  # source 8: answers every request at once
    let b = reporter.scannerHandle # source 7
    syncFrame = qrImage("sync", scale = 20)
    syncSource = 8
    requests[source] = 0
    deliverFrame(a, syncFrame.data, syncFrame.width, syncFrame.height, syncFrame.rowStride)
    let g = qrImage("waiting")
    deliverFrame(b, g.data, g.width, g.height, g.rowStride) # dropped: worker busy with A
    check waitFor(proc(): bool = requests.getOrDefault(source) >= 1, 3000)
    syncSource = 0
    for i in 0 ..< 50:
      processEvents()
      sleep(2)

  test "scanner destroyed mid-decode": # Review Focus 2
    let h = reporter.scannerHandle
    let before = reporter.found.len
    let slow = slowFrameWithCode("late")
    deliverFrame(h, slow.data, slow.width, slow.height, slow.rowStride)
    reporter.destroyScanner() # while the slow decode is still running
    for i in 0 ..< 400:
      processEvents()
      sleep(5)
    check "late" notin reporter.found # no signal for a destroyed scanner
    check reporter.found.len == before
    check source notin attached # detached on destroy
    check qrScanBackend().scannerCount() == 1 # only the second scanner remains
    let g = qrImage("late")
    deliverFrame(h, g.data, g.width, g.height, g.rowStride) # late frame: ignored
    for i in 0 ..< 20:
      processEvents()
    check reporter.found.len == before

  test "two engines share one backend":
    let b = qrScanBackend()
    let e2 = newQQmlApplicationEngine()
    installOnEngine(cast[pointer](e2.vptr), testFrames)
    check qrScanBackend() == b
    check b.scannerCount() == 1
    e2.delete()
