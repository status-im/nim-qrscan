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

  test "huge dimensions are rejected, not overflowed": # final review I2
    var buf = newSeq[byte](16)
    let v = LumaView(data: cast[ptr UncheckedArray[byte]](addr buf[0]), len: buf.len,
                     width: 1, height: 3, rowStride: high(int))
    check decode(v).error.kind == dekInvalidInput
    let w = LumaView(data: cast[ptr UncheckedArray[byte]](addr buf[0]), len: buf.len,
                     width: high(int), height: high(int), rowStride: high(int))
    check decode(w).error.kind == dekInvalidInput

# A real QR whose data region is damaged beyond error correction: the finder
# patterns survive, so ZXing detects the symbol but can't decode it.
proc damagedQr(): GrayImage =
  const scale = 4
  const quiet = 4
  result = qrImage("a QR code whose data region is too damaged to decode", scale, quiet, eccLow)
  let modules = result.width div scale - 2 * quiet
  for my in modules div 2 ..< modules - 9:
    for mx in modules div 2 ..< modules - 1:
      for dy in 0 ..< scale:
        for dx in 0 ..< scale:
          let i = ((my + quiet) * scale + dy) * result.rowStride + (mx + quiet) * scale + dx
          result.data[i] = 255'u8 - result.data[i]

suite "decodeReport":
  test "returnErrors counts a detected but undecodable code":
    let g = damagedQr()
    var opts = DecodeOptions.init()
    opts.returnErrors = true
    let r = decodeReport(g.view, opts)
    check r.isOk
    check r.get.codes.len == 0
    check r.get.undecodable == 1

  test "without returnErrors the damaged code is just absent":
    let g = damagedQr()
    let r = decodeReport(g.view, DecodeOptions.init())
    check r.get.codes.len == 0
    check r.get.undecodable == 0
    check decode(g.view).get.len == 0 # decode() unchanged

  test "a valid code is reported as before":
    let g = qrImage("report-ok")
    var opts = DecodeOptions.init()
    opts.returnErrors = true
    let r = decodeReport(g.view, opts)
    check r.get.codes.len == 1 and r.get.codes[0].text == "report-ok"
    check r.get.undecodable == 0

  test "a textured image without a code reports no undecodable code":
    # still-image options (as QrImageDecoder): a photo with no QR must give
    # "no code found", not "found but undecodable"
    var opts = DecodeOptions.init()
    opts.tryHarder = true
    opts.tryRotate = true
    opts.tryInvert = true
    opts.tryDownscale = true
    opts.returnErrors = true
    for seed in [1'u32, 7, 42]:
      let g = GrayImage(width: 1600, height: 1200, rowStride: 1600,
                        data: newSeq[byte](1600 * 1200)).withNoise(127, seed)
      let r = decodeReport(g.view, opts)
      check r.get.codes.len == 0
      check r.get.undecodable == 0

  test "a QR-like block texture without finder patterns reports no undecodable code":
    var opts = DecodeOptions.init()
    opts.tryHarder = true
    opts.tryRotate = true
    opts.tryInvert = true
    opts.tryDownscale = true
    opts.returnErrors = true
    var s = 12345'u32
    for cell in [4, 6, 9]:
      var g = GrayImage(width: 1200, height: 900, rowStride: 1200, data: newSeq[byte](1200 * 900))
      for cy in 0 ..< 900 div cell:
        for cx in 0 ..< 1200 div cell:
          s = s xor (s shl 13); s = s xor (s shr 17); s = s xor (s shl 5)
          let v = if (s and 1) == 1: 0'u8 else: 255'u8
          for y in 0 ..< cell:
            for x in 0 ..< cell:
              g.data[(cy * cell + y) * 1200 + cx * cell + x] = v
      let r = decodeReport(g.view, opts)
      check r.get.codes.len == 0
      check r.get.undecodable == 0
