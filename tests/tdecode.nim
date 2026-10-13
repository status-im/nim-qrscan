import std/[unittest, strutils]
import results
import ../qrscan
import ./qrgen

proc view(g: GrayImage): LumaView =
  lumaView(g.data, g.width, g.height, g.rowStride)

proc decodeText(g: GrayImage, opts = DecodeOptions.init()): seq[string] =
  for c in decode(g.view, opts).get:
    result.add c.text

suite "decode":
  test "plain QR":
    let address = "0x0123456789abcdef0123456789abcdef01234567"
    check decodeText(qrImage(address)) == @[address]
    check decode(qrImage(address).view).get[0].format == bfQrCode

  test "rotations":
    var g = qrImage("rotated")
    for i in 1 .. 3:
      g = g.rotate90
      check decodeText(g) == @["rotated"]

  test "inverted needs tryInvert":
    let g = qrImage("inverted").invert
    check decodeText(g) == @["inverted"]
    var o = DecodeOptions.init()
    o.tryInvert = false
    check decodeText(g, o).len == 0

  test "low contrast and noise":
    check decodeText(qrImage("contrast").withContrast(90, 160)) == @["contrast"]
    check decodeText(qrImage("noise", scale = 6).withNoise(40, 7)) == @["noise"]

  test "padded stride":
    check decodeText(qrImage("stride").withPadding(13)) == @["stride"]

  test "multiple codes":
    let both = decodeText(sideBySide(qrImage("left"), qrImage("right")))
    check both.len == 2
    check "left" in both
    check "right" in both

  test "roi restricts the search":
    let g = sideBySide(qrImage("left"), qrImage("right"))
    var o = DecodeOptions.init()
    o.roi = Opt.some NormRect(x: 0.5, y: 0, w: 0.5, h: 1)
    let r = decode(g.view, o).get
    check r.len == 1
    check r[0].text == "right"
    check r[0].corners[0].x > 0.5 # corners are in full-image coordinates

  test "format filter":
    var o = DecodeOptions.init()
    o.formats = {bfDataMatrix}
    check decodeText(qrImage("qr only"), o).len == 0

  test "no code -> empty, not error":
    let blank = GrayImage(data: newSeq[byte](100 * 100), width: 100, height: 100,
                          rowStride: 100)
    check decode(blank.view).get.len == 0

  test "corners are normalized and ordered":
    let c = decode(qrImage("corners").view).get[0].corners
    for p in c:
      check p.x >= 0 and p.x <= 1
      check p.y >= 0 and p.y <= 1
    check c[0].x < c[1].x # topLeft left of topRight
    check c[0].y < c[3].y # topLeft above bottomLeft

  test "utf8 and binary payloads": # Review Focus 5
    let utf = "Žabac 🐸 — ünïcödé"
    check decode(qrImage(utf).view).get[0].text == utf
    let bin = @[0'u8, 1, 2, 255, 0, 128, 7]
    check decode(qrImageBytes(bin).view).get[0].bytes == bin
    let long = repeat("cs3:", 300) # long, sync-code-like payload
    check decodeText(qrImage(long, scale = 2)) == @[long]

  test "invalid input": # Review Focus 4
    var buf = newSeq[byte](16)
    check decode(LumaView(data: nil, len: 0, width: 4, height: 4, rowStride: 4)).isErr
    check decode(lumaView(buf, 0, 4, 4)).error.kind == dekInvalidInput # zero width
    check decode(lumaView(buf, 4, 4, 3)).error.kind == dekInvalidInput # stride < width
    check decode(lumaView(buf, 4, 5, 4)).error.kind == dekInvalidInput # too short
    check decode(lumaView(buf, -1, 4, 4)).error.kind == dekInvalidInput # negative
    discard decode(lumaView(buf, 4, 4, 4)) # tiny but valid: must not crash
