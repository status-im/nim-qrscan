## QML QrImageDecoder: decoding a QR code from a local image file.

import std/[unittest, os, json, monotimes, times]
import nimqml
from seaqt/qimage import QImage, create, save, bytesPerLine, bits
from seaqt/qimagereader import QImageReader, supportedImageFormats
import ../qrscan/qml
import ./[qrgen, testutils]

putEnv("QT_QPA_PLATFORM", "offscreen")

type Event = object
  failed: bool
  texts: seq[string]
  undecodable: int
  kind: string ## failures: "unsupported" | "unopenable"

QtObject:
  type Reporter = ref object of QObject
    events: seq[Event]   ## decoded / failed signals, in arrival order
    busyAtReturn: bool
    eventsAtReturn: int  ## events already in when decodeFile returned
    heic: bool
    busyAfterCancel: bool

  proc setup(self: Reporter)
  proc delete(self: Reporter)

  proc newReporter(): Reporter =
    new(result, delete)
    result.setup

  proc setup(self: Reporter) =
    self.QObject.setup

  proc delete(self: Reporter) =
    self.QObject.delete

  proc decoded(self: Reporter, textsJson: string, undecodable: int) {.slot.} =
    var e = Event(undecodable: undecodable)
    try:
      for t in parseJson(textsJson):
        e.texts.add t.getStr
    except CatchableError:
      discard
    self.events.add e

  proc failed(self: Reporter, kind: string, message: string) {.slot.} =
    self.events.add Event(failed: true, kind: kind)

  proc returned(self: Reporter, busy: bool) {.slot.} =
    self.busyAtReturn = busy
    self.eventsAtReturn = self.events.len

  proc heicIs(self: Reporter, supported: bool) {.slot.} =
    self.heic = supported

  proc cancelled(self: Reporter, busy: bool) {.slot.} =
    self.busyAfterCancel = busy

  proc requestDecode*(self: Reporter, path: string) {.signal.}
  proc destroyDecoder*(self: Reporter) {.signal.}
  proc recreateDecoder*(self: Reporter) {.signal.}
  proc queryHeic*(self: Reporter) {.signal.}
  proc cancelDecode*(self: Reporter) {.signal.}

proc noFrames(): FrameSource =
  FrameSource(
    attach: proc(source, scanner: int) {.gcsafe, raises: [].} = discard,
    requestNext: proc(source: int) {.gcsafe, raises: [].} = discard,
    detach: proc(source: int) {.gcsafe, raises: [].} = discard)

let app = newQGuiApplication()
let engine = newQQmlApplicationEngine()
install(engine, noFrames())
let reporter = newReporter()
engine.setRootContextProperty("reporter", newQVariant(reporter))
engine.loadData("""
import QtQuick
import NimQrScan 1.0
Item {
  Loader {
    id: loader
    sourceComponent: Component {
      Item {
        property alias decoder: d
        QrImageDecoder {
          id: d
          onDecoded: (texts, undecodable) => reporter.decoded(JSON.stringify(texts), undecodable)
          onFailed: (kind, message) => reporter.failed(kind, message)
        }
      }
    }
  }
  Connections {
    target: reporter
    function onRequestDecode(path) {
      loader.item.decoder.decodeFile(path)
      reporter.returned(loader.item.decoder.busy)
    }
    function onDestroyDecoder() { loader.active = false }
    function onRecreateDecoder() { loader.active = true }
    function onQueryHeic() { reporter.heicIs(loader.item.decoder.heicSupported) }
    function onCancelDecode() {
      loader.item.decoder.cancel()
      reporter.cancelled(loader.item.decoder.busy)
    }
  }
}
""")
processEvents()

let dir = getTempDir() / "qrscan-timage"
createDir(dir)

proc save(g: GrayImage, name: string, format = "PNG"): string =
  ## Writes `g` as an image file; returns its path.
  result = dir / name
  let img = QImage.create(g.width.cint, g.height.cint, 24) # Format_Grayscale8
  let bpl = img.bytesPerLine().int
  let bits = cast[ptr UncheckedArray[byte]](img.bits())
  for y in 0 ..< g.height:
    for x in 0 ..< g.width:
      bits[y * bpl + x] = g.data[y * g.rowStride + x]
  doAssert img.save(result, format.cstring), "could not write " & result

proc saveTransparent(g: GrayImage, name: string): string =
  ## Dark modules opaque black, the rest fully transparent (0,0,0,0), as many
  ## QR generators export PNGs.
  result = dir / name
  let img = QImage.create(g.width.cint, g.height.cint, 5) # Format_ARGB32
  let bpl = img.bytesPerLine().int
  let bits = cast[ptr UncheckedArray[uint32]](img.bits())
  for y in 0 ..< g.height:
    for x in 0 ..< g.width:
      bits[y * (bpl div 4) + x] =
        if g.data[y * g.rowStride + x] < 128: 0xFF000000'u32 else: 0x00000000'u32
  doAssert img.save(result, "PNG"), "could not write " & result

proc blank(w, h: int): GrayImage =
  result = GrayImage(width: w, height: h, rowStride: w, data: newSeq[byte](w * h))
  for b in result.data.mitems:
    b = 255

proc paste(dst: var GrayImage, src: GrayImage, x0, y0: int) =
  for y in 0 ..< src.height:
    for x in 0 ..< src.width:
      dst.data[(y0 + y) * dst.rowStride + x0 + x] = src.data[y * src.rowStride + x]

proc twoCodes(a, b: string): GrayImage =
  let qa = qrImage(a)
  let qb = qrImage(b)
  result = blank(qa.width + qb.width + 40, max(qa.height, qb.height) + 20)
  result.paste(qa, 10, 10)
  result.paste(qb, qa.width + 30, 10)

proc damaged(text: string): GrayImage =
  ## A QR whose data region is damaged beyond error correction.
  const scale = 4
  const quiet = 4
  result = qrImage(text, scale, quiet, eccLow)
  let modules = result.width div scale - 2 * quiet
  for my in modules div 2 ..< modules - 9:
    for mx in modules div 2 ..< modules - 1:
      for dy in 0 ..< scale:
        for dx in 0 ..< scale:
          let i = ((my + quiet) * scale + dy) * result.rowStride + (mx + quiet) * scale + dx
          result.data[i] = 255'u8 - result.data[i]

proc noisyWithCode(text: string): GrayImage =
  ## Large and noisy: slow enough to still be decoding when the test acts.
  result = GrayImage(width: 2600, height: 2600, rowStride: 2600,
                     data: newSeq[byte](2600 * 2600)).withNoise(127, 5)
  result.paste(qrImage(text, scale = 6), 1200, 1200)

proc waitFor(cond: proc(): bool, timeoutMs = 8000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    processEvents()
    if cond():
      return true
    sleep(2)
  cond()

proc settle(ms = 300) =
  ## Lets any further (unexpected) signal arrive.
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while getMonoTime() < deadline:
    processEvents()
    sleep(2)

proc decodeOne(path: string): Event =
  ## Decodes `path` and returns its one signal.
  let before = reporter.events.len
  reporter.requestDecode(path)
  doAssert waitFor(proc(): bool = reporter.events.len > before), "no signal for " & path
  reporter.events[^1]

proc writeBytes(name: string, bytes: openArray[byte]): string =
  result = dir / name
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  writeFile(result, s)

# Real images of a Status profile QR code (with a logo in the middle).
const profileLink = "https://status.app/u/iweACg4KDHpRMy4uLlZoNG5OMwM=" &
  "#zQ3shZnCMtyHdMqqBw3yEGqmzKKNUxvJorDJqMjWPEEVh4nN3"

proc fixture(name: string): string =
  currentSourcePath().parentDir / "fixtures" / name

suite "QrImageDecoder":
  test "PNG with one code → decoded([text], 0)":
    let e = decodeOne(qrImage("img-png").save("one.png"))
    check not e.failed
    check e.texts == @["img-png"]
    check e.undecodable == 0

  test "JPEG with one code → decoded([text], 0)":
    let e = decodeOne(qrImage("img-jpeg", scale = 6).save("one.jpg", "JPG"))
    check e.texts == @["img-jpeg"]

  test "content decides, not the extension":
    # PNG content in a .jpg file
    let e = decodeOne(qrImage("png-as-jpg").save("png-content.jpg", "PNG"))
    check e.texts == @["png-as-jpg"]

  test "file: URL and plain path both work":
    let p = qrImage("url-or-path").save("url.png")
    check decodeOne("file://" & p).texts == @["url-or-path"]
    check decodeOne(p).texts == @["url-or-path"]

  test "a code on a transparent background decodes":
    let e = decodeOne(qrImage("transparent-bg").saveTransparent("transparent.png"))
    check not e.failed
    check e.texts == @["transparent-bg"]

  test "two codes → both texts":
    let e = decodeOne(twoCodes("left-code", "right-code").save("two.png"))
    check e.texts.len == 2
    check "left-code" in e.texts and "right-code" in e.texts

  test "no code → decoded([], 0)":
    let e = decodeOne(blank(400, 300).save("blank.png"))
    check not e.failed
    check e.texts.len == 0
    check e.undecodable == 0

  test "damaged code → decoded([], 1)":
    let e = decodeOne(damaged("an image whose code is damaged beyond repair").save("damaged.png"))
    check not e.failed
    check e.texts.len == 0
    check e.undecodable == 1

  test "a file of an unsupported type → failed(unsupported)":
    let p = dir / "notes.txt"
    writeFile(p, "these are not image bytes at all\n")
    let e = decodeOne(p)
    check e.failed
    check e.kind == "unsupported"

  test "a PNG with a broken body → failed(unopenable)":
    # valid PNG signature, then garbage
    let e = decodeOne(writeBytes("broken.png",
      [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6, 7, 8]))
    check e.failed
    check e.kind == "unopenable"

  test "truncated JPEG → decoded or failed(unopenable), never stuck busy":
    let full = qrImage("truncated-jpeg", scale = 6).save("full.jpg", "JPG")
    let bytes = readFile(full)
    writeFile(dir / "truncated.jpg", bytes[0 ..< bytes.len div 2])
    let e = decodeOne(dir / "truncated.jpg")
    check (not e.failed) or e.kind == "unopenable"

  test "an existing but unreadable file → failed(unopenable)":
    let p = qrImage("unreadable").save("unreadable.png")
    setFilePermissions(p, {})
    defer: setFilePermissions(p, {fpUserRead, fpUserWrite})
    var f: File
    if open(f, p): # root reads it anyway: nothing to check
      f.close()
      skip()
    else:
      let e = decodeOne(p)
      check e.failed
      check e.kind == "unopenable"

  test "missing file → failed(unopenable)":
    let e = decodeOne(dir / "does-not-exist.png")
    check e.failed
    check e.kind == "unopenable"

  test "empty file → failed(unopenable)":
    writeFile(dir / "empty.png", "")
    let e = decodeOne(dir / "empty.png")
    check e.failed
    check e.kind == "unopenable"

  test "non-file URL → failed(unopenable), nothing fetched":
    let e = decodeOne("https://example.com/qr.png")
    check e.failed
    check e.kind == "unopenable"

  test "large image is scaled down and still decodes":
    var g = blank(4000, 3000)
    g.paste(qrImage("large-image", scale = 24), 1600, 1100) # code ≥ 600 px
    check decodeOne(g.save("large.png")).texts == @["large-image"]

  test "decodeFile returns at once, even for a large photo":
    # loading (read, scale, grayscale) must not run on the GUI thread
    var g = blank(6000, 4500) # 27 MP
    g.paste(qrImage("large-photo", scale = 30), 2600, 1800)
    let p = g.save("photo27mp.png")
    let before = reporter.events.len
    let t0 = getMonoTime()
    reporter.requestDecode(p) # QML calls decodeFile synchronously
    let elapsed = (getMonoTime() - t0).inMilliseconds
    check elapsed < 50
    check waitFor(proc(): bool = reporter.events.len > before, 20000)
    check reporter.events[^1].texts == @["large-photo"]

  test "results arrive after decodeFile returns":
    let before = reporter.events.len
    discard decodeOne(qrImage("async-ok").save("async.png"))
    check reporter.eventsAtReturn == before # nothing yet when decodeFile returned
    let beforeFail = reporter.events.len
    discard decodeOne(dir / "missing-async.png")
    check reporter.eventsAtReturn == beforeFail # failures too

  test "busy is true until the result":
    discard decodeOne(qrImage("busy-check").save("busy.png"))
    check reporter.busyAtReturn

  test "a second decodeFile supersedes the first":
    let slow = noisyWithCode("first-image").save("first.png")
    let second = qrImage("second-image").save("second.png")
    let before = reporter.events.len
    reporter.requestDecode(slow)
    reporter.requestDecode(second)
    check waitFor(proc(): bool = reporter.events.len > before)
    settle(3000) # the first decode has had time to finish
    check reporter.events.len == before + 1
    check reporter.events[^1].texts == @["second-image"]

  test "cancel mid-decode → no signal, not busy; the next decodeFile works":
    let slow = noisyWithCode("cancelled-mid-decode").save("cancelled.png")
    let before = reporter.events.len
    reporter.requestDecode(slow)
    reporter.cancelDecode()
    check not reporter.busyAfterCancel
    settle(3000) # the cancelled decode has had time to finish
    check reporter.events.len == before
    check decodeOne(qrImage("after-cancel").save("after-cancel.png")).texts == @["after-cancel"]

  test "cancel while loading → no signal":
    var g = blank(6000, 4500) # slow to load
    g.paste(qrImage("cancelled-load", scale = 30), 2600, 1800)
    let p = g.save("cancelled-load.png")
    let before = reporter.events.len
    reporter.requestDecode(p)
    reporter.cancelDecode()
    settle(5000)
    check reporter.events.len == before

  test "destroyed decoder mid-decode → no signal":
    let slow = noisyWithCode("destroyed-mid-decode").save("destroyed.png")
    let before = reporter.events.len
    reporter.requestDecode(slow)
    reporter.destroyDecoder()
    settle(3000)
    check reporter.events.len == before
    reporter.recreateDecoder()
    processEvents()

  test "real image: a profile QR code decodes":
    check decodeOne(fixture("profile.png")).texts == @[profileLink]

  test "real image: a rotated profile QR code decodes":
    check decodeOne(fixture("profile-angle.png")).texts == @[profileLink]

  test "real image: a PNG named .heic decodes on every platform":
    check decodeOne(fixture("profile-png-content.heic")).texts == @[profileLink]

  test "real image: a code cut off at a finder pattern → found, not decoded":
    # Less than half of the top-right finder is in the picture: the code is
    # found but can't be sampled ("Couldn't read the QR code").
    let e = decodeOne(fixture("profile-partial.png"))
    check not e.failed
    check e.texts.len == 0
    check e.undecodable > 0

  test "heicSupported matches the platform":
    reporter.queryHeic()
    var heicFormat = false
    for f in QImageReader.supportedImageFormats():
      if cast[string](f) == "heic":
        heicFormat = true
    check reporter.heic == (heicFormat or defined(android))

  test "HEIC decodes where supported":
    reporter.queryHeic()
    if not reporter.heic:
      skip()
    else:
      check decodeOne(fixture("profile-angle.heic")).texts == @[profileLink]

  test "HEIF (.heif) decodes where supported":
    reporter.queryHeic()
    if not reporter.heic:
      skip()
    else:
      check decodeOne(fixture("profile-angle.heif")).texts == @[profileLink]