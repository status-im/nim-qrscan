// QML-side C ABI helpers (QtCore + QtQml only), used by qrscan/qml.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

// Runs fn() on the application's (GUI) thread. Safe to call from any thread;
// does nothing without an application object.
void qrscan_post_to_gui(void (*fn)(void));

// engine: QQmlEngine*; qobject: the QObject* exposed as context property `name`.
void qrscan_qml_install(void* engine, const char* importPath, const char* name, void* qobject);

#ifdef __cplusplus
}
#endif
