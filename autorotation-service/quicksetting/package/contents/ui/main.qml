// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation —
// PURE-QML FALLBACK that works without the C++ plugin.
//
// This is the DEFAULT tile that loads when the C++ QML plugin is not available.
// It reads the lock state from /var/lib/pibrick/autorotation.lock via Process.
//
// Why a fallback exists:
//   The stateful tile imports a QML module registered by a C++ plugin.
//   If that plugin is missing (build failed, no g++ available, Qt6 not installed, etc.),
//   the QML engine fails to resolve the import and the tile is silently
//   dropped from the drawer. This pure-QML version always loads.
//
// What it does:
//   - Reads /var/lib/pibrick/autorotation.lock via Process every second
//     to keep the tile "enabled" property in sync with reality.
//   - Tapping the tile calls /usr/bin/autorotation-lock via ShellUtil.executeCommand.
//   - Works on both KDE Plasma Mobile and Phosh (uses shell-agnostic approach).

import QtQuick

import org.kde.plasma.private.mobileshell as MobileShell
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper:   "/usr/bin/autorotation-lock"

    // True when auto-rotation is currently enabled (lock file absent or empty)
    property bool isAuto: true

    text: isAuto ? i18n("Auto-rotate") : i18n("Rotation locked")
    icon: "object-rotate-right-symbolic"
    status: isAuto
        ? i18nc("@info:status quick setting is on", "On")
        : i18nc("@info:status quick setting is off", "Off")
    enabled: isAuto
    available: true

    function toggle() {
        // ShellUtil.executeCommand runs without blocking the QML engine.
        // Tap flips state — the periodic refresh below catches up.
        if (isAuto) {
            MobileShell.ShellUtil.executeCommand(helper + " normal")
        } else {
            MobileShell.ShellUtil.executeCommand(helper + " auto")
        }
    }

    Process {
        id: lockReader
        onFinished: {
            // exitCode === 0 means the file existed; non-empty body means locked
            if (exitCode === 0 && stdout !== null) {
                root.isAuto = (stdout.toString().trim().length === 0)
            } else {
                root.isAuto = true
            }
        }
    }

    function refreshState() {
        lockReader.start("cat", [lockFile])
    }

    // Keep the tile in sync with the on-disk lock state
    Timer {
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshState()
    }

    Component.onCompleted: refreshState()
}
