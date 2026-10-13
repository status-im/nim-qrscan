## Camera → QR scanner demo. The glue below is all it takes to feed
## nim-qrscan from nim-qtcamera; neither library imports the other.
## Run: make example-deps QTCAMERA_URL=<nim-qtcamera repo> && make example

import std/os
import nimqml
import qtcamera/types as camtypes
import qtcamera/qml as cam
import qrscan/qml as scan

proc cameraFrames(): scan.FrameSource =
  ## A frame source is a NimQtCamera FrameTap handle.
  scan.FrameSource(
    attach: proc(source, scanner: int) {.gcsafe, raises: [].} =
      cam.setTapConsumer(source, proc(f: sink camtypes.GrayFrame) {.gcsafe, raises: [].} =
        scan.deliverFrame(scanner, f.data, f.width, f.height, f.width)),
    requestNext: proc(source: int) {.gcsafe, raises: [].} =
      cam.armTap(source),
    detach: proc(source: int) {.gcsafe, raises: [].} =
      cam.setTapConsumer(source, nil))

let app = newQGuiApplication()
let engine = newQQmlApplicationEngine()
cam.install(engine)
scan.install(engine, cameraFrames())
engine.load(currentSourcePath().parentDir() / "main.qml")
app.exec()
