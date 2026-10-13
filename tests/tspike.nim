import std/unittest
import ../qrscan/zxing
import ./qrgen

suite "zxing C API spike":
  test "decodes a generated QR code through the C API":
    let img = qrImage("status-qr-spike")
    let iv = ZXing_ImageView_new(unsafeAddr img.data[0], img.width.cint, img.height.cint,
                                 zxingImageFormatLum, img.rowStride.cint, 1)
    check iv != nil
    let opts = ZXing_ReaderOptions_new()
    let bcs = ZXing_ReadBarcodes(iv, opts)
    check bcs != nil
    check ZXing_Barcodes_size(bcs) == 1
    let t = ZXing_Barcode_text(ZXing_Barcodes_at(bcs, 0))
    check $t == "status-qr-spike"
    ZXing_free(t)
    ZXing_Barcodes_delete(bcs)
    ZXing_ReaderOptions_delete(opts)
    ZXing_ImageView_delete(iv)

  test "format names resolve":
    let qr = ZXing_BarcodeFormatFromString("QRCode")
    check qr != ZXing_BarcodeFormatFromString("Invalid")
    # ToString gives the human-readable name; FromString takes the identifier.
    let name = ZXing_BarcodeFormatToString(qr)
    check $name == "QR Code"
    ZXing_free(name)
    check ZXing_BarcodeFormatFromString("QRCode") == qr
