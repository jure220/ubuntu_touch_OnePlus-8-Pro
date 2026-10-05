/* QML module registration: import IRCam 1.0 */
#include "ircamera.h"
#include "viewfinder.h"

#include <QQmlExtensionPlugin>
#include <qqml.h>

class IRCamPlugin : public QQmlExtensionPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QQmlExtensionInterface")

 public:
  void registerTypes(const char *uri) override {
    Q_ASSERT(QLatin1String(uri) == QLatin1String("IRCam"));
    qmlRegisterType<IRCamera>(uri, 1, 0, "IRCamera");
    qmlRegisterType<IRViewfinder>(uri, 1, 0, "IRViewfinder");
  }
};

#include "plugin.moc"
