import QtQuick

// Decodes frames from a host-defined frame source and emits tagFound.
// Requires the `nimQrScanBackend` context property (qrscan/qml install()).
QtObject {
    id: root

    // Host-defined source handle (e.g. a NimQtCamera FrameTap's handle); 0 = none.
    property int frameSource: 0
    property bool scanning: true
    property bool tryHarder: true
    property bool tryRotate: true
    property bool tryInvert: true
    property var formats: ["QRCode"]

    readonly property int handle: d.handle
    readonly property string lastTag: d.lastTag
    readonly property real lastDecodeMs: d.lastDecodeMs

    // Every successful decode (lastTag only changes when the text differs).
    signal tagFound(string tag)

    function applyOptions() {
        nimQrScanBackend.setOptions(d.handle, tryHarder, tryRotate, tryInvert, formats.join(","))
    }

    onFrameSourceChanged: nimQrScanBackend.bindSource(d.handle, frameSource)
    onScanningChanged: nimQrScanBackend.setScanning(d.handle, scanning)
    onTryHarderChanged: applyOptions()
    onTryRotateChanged: applyOptions()
    onTryInvertChanged: applyOptions()
    onFormatsChanged: applyOptions()

    Component.onCompleted: {
        applyOptions()
        nimQrScanBackend.setScanning(d.handle, scanning)
        nimQrScanBackend.bindSource(d.handle, frameSource)
    }

    Component.onDestruction: nimQrScanBackend.destroyScanner(d.handle)

    readonly property QtObject _d: QtObject {
        id: d

        // Created on first read and cached: re-evaluating this binding must not
        // create another scanner. `cache` is a plain JS object (no notify).
        readonly property var cache: ({ handle: 0 })
        readonly property int handle: {
            if (cache.handle === 0)
                cache.handle = nimQrScanBackend.createScanner()
            return cache.handle
        }
        property string lastTag
        property real lastDecodeMs
    }

    readonly property Connections _backendConnection: Connections {
        target: nimQrScanBackend

        function onScanResult(h, text, decodeMs) {
            if (h !== d.handle)
                return
            d.lastDecodeMs = decodeMs
            d.lastTag = text
            root.tagFound(text)
        }
    }
}
