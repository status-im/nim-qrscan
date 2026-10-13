## nim-qrscan: QR/barcode decoding from 8-bit grayscale images (zxing-cpp).
## Core API; see qrscan/worker (background decoding), qrscan/capi (C ABI) and
## qrscan/qml (QML scanner).

import qrscan/[types, decode]
export types, decode
