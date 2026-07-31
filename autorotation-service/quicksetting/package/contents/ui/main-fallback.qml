// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plasma Mobile Quick Drawer entry for piBrick autorotation.
//
// This is the FALLBACK QML used when the QML extension plugin
// (plugin-src/) was not built or did not install correctly.
//
// Why a fallback exists:
//   The stateful tile imports a QML module registered by a C++ plugin.
//   If that plugin is missing (build failed, no g++ available, etc.),
//   the QML engine fails to resolve the import and the tile is silently
//   dropped from the drawer. So we ship this static, no-dependency
//   version that always loads.
//
// Limitations of the fallback:
//   - The tile always shows "Auto-rotate" / "On".
//   - Tapping always runs `autorotation-lock auto` (re-enables
//     auto-rotation regardless of current state). Idempotent.
//   - The stateful toggle is only available via the panel plasmoid,
//     which has the full Python toolchain behind it.
//
// The stateful version (with plugin) is in package/contents/ui/main.qml
// and is the default — install.sh chooses this one when the plugin
// builds. This fallback lives next to it.

import QtQuick

import org.kde.plasma.private.mobileshell as MobileShell
import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

QS.QuickSetting {
    text: i18n("Auto-rotate")
    icon: "object-rotate-right-symbolic"
    status: i18nc("@info:status quick setting is on", "On")
    enabled: true
    available: true

    function toggle() {
        // MobileShell.ShellUtil.executeCommand is the shell's own helper
        // for quicksettings; it shells out without blocking the QML engine.
        MobileShell.ShellUtil.executeCommand("/usr/bin/autorotation-lock auto")
    }
}
