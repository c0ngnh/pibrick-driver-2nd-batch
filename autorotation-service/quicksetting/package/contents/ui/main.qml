// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// State lives in /var/lib/pibrick/autorotation.lock — the same file the
// pibrick-autorotation daemon watches and the same file the panel plasmoid
// writes. We re-read it via a Loader (same idiom the panel plasmoid uses)
// and also kick off a reload every time the helper process completes.
//
// Tapping the tile calls /usr/bin/autorotation-lock to flip state:
//   - auto   → normal : locks to the current physical orientation
//                       (preserves whatever the user last saw)
//   - normal → auto   : re-enables sensor-driven rotation
//
// We poll the lock file once a second. Cheap, robust against out-of-band
// changes, and the tile stays correct even if some other surface (the panel
// plasmoid, a script in a terminal) mutates the lock file.

import QtQuick
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    id: root

    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper:   "/usr/bin/autorotation-lock"

    // True when auto-rotation is currently active (lock file absent / empty).
    property bool isAuto: true

    function readStateFromDisk() {
        // Force Loader to re-fetch the file (it's URL-cached).
        lockFileHandle.active = false
        lockFileHandle.active = true
    }

    Loader {
        id: lockFileHandle
        asynchronous: false
        source: lockFile
        onLoaded: {
            // When the file is missing or empty, the Loader's status is
            // Loader.Error or the loaded item is null — in both cases treat
            // the state as "auto".
            if (status === Loader.Ready && item && item.text !== undefined) {
                root.isAuto = (item.text.trim().length === 0)
            } else {
                root.isAuto = true
            }
        }
    }

    text: isAuto ? i18n("Auto-rotate") : i18n("Rotation locked")
    icon: "object-rotate-right-symbolic"
    enabled: isAuto
    available: true

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

    Process {
        id: helperProcess
        onFinished: refreshTimer.restart()
    }

    // Small delay so the helper has time to write the lock file before we re-read.
    Timer {
        id: refreshTimer
        interval: 250
        repeat: false
        onTriggered: root.readStateFromDisk()
    }

    // Periodic refresh keeps the tile in sync with the daemon / plasmoid / terminal.
    Timer {
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.readStateFromDisk()
    }

    Component.onCompleted: readStateFromDisk()
}