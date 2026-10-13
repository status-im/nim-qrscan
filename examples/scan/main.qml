import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import NimQtCamera 1.0
import NimQrScan 1.0

ApplicationWindow {
    width: 900
    height: 700
    visible: true
    title: "nim-qrscan demo"

    MediaDevices { id: mediaDevices }

    CameraAccess {
        id: access
        Component.onCompleted: if (status === "undetermined") request()
    }

    CaptureSession {
        camera: Camera {
            id: camera
            active: access.granted && Qt.application.state === Qt.ApplicationActive
            focusMode: Camera.FocusModeAutoNear
        }
        videoOutput: preview
    }

    FrameTap {
        id: tap
        videoSink: preview.videoSink
        enabled: camera.active
        maxFps: 10
        maxDim: 1024
    }

    QrScanner {
        id: scanner
        frameSource: tap.handle
        scanning: camera.active
        onTagFound: tag => {
            results.insert(0, { text: tag, ms: scanner.lastDecodeMs.toFixed(1) })
            if (results.count > 10)
                results.remove(10)
        }
    }

    ListModel { id: results }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12

        RowLayout {
            ComboBox {
                Layout.preferredWidth: 260
                model: mediaDevices.videoInputs
                textRole: "description"
                onActivated: camera.cameraDevice = mediaDevices.videoInputs[currentIndex]
            }
            Label {
                visible: access.status === "denied"
                text: access.canOpenSettings ? "Camera access is off"
                                             : "Enable camera access in your system settings"
                color: "red"
            }
            Button {
                visible: access.status === "denied" && access.canOpenSettings
                text: "Open settings"
                onClicked: access.openSettings()
            }
        }

        VideoOutput {
            id: preview
            Layout.fillWidth: true
            Layout.fillHeight: true
            fillMode: VideoOutput.PreserveAspectCrop
        }

        Label { text: "Last results (decode ms):" }
        Repeater {
            model: results
            Label { text: `${model.ms} ms   ${model.text}`; elide: Text.ElideRight; Layout.fillWidth: true }
        }
    }
}
