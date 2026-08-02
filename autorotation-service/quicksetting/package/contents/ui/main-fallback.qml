// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation —
// PURE-QML FALLBACK used when the QML extension plugin (plugin-src/) was
// not built or did not install correctly.
//
// Why a fallback exists:
//   The stateful tile imports a QML module registered by a C++ plugin.
//   If that plugin is missing (build failed, no g++ available, etc.),
//   the QML engine fails to resolve the import and the tile is silently
//   dropped from the drawer. So we ship this no-dependency version that
//   always loads.
//
// What it does:
//   - Reads /var/lib/pibrick/autorotation.lock via plain QML (`Process`)
//     every second to keep the tile "enabled" property in sync with reality.
//   - Tapping the tile flips state by calling `/usr/bin/autorotation-lock`
//     via MobileShell.ShellUtil.executeCommand — the same helper the
//     stateful path uses, so the lock file is the single source of truth.
//   - Limits: a brief race window after a tap is possible (the lock file
//     is rewritten by autorotation-lock; the next refresh catches up
//     within a second). The stateful version is preferred because it
//     reads the same lock file synchronously.

import QtQuick

import org.kde.plasma.private.mobileshell as MobileShell
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper:   "/usr/bin/autorotation-lock"

    // True when auto-rotation is currently enabled (lock file absent or
    // empty). Drives the tile's `enabled` property below.
    property bool isAuto: true

    text: isAuto ? i18n("Auto-rotate") : i18n("Rotation locked")
    icon: "object-rotate-right-symbolic"
    status: isAuto
        ? i18nc("@info:status quick setting is on", "On")
        : i18nc("@info:status quick setting is off", "Off")
    enabled: isAuto
    available: true

    function toggle() {
        // MobileShell.ShellUtil.executeCommand runs without blocking the
        // QML engine. Tap flips state — the periodic refresh below catches
        // up to whatever the helper actually wrote to the lock file.
        if (isAuto) {
            MobileShell.ShellUtil.executeCommand(helper + " normal")
        } else {
            MobileShell.ShellUtil.executeCommand(helper + " auto")
        }
    }

    Process {
        id: lockReader
        onFinished: {
            // exitCode === 0 means the file existed; non-empty body means
            // locked. Either missing-file or empty-file paths give isAuto=true.
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

    // Keep the tile in sync with the on-disk lock state. One stat per
    // second is negligible, and this also picks up out-of-band changes
    // (e.g. a tap on the panel plasmoid's popup — except the panel
    // applet has been removed; this tile is now the only entry point).
    Timer {
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshState()
    }

    Component.onCompleted: refreshState()
}
