# nim-qrscan

QR / barcode decoding for Nim, over [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp)
(v3.1.1, C API). The library doesn't know where an image came from (a camera,
a file, a Logos module, a test): it decodes 8-bit grayscale buffers.

Work in progress — see `docs/spike-results.md`.

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
QrScanner { frameSource: someSourceHandle; onTagFound: tag => console.log(tag) }
```

With nim-qtcamera, the glue is a few lines over its FrameTap
(`setTapConsumer` → `deliverFrame`, `armTap` → `requestNext`); see
`examples/scan`.

Threading and pull model: decoding runs on one background thread. The scanner
requests the next frame only after the previous result arrives, so at most one
decode is in flight; results are posted back to the GUI thread.

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
- Thread-safe: calls may run concurrently on different threads.
- Build: `make capi` → `build/libqrscan.a`. Link it with `build/zxing/core/libZXing.a`
  and the C++ runtime (`-lc++` on Apple/Android, `-lstdc++` on Linux).

## Development

```sh
make deps     # zxing-cpp submodule + pinned Nim deps into .deps/
make zxing    # static libZXing.a (readers + C API)
make test     # Nim test suites
make ctest    # C interface test (incl. two threads)
```
