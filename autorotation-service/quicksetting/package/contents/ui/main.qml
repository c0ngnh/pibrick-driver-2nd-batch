// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// What we have access to:
//   - QS.QuickSetting (the tile API; required by the drawer)
//   - MobileShell.ShellUtil.executeCommand (a C++ helper exposed by the
//     shell's own private mobileshell module — see, for example, the
//     upstream VPN quicksetting at
//     https://invent.kde.org/kkofler/plasma-mobile/-/blob/kkofler/vpn-quicksetting/quicksettings/vpn/contents/ui/main.qml
//     which uses the same pattern to run its toggle-vpn.sh helper).
//
// What we do NOT have access to:
//   - org.kde.plasma.core.DataSource — PlasmaCore is importable in
//     quicksettings but DataSource is not registered for this engine.
//     Trying it gives: "PlasmaCore.DataSource is not a type".
//   - QtQuick.Process — no such QML type in Qt 6. QProcess is C++-only.
//   - D-Bus calls from QML — also C++-only here.
//
// Strategy:
//   On tap, MobileShell.ShellUtil.executeCommand runs
//   /usr/bin/autorotation-lock with the argument the lock helper needs
//   for the *current* orientation.
//
//   We cannot poll the lock file from QML to read the state, so the tile
//   shows a single, idempotent action: "Re-enable auto-rotation". If
//   rotation is already auto, tapping it is a harmless no-op. If it is
//   locked (by the panel plasmoid, the daemon, or a previous user
//   gesture), a tap re-enables sensor-driven rotation. This matches the
//   pattern of several upstream tiles that surface a single-shot action
//   rather than a true two-state toggle.
//
//   For "lock current orientation" the user uses the panel plasmoid
//   (which has the full QML/Python toolchain behind it and can poll the
//   lock file via its WorkerScript).

import QtQuick

import org.kde.plasma.private.mobileshell as MobileShell
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string helper: "/usr/bin/autorotation-lock"

    text: i18n("Auto-rotate")
    icon: "object-rotate-right-symbolic"
    status: i18nc("@info:status quick setting is on", "On")
    enabled: true
    available: true

    function toggle() {
        // MobileShell.ShellUtil.executeCommand is the C++ helper the
        // shell exposes for quicksettings; it calls KShell::splitArgs
        // + KProcess::startDetached internally, so the helper runs
        // out-of-process and we do not block the QML engine.
        // Passing just "auto" is idempotent — re-enables auto-rotation
        // whether or not it was already on.
        MobileShell.ShellUtil.executeCommand(helper + " auto")
    }
}