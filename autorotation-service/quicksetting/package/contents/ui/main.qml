// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// State lives in /var/lib/pibrick/autorotation.lock — the same file the
// pibrick-autorotation daemon watches and the same file the panel
// plasmoid writes. We re-read it via a small Process-based check, NOT a
// Loader (a Loader is a visual Item; making it a child of QS.QuickSetting
// breaks the tile's layout and the Quick Drawer silently drops the entry).
//
// Tapping the tile calls /usr/bin/autorotation-lock to flip state:
//   - auto   → lock-current : locks to the current physical orientation
//                              (preserves whatever the user last saw)
//   - locked → auto         : re-enables sensor-driven rotation
//
// We poll the lock file once a second. Cheap, robust against out-of-band
// changes from the panel plasmoid, terminal scripts, or the daemon.

import QtQuick
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper:   "/usr/bin/autorotation-lock"

    // True when auto-rotation is currently active (lock file absent / empty).
    property bool isAuto: true

    // ── External property bindings (QuickSetting API) ───────────────────────────
    text: isAuto ? i18n("Auto-rotate") : i18n("Rotation locked")
    icon: "object-rotate-right-symbolic"
    enabled: isAuto
    available: true

    // ── Toggle action ────────────────────────────────────────────────────────────
    function toggle() {
        if (isAuto) {
            // Lock to whatever orientation the screen is currently showing.
            // `lock-current` reads the current compositor transform and locks
            // to it, preserving what the user sees without forcing portrait.
            helperProcess.start(helper, ["lock-current"])
        } else {
            helperProcess.start(helper, ["auto"])
        }
    }

    // ── State-read process ───────────────────────────────────────────────────────
    // We use `[ -s file ]` to test the lock file: returns 0 (success) when
    // the file exists and has size, which means "rotation is locked".
    // `echo auto` is the success branch label; we then map 0 → locked,
    // non-zero → auto.
    //
    // The Process is non-visual — it is not a child Item in the QML tree, so
    // it does not interfere with QS.QuickSetting's internal layout.
    Process {
        id: stateReader
        onFinished: {
            // exitCode 0 → file exists & has size → locked (isAuto = false).
            // Anything else (file missing, empty, error) → auto (isAuto = true).
            root.isAuto = (exitCode !== 0)
        }
    }

    function readState() {
        // Test the lock file. stdout/stderr are discarded — the only signal
        // we care about is the exit code.
        stateReader.start("/bin/sh", ["-c",
            "[ -s '" + lockFile + "' ] && echo locked || echo auto"])
    }

    // ── Toggle process ───────────────────────────────────────────────────────────
    Process {
        id: helperProcess
        onFinished: refreshTimer.restart()
    }

    // Small delay so the helper has time to write the lock file before we re-read.
    Timer {
        id: refreshTimer
        interval: 250
        repeat: false
        onTriggered: root.readState()
    }

    // ── Periodic refresh keeps the tile in sync ──────────────────────────────────
    Timer {
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.readState()
    }

    Component.onCompleted: readState()
}