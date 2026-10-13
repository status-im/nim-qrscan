## Bindings to qml_shim.cpp; imported only by qrscan/qml.

{.push raises: [], gcsafe.}

import seaqt/QtCore/qtcore_pkg
import seaqt/QtQml/qtqml_pkg

{.compile("qml_shim.cpp", "-std=c++17 " & QtCoreCFlags & " " & QtQmlCFlags).}
{.passl: QtCoreLibs.}
{.passl: QtQmlLibs.}

type GuiCallback* = proc() {.cdecl, gcsafe, raises: [].}

proc shimPostToGui*(fn: GuiCallback) {.importc: "qrscan_post_to_gui".}
proc shimQmlInstall*(engine: pointer, importPath, name: cstring, qobject: pointer) {.
  importc: "qrscan_qml_install".}
