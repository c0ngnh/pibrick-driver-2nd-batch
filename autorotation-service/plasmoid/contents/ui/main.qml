import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

// ── piBrick Rotation Lock Plasmoid ────────────────────────────────────────────
// Plasma 6.x compatible QML
// Required: /usr/bin/pibrick-autorotation-ctl (installed by pibrick-autorotation install.sh)

Item {
    id: root
    anchors.fill: parent

    // ── Paths ────────────────────────────────────────────────────────────────
    readonly property string lockFile: "/var/lib/pibrick/autorotation.lock"
    readonly property string helper: "/usr/bin/pibrick-autorotation-ctl"

    // ── State ────────────────────────────────────────────────────────────────
    property bool isLocked: false
    property string lockedOrientation: ""
    property bool isWorking: false

    // ── Read lock state from file ─────────────────────────────────────────────
    function readLockFile() {
        try {
            var file = lockFileHandle
            if (file.status === Loader.Ready) {
                return file.item.text.trim()
            }
        } catch(e) {}
        return ""
    }

    Loader {
        id: lockFileHandle
        source: lockFile
        onLoaded: {
            isLocked = item.text.trim().length > 0
            lockedOrientation = isLocked ? item.text.trim() : ""
        }
    }

    // ── Run helper via Process ──────────────────────────────────────────────
    function runCtl(cmd, args) {
        isWorking = true
        helperProcess.start(helper, [cmd].concat(args || []))
    }

    Process {
        id: helperProcess
        onFinished: {
            isWorking = false
            if (exitCode === 0) {
                // Refresh state
                lockFileHandle.active = false
                lockFileHandle.active = true
            }
        }
    }

    function refreshStatus() {
        lockFileHandle.active = false
        lockFileHandle.active = true
    }

    // ── Actions ──────────────────────────────────────────────────────────────
    function lockTo(ori) {
        runCtl("lock", [ori])
    }

    function unlock() {
        runCtl("unlock", [])
    }

    // ── Helpers ─────────────────────────────────────────────────────────────
    function iconName() {
        if (!isLocked) return "transform-move"
        return {
            normal: "phone-portrait",
            right: "phone-landscape",
            inverted: "phone-portrait-inverted",
            left: "phone-landscape-inverted"
        }[lockedOrientation] || "transform-move"
    }

    function displayLabel(ori) {
        return {
            normal: "Portrait",
            right: "Landscape",
            inverted: "Portrait ↓",
            left: "Landscape ←"
        }[ori] || ori
    }

    // ── UI ──────────────────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.smallSpacing

        // Header
        RowLayout {
            Layout.fillWidth: true

            PlasmaComponents.ToolButton {
                action: Kirigami.Action {
                    icon.name: "window-close"
                    onTriggered: root.ParentDialog.close()
                }
            }

            Kirigami.Heading {
                text: i18n("Screen Rotation")
                level: 3
                Layout.fillWidth: true
            }
        }

        // Status
        QQC2.Label {
            Layout.fillWidth: true
            text: isWorking ? i18n("Applying…") :
                  isLocked  ? i18n("Locked: %1", displayLabel(lockedOrientation))
                             : i18n("Auto-rotation is ON")
            color: Kirigami.Theme.disabledTextColor
            font.pixelSize: Kirigami.Units.gridUnit * 0.8
        }

        // Auto-rotate toggle row
        RowLayout {
            Layout.fillWidth: true

            QQC2.Label {
                text: i18n("Auto-rotate")
                Layout.fillWidth: true
            }

            QQC2.Switch {
                checked: !isLocked
                enabled: !isWorking
                onToggled: {
                    if (!checked) {
                        // Lock to current orientation
                        root.lockTo("normal")
                        checked = true // revert - user must choose orientation
                    } else {
                        root.unlock()
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Kirigami.Theme.separatorColor
        }

        // 2×2 orientation grid
        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 2
            rowSpacing: Kirigami.Units.smallSpacing
            columnSpacing: Kirigami.Units.smallSpacing

            OriButton {
                label: i18n("Portrait")
                icon: "phone-portrait"
                active: isLocked && lockedOrientation === "normal"
                enabled: !isWorking
                onClicked: {
                    root.lockTo("normal")
                    root.ParentDialog.close()
                }
            }

            OriButton {
                label: i18n("Landscape")
                icon: "phone-landscape"
                active: isLocked && lockedOrientation === "right"
                enabled: !isWorking
                onClicked: {
                    root.lockTo("right")
                    root.ParentDialog.close()
                }
            }

            OriButton {
                label: i18n("Portrait ↓")
                icon: "phone-portrait-inverted"
                active: isLocked && lockedOrientation === "inverted"
                enabled: !isWorking
                onClicked: {
                    root.lockTo("inverted")
                    root.ParentDialog.close()
                }
            }

            OriButton {
                label: i18n("Landscape ←")
                icon: "phone-landscape-inverted"
                active: isLocked && lockedOrientation === "left"
                enabled: !isWorking
                onClicked: {
                    root.lockTo("left")
                    root.ParentDialog.close()
                }
            }
        }

        // Unlock + Close buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Button {
                Layout.fillWidth: true
                visible: isLocked
                enabled: !isWorking
                text: i18n("Unlock")
                icon.name: "transform-move"
                onClicked: root.unlock()
            }

            PlasmaComponents.Button {
                Layout.fillWidth: true
                text: i18n("Close")
                icon.name: "window-close"
                onClicked: root.ParentDialog.close()
            }
        }
    }

    // ── Component: Orientation Button ─────────────────────────────────────────
    readonly property Component OriButton: Component {
        PlasmaComponents.Button {
            property string label: ""
            property string icon: ""
            property bool active: false
            property bool enabled: true

            Layout.fillWidth: true
            Layout.fillHeight: true

            contentItem: Column {
                anchors.centerIn: parent
                spacing: Kirigami.Units.smallSpacing

                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Kirigami.Units.iconSize.medium
                    height: Kirigami.Units.iconSize.medium
                    source: "image://icon/" + icon
                    ColorOverlay {
                        anchors.fill: parent
                        source: parent
                        color: active
                            ? Kirigami.Theme.highlightColor
                            : Kirigami.Theme.textColor
                    }
                }

                QQC2.Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: label
                    horizontalAlignment: Text.AlignHCenter
                    font.weight: active ? Font.Bold : Font.Normal
                    font.pixelSize: Kirigami.Units.gridUnit * 0.7
                    color: active ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                    wrapMode: Text.WordWrap
                }
            }

            background: Rectangle {
                anchors.fill: parent
                radius: Kirigami.Units.smallSpacing
                color: active
                    ? Kirigami.Theme.highlightBackgroundColor
                    : Kirigami.Theme.buttonBackgroundColor
                border.width: active ? 2 : 1
                border.color: active
                    ? Kirigami.Theme.highlightColor
                    : Kirigami.Theme.separatorColor
            }
        }
    }

    Component.onCompleted: refreshStatus()
}
