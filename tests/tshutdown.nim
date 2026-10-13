## The backend must stop and join its worker when the application quits, even
## with a decode in flight (final review I5).

import std/[unittest, os]
import nimqml
import ../qrscan/qml
import ./qrgen

putEnv("QT_QPA_PLATFORM", "offscreen")

let frames = FrameSource(
  attach: proc(source, scanner: int) {.gcsafe, raises: [].} = discard,
  requestNext: proc(source: int) {.gcsafe, raises: [].} = discard,
  detach: proc(source: int) {.gcsafe, raises: [].} = discard)

let app = newQGuiApplication()
let engine = newQQmlApplicationEngine()
install(engine, frames)
engine.loadData("""
import QtQuick
import NimQrScan 1.0
Item {
  QrScanner { id: scanner; frameSource: 1; Component.onCompleted: reporterHandle = handle }
  property int reporterHandle: 0
  Timer { interval: 50; running: true; onTriggered: Qt.quit() }
}
""")

# A slow decode that is still running when the app quits.
let big = GrayImage(width: 3000, height: 3000, rowStride: 3000,
                    data: newSeq[byte](3000 * 3000)).withNoise(127, 9)
deliverFrame(1, big.data, big.width, big.height, big.rowStride)

suite "shutdown":
  test "aboutToQuit stops the worker and later calls are ignored":
    check qrScanBackend().workerRunning
    app.exec() # Timer -> Qt.quit() -> aboutToQuit
    check qrScanBackend().isShutDown
    check not qrScanBackend().workerRunning
    deliverFrame(1, big.data, big.width, big.height, big.rowStride) # ignored, no crash
    shutdownQrScan() # idempotent
