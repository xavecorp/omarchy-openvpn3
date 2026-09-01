import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The floating surface: lists every openvpn3 configuration profile, shows the
// active session in a hero line, and toggles a profile on or off per row.
Panel {
    id: root
    moduleName: "xavecorp.openvpn3"
    ipcTarget: "xavecorp.openvpn3"
    manageIpc: false

    property var service: null
    property int cursorIndex: 0
    property bool cursorActive: false

    // injectPanel() assigns these with `if ("anchorItem" in target)`, so a
    // panel that does not declare them is silently skipped and has nothing to
    // anchor its popup to.
    property var anchorItem: null
    property var hostWidget: null

    readonly property var barIdentity: hostWidget || root
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    readonly property var configs: service ? service.configs : []
    readonly property string hero: service && service.available
        ? Model.heroText(service.activeName, service.state)
        : "openvpn3 not available"

    function clampCursor() {
        if (configs.length === 0) { cursorIndex = 0; return }
        if (cursorIndex < 0) cursorIndex = 0
        if (cursorIndex > configs.length - 1) cursorIndex = configs.length - 1
    }

    function moveCursor(delta) {
        cursorActive = true
        cursorIndex += delta
        clampCursor()
    }

    function activateCursor() {
        if (configs.length === 0) return
        clampCursor()
        root.toggleRow(String(configs[cursorIndex].name))
    }

    function toggleRow(name) {
        if (!service) return
        var row = Model.rowByName(configs, name)
        if (!row) return
        // A pending row needs no guard: Service's connectConfig/disconnectConfig
        // already no-op while an action is in flight.
        service.toggleConfig(name)
    }

    onOpenedChanged: if (opened && service) service.refresh()

    // KeyboardPanel is the popup surface. The Panel base is an invisible Item
    // that owns only the open/close controller and draws nothing, so content
    // must live inside this to render.
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(360))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        // PanelKeyCatcher maps keys to semantic signals: j/k and arrows become
        // moveRequested(dx, dy), enter/space become activateRequested, escape
        // becomes closeRequested, other single characters arrive as textKey.
        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent

            onMoveRequested: function (dx, dy) {
                // First press only wakes the cursor so the highlight appears
                // where the eye already is.
                if (!root.cursorActive) { root.cursorActive = true; return }
                if (dy !== 0) root.moveCursor(dy)
            }
            onActivateRequested: if (root.cursorActive) root.activateCursor()
            onCloseRequested: root.close()
            onTextKey: function (t) {
                if (!root.service) return
                if (t === "r" || t === "R") root.service.refresh()
                else if (t === "d" || t === "D") {
                    if (root.service.activeName !== "")
                        root.service.disconnectConfig(root.service.activeName)
                }
            }

            ColumnLayout {
                id: column
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                PanelHero {
                    Layout.fillWidth: true
                    title: root.hero
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.configs.length === 0 && root.service && root.service.available
                    text: "No configs — import one with:\nopenvpn3 config-import --config <file>.ovpn"
                    color: root.dim
                    font.family: root.fontFamily
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.configs

                    RowLayout {
                        id: row
                        required property var modelData
                        required property int index

                        readonly property string rowState: root.service
                            ? root.service.displayState(modelData.name)
                            : "disconnected"

                        Layout.fillWidth: true
                        spacing: Style.space(8)

                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.name
                            color: root.foreground
                            font.family: root.fontFamily
                            elide: Text.ElideRight
                        }

                        Text {
                            text: Model.stateLabel(row.rowState)
                            color: row.rowState === "error" ? root.urgent : root.dim
                            font.family: root.fontFamily
                            elide: Text.ElideRight
                            Layout.maximumWidth: panel.contentWidth * 0.4
                        }

                        ToggleSwitch {
                            checked: row.rowState === "connected" || row.rowState === "connecting"
                            busy: root.service ? root.service.isPending(row.modelData.name) : false
                            hasCursor: root.cursorActive && root.cursorIndex === row.index
                            foreground: root.foreground
                            onToggled: root.toggleRow(String(row.modelData.name))
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.service && root.service.lastError !== ""
                    text: root.service ? root.service.lastError : ""
                    color: root.urgent
                    font.family: root.fontFamily
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
