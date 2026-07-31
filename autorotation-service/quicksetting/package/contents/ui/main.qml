// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// State lives in /var/lib/pibrick/autorotation.lock — the same file the
// pibrick-autorotation daemon watches and the same file the panel
// plasmoid writes. We re-read it via the KDE "executable" data engine
// (PlasmaCore.DataSource { engine: "executable" }) which is the
// canonical way to fork a child process from QML without writing a C++
// plugin. (QML itself has no Process type; QProcess is a C++ class
// that must be exposed via qmlRegisterType to be reachable from QML.)
//
// Tapping the tile calls /usr/bin/autorotation-lock to flip state:
//   - auto   → lock-current : locks to the current physical orientation
//                              (preserves whatever the user last saw)
//   - locked → auto         : re-enables sensor-driven rotation
//
// We poll the lock file once a second. Cheap, robust against out-of-band
// changes from the panel plasmoid, terminal scripts, or the daemon.

import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper:   "/usr/bin/autorotation-lock"

    // ── External property bindings (QuickSetting API) ───────────────────────────
    // True when auto-rotation is currently active (lock file absent / empty).
    // We start with the optimistic "auto" default; the first poll below
    // corrects it within a second.
    property bool isAuto: true

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
            helperRunner.run([helper, "lock-current"])
        } else {
            helperRunner.run([helper, "auto"])
        }
        // Optimistically flip the local state. The follow-up poll will
        // re-sync with the lock file in case the helper exited non-zero.
        root.isAuto = !root.isAuto
    }

    // ── State-read shell helper (PlasmaCore.DataSource, "executable" engine) ────
    // The shell command tests the lock file: exists & non-empty → "locked",
    // missing/empty → "auto". We pass the command as an array so
    // PlasmaCore.DataSource tokenises it with shell-safe quoting.
    //
    // The engine buffers a single pending command per DataSource: calling
    // connectSource() while another source is still running replaces the
    // pending one. We therefore don't pre-emptively disconnect — onNewData
    // handles the teardown when the current run finishes.
    PlasmaCore.DataSource {
        id: lockChecker
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            // exitCode 0 → file exists & has size → locked (isAuto = false).
            // Anything else (file missing, empty, error) → auto (isAuto = true).
            var exitCode = (data && typeof data["exit code"] !== "undefined")
                           ? data["exit code"] : -1
            root.isAuto = (exitCode !== 0)
            lockChecker.disconnectSource(sourceName)
        }
        function run(cmd) {
            lockChecker.connectSource(cmd)
        }
    }

    function readState() {
        // `[ -s <file> ]` returns exit 0 when file is non-empty.
        lockChecker.run(["/bin/sh", "-c",
            "[ -s '" + lockFile + "' ] && echo locked || echo auto"])
    }

    // ── Toggle shell helper (also "executable" engine) ──────────────────────────
    PlasmaCore.DataSource {
        id: helperRunner
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            // Always disconnect so the next run() starts fresh.
            helperRunner.disconnectSource(sourceName)
        }
        function run(cmd) {
            helperRunner.connectSource(cmd)
        }
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