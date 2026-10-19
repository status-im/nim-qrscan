# nim-qrscan

QR / barcode decoding for Nim, over [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp)
(v3.1.1, C API). The library doesn't know where an image came from (a camera,
a file, a Logos module, a test): it decodes 8-bit grayscale buffers.

Platforms: iOS, Android, Linux, Windows and macOS (see `docs/platforms.md`).

## Layers

| Module | What | Depends on |
|---|---|---|
| `qrscan` | `decode(LumaView, DecodeOptions)` | zxing-cpp |
| `qrscan/worker` | `DecodeWorker`: one background thread, one job in flight | core |
| `qrscan/capi` | C interface (`include/qrscan.h`) | core |
| `qrscan/qml` | QML `NimQrScan.QrScanner` over an abstract frame source | core, nimqml/seaqt |

## QML

The scanner takes frames from a **frame source** the host provides when it
installs the library. A source is any integer handle the host chooses; the
library never imports a camera library.

```nim
import nimqml, qrscan/qml

let frames = FrameSource(
  attach:      proc(source, scanner: int) = …,  # start sending frames: deliverFrame(scanner, data, w, h, stride)
  requestNext: proc(source: int) = …,          # send one more frame
  detach:      proc(source: int) = …)          # stop
install(engine, frames)                         # C++ hosts: installOnEngine(qqmlEnginePtr, frames)
```

```qml
import NimQrScan 1.0
QrScanner {
    frameSource: someSourceHandle
    onTagFound: tag => console.log(tag)          // not emitted while scanning is false
    onDecodeError: message => console.warn(message) // e.g. a source sent a bad stride
}
```

With nim-qtcamera, the glue is a few lines over its FrameTap
(`setTapConsumer` → `deliverFrame`, `armTap` → `requestNext`); see
`examples/scan`.

Threading and pull model: decoding runs on one background thread. The scanner
requests the next frame only after the previous result arrives, so at most one
decode is in flight; results are posted back to the GUI thread.

## Decoding an image

`QrImageDecoder` decodes the QR codes in a local image file, e.g. one the user
picked:

```qml
import NimQrScan 1.0

QrImageDecoder {
    id: decoder
    onDecoded: (texts, undecodable) => { /* texts: [] = no code found;
                                           undecodable > 0: found but damaged */ }
    onFailed: (kind, message) => { /* "unsupported" | "unopenable" */ }
}
// decoder.decodeFile(fileUrl)   // a file: URL or a local path
```

- Only local files are read; other URLs fail as `"unopenable"` without being
  fetched. Nothing is uploaded.
- The format comes from the content. `"unsupported"`: no decoder recognises it
  here (e.g. a text file, or HEIC where the platform can't decode it).
  `"unopenable"`: missing, empty, unreadable (permissions, I/O), or a
  recognised format that fails to read (damaged, truncated).
- Images are loaded off the GUI thread, oriented from EXIF, composited onto
  white (transparency reads as paper) and scaled to at most 3000 px on the
  longest side, then decoded on the same worker as camera frames, with
  tryHarder/tryRotate/tryInvert/tryDownscale.
- A newer `decodeFile` supersedes an older one; `cancel()` drops the pending
  one (e.g. when the scanner is closed); a destroyed decoder reports nothing.
  `busy` is true until the result or `cancel()`.

HEIC/HEIF (`heicSupported`):

| Platform | HEIC/HEIF |
|---|---|
| macOS, iOS | yes, Qt's `qmacheif` plugin (iOS: a static plugin the app must link) |
| Android | yes, the platform's `BitmapFactory` (API 28+) when Qt has no plugin |
| Windows, Linux | no (Qt ships no HEIF plugin) |

## C interface

```c
#include "qrscan.h"

qrscan_init();                                   /* once per process */
char* json = qrscan_decode_luma(pixels, len, width, height, row_stride, NULL);
/* {"ok":true,"codes":[{"text":"…","bytes":"<hex>","format":"QRCode","corners":[[x,y],…]}]} */
qrscan_free(json);
```

- `options_json` may be NULL or e.g. `{"formats":["QRCode"],"tryHarder":true,"roi":{"x":0,"y":0,"w":1,"h":1}}`.
- Errors: `{"ok":false,"error":{"kind":"invalidInput"|"invalidOptions"|"engine","message":"…"}}`.
- Every returned string is freed with `qrscan_free`.
- Thread-safe: calls may run concurrently on different threads, including
  short-lived ones (the library is built with `-d:useMalloc`, so threads that
  exit don't leak a Nim heap).
- Build: `make capi` → `build/libqrscan.a`. Link it with `build/zxing/core/libZXing.a`
  and the C++ runtime (`-lc++` on Apple/Android, `-lstdc++` on Linux).

## Example: camera → scanner

`examples/scan` wires nim-qtcamera's FrameTap into a `QrScanner` with ~10
lines of glue (`cameraFrames()` in `main.nim`). It is the only place in this
repo that uses nim-qtcamera:

```sh
make example-deps QTCAMERA_URL=<nim-qtcamera repo>   # clones it into .deps/
make example
```

## Performance

`make bench` (macOS arm64): a 1080p frame decodes in ~13 ms, a 640 px frame
in ~1.4 ms (`docs/spike-results.md`).

## zxing-cpp

Pinned at v3.1.1 (`vendor/zxing-cpp`), built static with readers and the C API
only (`make zxing`). Hosts that build zxing themselves pass
`-d:qrscanZxingLib=<path to libZXing.a>`.

Not included yet: decoding image files (PNG/JPEG).

## CI

`.github/workflows/ci.yml`, on every pull request and on pushes to `main`:

| Job | What |
|---|---|
| test (linux), test (macos) | `make test` (core, worker, QML headless) + `make ctest` |
| test (macos) | also the C test **in the iOS simulator**, and an iOS device build |
| build (android) | arm64-v8a and x86_64 build and link |
| test (windows) | core + worker suites built like desktop-app builds Nim on Windows (clang → x86_64-pc-windows-msvc, lld, /MD) |

Not in CI yet: running on an Android emulator, and the C test on Windows
(it uses pthreads).

## Development

```sh
make deps     # zxing-cpp submodule + pinned Nim deps into .deps/
make zxing    # static libZXing.a (readers + C API)
make test     # Nim test suites
make ctest    # C interface test (incl. two threads)
make bench    # 1080p decode benchmark
```
