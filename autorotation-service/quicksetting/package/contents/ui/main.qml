// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// What this tile binds to:
//   The bindable PibrickAutorotationUtil singleton (from the
//   org.kde.plasma.quicksetting.pibrick-autorotation QML module — a tiny
//   C++ plugin installed alongside this package under
//   /usr/lib/qt6/qml/...).
//
//   Why a singleton instead of a JS-only implementation:
//     QML in quicksettings packages cannot run external commands
//     directly — DataSource and Process are unavailable. Upstream
//     solves the same problem by shipping a C++ QML module per
//     quicksetting (see quicksettings/screenrotation/ in plasma-mobile).
//     We follow the same pattern but with a much smaller surface: a
//     single Q_PROPERTY that's true when /usr/bin/autorotation-lock is
//     in "auto" mode, false when a manual lock is active.
//
// Tapping the tile calls PibrickAutorotationUtil.lockCurrent() (when
// auto is on) or PibrickAutorotationUtil.enableAuto() (when locked).
// Both invokables run /usr/bin/autorotation-lock under the hood, then
// re-read ~/.config/kwinoutputconfig.json after a short delay and emit
// autoRotationEnabledChanged so the tile highlights/un-highlights.

import QtQuick

import org.kde.plasma.private.mobileshell as MobileShell
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS
import org.kde.plasma.quicksetting.pibrick-autorotation 1.0

QS.QuickSetting {
    id: root

    text: enabled ? i18n("Auto-rotate") : i18n("Rotation locked")
    icon: enabled ? "object-rotate-right-symbolic" : "object-rotate-right-symbolic"
    status: enabled
            ? i18nc("@info:status quick setting is on", "On")
            : i18nc("@info:status quick setting is off", "Off")
    enabled: PibrickAutorotationUtil.autoRotationEnabled
    available: true

    function toggle() {
        if (enabled) {
            PibrickAutorotationUtil.lockCurrent()
        } else {
            PibrickAutorotationUtil.enableAuto()
        }
    }
}
