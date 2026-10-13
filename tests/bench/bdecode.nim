## 1080p decode benchmark (prints; asserts nothing). Run: make bench
import std/[algorithm, monotimes, times, strformat]
import ../../qrscan
import ../qrgen

proc frameWithCode(w, h: int): GrayImage =
  result = GrayImage(width: w, height: h, rowStride: w, data: newSeq[byte](w * h))
  for i in 0 ..< result.data.len:
    result.data[i] = 128
  result = result.withNoise(30, 3)
  let qr = qrImage("0x0123456789abcdef0123456789abcdef01234567", scale = 8)
  let ox = (w - qr.width) div 2
  let oy = (h - qr.height) div 2
  for y in 0 ..< qr.height:
    for x in 0 ..< qr.width:
      result.data[(oy + y) * w + ox + x] = qr.data[y * qr.rowStride + x]

proc downscale(g: GrayImage, maxDim: int): GrayImage =
  let k = max(1, (max(g.width, g.height) + maxDim - 1) div maxDim)
  result = GrayImage(width: g.width div k, height: g.height div k, rowStride: g.width div k)
  result.data = newSeq[byte](result.width * result.height)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result.data[y * result.width + x] = g.data[y * k * g.rowStride + x * k]

proc bench(name: string, g: GrayImage, runs = 50) =
  var ms: seq[float]
  for i in 0 ..< runs:
    let t0 = getMonoTime()
    let r = decode(lumaView(g.data, g.width, g.height, g.rowStride))
    ms.add (getMonoTime() - t0).inMicroseconds.float / 1000
    doAssert r.isOk and r.get.len == 1
  ms.sort()
  echo &"{name:<22} {g.width}x{g.height}: median {ms[ms.len div 2]:.1f} ms, p95 {ms[int(ms.len.float * 0.95)]:.1f} ms"

let full = frameWithCode(1920, 1080)
bench("1080p, default options", full)
bench("downscaled to 640px", full.downscale(640))
