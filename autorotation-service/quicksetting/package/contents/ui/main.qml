// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation —
// PURE-QML FALLBACK that works without the C++ plugin.
//
// This is the DEFAULT tile that loads when the C++ QML plugin is not available.
// It reads the lock state from /var/lib/pibrick/autorotation.lock via
// P5Support.DataSource (engine: "executable") and writes it by invoking
// /usr/bin/autorotation-lock via MobileShell.ShellUtil.executeCommand.
//
// Why a fallback exists:
//   The stateful tile imports a QML module registered by a C++ plugin.
//   If that plugin is missing (build failed, no g++ available, Qt6 not installed, etc.),
//   the QML engine fails to resolve the import and the tile is silently
//   dropped from the drawer. This pure-QML version always loads.
//
// Why DataSource, not Process:
//   `Process {}` is the Qt 5 / QtQml idiom for spawning a child process.
//   Qt6 dropped it from the QML built-ins; it is not present on this
//   Plasma Mobile 6.3 image, so the QML engine emits "Process is not a type"
//   and the tile is silently dropped. P5Support.DataSource with the
//   "executable" engine is the Qt 6 way to run a command and read its
//   stdout from QML, and is what stock tiles (caffeine) use.

import QtQuick

import org.kde.plasma.plasma5support 2.0 as P5Support
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
    // 'enabled' here means "is the toggle in the on-state" (drives the
    // tile background tint). The delegate's MouseArea is wired
    // unconditionally — clicks always reach toggle(), regardless of this.
    enabled: isAuto
    available: true

    function toggle() {
        // ShellUtil.executeCommand runs without blocking the QML engine.
        if (isAuto) {
            MobileShell.ShellUtil.executeCommand(helper + " normal")
        } else {
            MobileShell.ShellUtil.executeCommand(helper + " auto")
        }
        // Optimistically flip the visual state so the user sees immediate
        // feedback. The periodic DataSource refresh below will reconcile
        // with the on-disk truth on the next tick.
        isAuto = !isAuto
    }

    // DataSource with engine: "executable" runs the supplied command
    // every `interval` milliseconds and emits data updates with stdout.
    // The command is `cat <lockFile>`; stdout is non-empty only when the
    // file exists and contains a lock word ("normal"/"left"/...).
    P5Support.DataSource {
        id: lockReader
        engine: "executable"
        interval: 500
        connectedSources: ["cat " + root.lockFile]
        onSourceAdded: source => {
            const out = (data && data[source] && data[source].stdout) || ""
            root.isAuto = (out.toString().trim().length === 0)
        }
    }
}
