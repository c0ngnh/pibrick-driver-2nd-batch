// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// QML extension plugin entry point for the piBrick autorotation tile.
//
// Following the upstream screenrotation pattern (see
// plasma-mobile/quicksettings/screenrotation/screenrotationplugin.cpp),
// this file declares a QQmlExtensionPlugin and registers the helper
// class as a singleton under the URI the quicksetting QML imports.
//
// The qmldir in the install dir points the QML engine at this plugin via:
//   module org.kde.plasma.quicksetting.pibrick-autorotation
//   plugin pibrick-autorotation-plugin
//   classname PibrickAutorotationPlugin

#include <QQmlEngine>
#include <QQmlExtensionPlugin>

#include "pibrick-autorotation-util.h"

class PibrickAutorotationPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QQmlExtensionInterface")

public:
    void registerTypes(const char *uri) override
    {
        Q_ASSERT(QLatin1String(uri)
                 == QLatin1String("org.kde.plasma.quicksetting.pibrick-autorotation"));
        qmlRegisterSingletonType<PibrickAutorotationUtil>(
            uri, 1, 0, "PibrickAutorotationUtil",
            [](QQmlEngine *, QJSEngine *) -> QObject * {
                return new PibrickAutorotationUtil;
            });
    }
};

#include "pibrick-autorotation-plugin.moc"
