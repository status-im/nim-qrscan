#include "qml_shim.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QMetaObject>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlEngine>

extern "C" void qrscan_post_to_gui(void (*fn)(void))
{
    auto* app = QCoreApplication::instance();
    if (!app || !fn)
        return;
    QMetaObject::invokeMethod(app, [fn] { fn(); }, Qt::QueuedConnection);
}

extern "C" void qrscan_on_about_to_quit(void (*fn)(void))
{
    auto* app = QCoreApplication::instance();
    if (!app || !fn)
        return;
    QObject::connect(app, &QCoreApplication::aboutToQuit, app, [fn] { fn(); });
}

extern "C" void qrscan_qml_install(void* engine, const char* importPath, const char* name, void* qobject)
{
    auto* e = static_cast<QQmlEngine*>(engine);
    if (!e)
        return;
    e->addImportPath(QString::fromUtf8(importPath));
    e->rootContext()->setContextProperty(QString::fromUtf8(name), static_cast<QObject*>(qobject));
}
