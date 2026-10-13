## C ABI (include/qrscan.h). Build as a static library:
##   nim c --app:staticlib --noMain -d:release qrscan/capi.nim
## Every export is cdecl and never lets a Nim exception cross the boundary.

{.push raises: [], gcsafe.}

import std/json
from system/ansi_c import c_malloc, c_free
import results
import ./[types, decode]

const libraryVersion = "0.1.0"

proc NimMain() {.importc, cdecl.}

var nimInitialized: bool

proc qrscan_init() {.exportc, cdecl.} =
  if not nimInitialized:
    nimInitialized = true
    NimMain()

proc qrscan_version(): cstring {.exportc, cdecl.} =
  cstring(libraryVersion)

proc toCString(s: string): cstring =
  let p = cast[cstring](c_malloc(csize_t(s.len + 1)))
  if p == nil:
    return nil
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  cast[ptr UncheckedArray[char]](p)[s.len] = '\0'
  p

proc qrscan_free(p: cstring) {.exportc, cdecl.} =
  if p != nil:
    c_free(p)

func toHexLower(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0f)]

proc errorJson(kind, message: string): string =
  {.cast(raises: []).}:
    $(%*{"ok": false, "error": {"kind": kind, "message": message}})

proc parseOptions(text: cstring): Result[DecodeOptions, string] =
  var opts = DecodeOptions.init()
  if text == nil:
    return ok(opts)
  try:
    let j = parseJson($text)
    if j.kind != JObject:
      return err("options must be a JSON object")
    for key, value in j.pairs:
      case key
      of "formats":
        if value.kind != JArray:
          return err("formats must be an array")
        opts.formats = {}
        for f in value:
          if f.kind != JString:
            return err("formats must be strings")
          var found = false
          for bf in BarcodeFormat:
            if $bf == f.getStr:
              opts.formats.incl bf
              found = true
          if not found:
            return err("unknown format: " & f.getStr)
      of "tryHarder", "tryRotate", "tryInvert", "tryDownscale":
        if value.kind != JBool:
          return err(key & " must be a boolean")
        case key
        of "tryHarder": opts.tryHarder = value.getBool
        of "tryRotate": opts.tryRotate = value.getBool
        of "tryInvert": opts.tryInvert = value.getBool
        else: opts.tryDownscale = value.getBool
      of "maxResults":
        if value.kind != JInt or value.getInt < 0:
          return err("maxResults must be a non-negative integer")
        opts.maxResults = value.getInt
      of "roi":
        if value.kind != JObject:
          return err("roi must be an object")
        var r: NormRect
        for k in ["x", "y", "w", "h"]:
          let v = value{k}
          if v.isNil or v.kind notin {JInt, JFloat}:
            return err("roi." & k & " must be a number")
          let f = v.getFloat.float32
          case k
          of "x": r.x = f
          of "y": r.y = f
          of "w": r.w = f
          else: r.h = f
        opts.roi = Opt.some(r)
      else:
        return err("unknown option: " & key)
    ok(opts)
  except CatchableError as e:
    err("invalid JSON: " & e.msg)

proc decodeToJson(data: ptr uint8, len: csize_t, width, height, rowStride: cint,
                  optionsJson: cstring): string =
  let opts = parseOptions(optionsJson)
  if opts.isErr:
    return errorJson("invalidOptions", opts.error)
  # Clamp before converting: a length beyond int's range (e.g. a negative
  # length cast to size_t) must become a validation error, not a RangeDefect.
  let length = if len > csize_t(high(int)): high(int) else: int(len)
  let view = LumaView(data: cast[ptr UncheckedArray[byte]](data), len: length,
                      width: width.int, height: height.int, rowStride: rowStride.int)
  let r = decode(view, opts.get)
  if r.isErr:
    let kind = if r.error.kind == dekInvalidInput: "invalidInput" else: "engine"
    return errorJson(kind, r.error.msg)
  {.cast(raises: []).}:
    var codes = newJArray()
    for c in r.get:
      var corners = newJArray()
      for p in c.corners:
        corners.add %*[p.x, p.y]
      codes.add %*{"text": c.text, "bytes": toHexLower(c.bytes), "format": $c.format,
                   "corners": corners}
    $(%*{"ok": true, "codes": codes})

proc qrscan_decode_luma(data: ptr uint8, len: csize_t, width, height, rowStride: cint,
                        optionsJson: cstring): cstring {.exportc, cdecl.} =
  var json: string
  try:
    json = decodeToJson(data, len, width, height, rowStride, optionsJson)
  except CatchableError as e:
    json = errorJson("engine", e.msg)
  toCString(json)
