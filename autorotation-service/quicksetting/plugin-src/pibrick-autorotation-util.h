// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// QML singleton helper for the piBrick autorotation Quick Drawer tile.
//
// Why this exists:
//   QML in a Plasma Mobile quicksettings package runs in a sandbox where
//   PlasmaCore.DataSource is not available, no Process type exists, and
//   D-Bus cannot be called directly. The only way to expose a *stateful*
//   bindable property to the tile is to ship a tiny C++ plugin that the
//   shell's QML engine loads from /usr/lib/qt6/qml/<uri>/.
//
//   We follow the same pattern upstream uses for org.kde.plasma.quicksetting.
//   screenrotation: a QQmlExtensionPlugin registers a singleton (see
//   quicksettings/screenrotation/screenrotationplugin.cpp in plasma-mobile).
//
// What we expose:
//   - PibrickAutorotationUtil.autoRotationEnabled  (bool, bindable)
//   - PibrickAutorotationUtil.lockCurrent()        (Q_INVOKABLE)
//   - PibrickAutorotationUtil.enableAuto()         (Q_INVOKABLE)
//
// Implementation:
//   - "state" is the per-user kwinoutputconfig.json that autorotation-lock
//     already maintains. We do not invent a parallel source of truth.
//   - toggle handlers shell out to /usr/bin/autorotation-lock; that script
//     in turn updates kwinoutputconfig.json AND tells KWin to reload via
//     D-Bus. We then re-read kwinoutputconfig.json after a short delay
//     and emit autoRotationEnabledChanged() so the tile refreshes.

#pragma once

#include <QObject>

class PibrickAutorotationUtil : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool autoRotationEnabled READ autoRotationEnabled
               WRITE setAutoRotationEnabled NOTIFY autoRotationEnabledChanged)

public:
    explicit PibrickAutorotationUtil(QObject *parent = nullptr);

    bool autoRotationEnabled() const;
    void setAutoRotationEnabled(bool enabled);

    // Helper invokables — also exposed so the QML side can use whichever
    // style is cleaner.
    Q_INVOKABLE void lockCurrent();
    Q_INVOKABLE void enableAuto();

Q_SIGNALS:
    void autoRotationEnabledChanged();

private:
    void refreshFromConfig();
    bool readAutoRotationFromConfig() const;

    QString m_helperPath { QStringLiteral("/usr/bin/autorotation-lock") };
    QString m_kwinConfigPath;          // resolved lazily on first read
    mutable bool m_cachedEnabled { true };
    mutable bool m_cacheValid { false };
};
