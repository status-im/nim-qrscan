import QtQuick

// Decodes the QR codes in a local image file (e.g. picked by the user).
// Requires the `nimQrScanBackend` context property (qrscan/qml install()).
// Only local files are read; nothing is uploaded or fetched.
QtObject {
    id: root

    // True from decodeFile() until its decoded/failed signal (or cancel()).
    readonly property bool busy: d.busy

    // Whether this platform decodes HEIC/HEIF images (macOS, iOS, Android).
    readonly property bool heicSupported: nimQrScanBackend.heicSupported()

    // The texts of the codes found (possibly none), and how many codes were
    // found but could not be decoded (damaged, cut off).
    signal decoded(var texts, int undecodable)

    // The image could not be used: kind "unsupported" (no decoder for the
    // format here) or "unopenable" (missing, damaged, not a local file).
    signal failed(string kind, string message)

    // A `file:` URL or a local path. A newer call supersedes an older one.
    function decodeFile(url) {
        d.busy = true
        nimQrScanBackend.decodeImageFile(d.handle, String(url))
    }

    // Drops the pending request, if any: no decoded/failed signal for it.
    function cancel() {
        d.busy = false
        if (d.cache.handle !== 0)
            nimQrScanBackend.cancelImageDecode(d.cache.handle)
    }

    Component.onDestruction: nimQrScanBackend.destroyImageDecoder(d.handle)

    readonly property QtObject _d: QtObject {
        id: d

        // Created on first read and cached (see QrScanner.qml).
        readonly property var cache: ({ handle: 0 })
        readonly property int handle: {
            if (cache.handle === 0)
                cache.handle = nimQrScanBackend.createImageDecoder()
            return cache.handle
        }
        property bool busy: false
    }

    readonly property Connections _backendConnection: Connections {
        target: nimQrScanBackend

        function onImageDecoded(h, textsJson, undecodable) {
            if (h !== d.handle)
                return
            d.busy = false
            root.decoded(JSON.parse(textsJson), undecodable)
        }

        function onImageDecodeFailed(h, kind, message) {
            if (h !== d.handle)
                return
            d.busy = false
            root.failed(kind, message)
        }
    }
}
