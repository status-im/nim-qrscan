## Shared helpers (kept apart so tests importing nimqml don't also import
## seaqt's QObject).
import seaqt/qcoreapplication

proc processEvents*() =
  QCoreApplication.processEvents()
