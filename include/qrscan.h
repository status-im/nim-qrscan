/* nim-qrscan C interface.
 *
 * Decodes QR codes (and other zxing formats) from an 8-bit grayscale image.
 * The library doesn't care where the image came from (camera, file, ...).
 *
 * Link: libqrscan.a + libZXing.a + the C++ runtime (-lc++ on Apple/Android,
 * -lstdc++ on Linux; the MSVC runtime on Windows).
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call once per process, before any other function (initializes the Nim
   runtime). Not needed when the library is used from Nim. */
void qrscan_init(void);

/* Library version. Static string: do not free. */
const char* qrscan_version(void);

/* Decodes an 8-bit grayscale image: pixel (x, y) is data[y * row_stride + x],
   `len` bytes are readable.

   options_json may be NULL (defaults: QR codes, try harder/rotate/invert/
   downscale) or an object with any of:
     {"formats":["QRCode","MicroQRCode","RMQRCode","DataMatrix","Aztec","PDF417"],
      "tryHarder":true, "tryRotate":true, "tryInvert":true, "tryDownscale":true,
      "maxResults":0, "roi":{"x":0,"y":0,"w":1,"h":1}}   (roi: normalized 0..1)

   Returns a malloc'ed UTF-8 JSON string, never NULL; free it with qrscan_free:
     {"ok":true,"codes":[{"text":"...","bytes":"<lowercase hex>","format":"QRCode",
                          "corners":[[x,y],[x,y],[x,y],[x,y]]}]}
       corners: topLeft, topRight, bottomRight, bottomLeft, normalized 0..1
     {"ok":false,"error":{"kind":"invalidInput"|"invalidOptions"|"engine","message":"..."}}

   Thread-safe: may be called concurrently from different threads. */
char* qrscan_decode_luma(const uint8_t* data, size_t len, int width, int height,
                         int row_stride, const char* options_json);

/* Frees a string returned by this library. NULL is ignored. */
void qrscan_free(char* p);

#ifdef __cplusplus
}
#endif
