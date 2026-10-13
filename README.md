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
