import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The floating surface. Laid out top to bottom as:
//   1. Header  — the plugin icon and the "OpenVPN3" title.
//   2. Status  — a coloured state dot, the connection state and, when
//                connected, the active config name.
//   3. A horizontal separator rule.
//   4. The list of available profiles, each a card with its own state dot and
//      toggle switch.
// Stronger visual grouping (a title band, a status band, a rule, then framed
// rows) makes each region legible on its own.
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

    // State palette. Derived locally so the panel does not depend on a
    // "success" colour that the shell may not expose: a saturated green for
    // connected, the theme urgent for error/connecting-fault, a muted grey for
    // off. `connecting` reuses the connected hue so the pulse still reads.
    readonly property color connectedColor: "#3fb950"
    readonly property color connectingColor: "#d29922"
    readonly property color offColor: Qt.darker(foreground, 1.9)

    // Surface tints for the framed regions, blended off the foreground so they
    // adapt to light and dark bars alike.
    readonly property color cardColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
    readonly property color cardCursorColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
    readonly property color ruleColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)

    readonly property var configs: service ? service.configs : []
    readonly property bool available: service ? service.available : false
    readonly property string overallState: service ? service.state : "disconnected"
    readonly property string activeName: service ? service.activeName : ""

    // Colour for a given state string, used by both the header status dot and
    // each row dot.
    function colorForState(state) {
        if (state === "connected") return connectedColor
        if (state === "connecting") return connectingColor
        if (state === "error") return urgent
        return offColor
    }

    // The status subtitle: the state label, plus the active config when up.
    readonly property string statusLabel: {
        if (!available) return "openvpn3 not available"
        if (overallState === "connected")
            return "Connected · " + Model.clipName(activeName)
        return Model.stateLabel(overallState)
    }

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
                spacing: Style.space(10)

                // ---- 1. Header: plugin icon + title ------------------------

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(8)

                    Item {
                        implicitWidth: Style.space(22)
                        implicitHeight: Style.space(22)

                        Image {
                            id: headerIcon
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            source: Qt.resolvedUrl("icon.svg")
                            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                            visible: false
                            layer.enabled: true
                        }

                        MultiEffect {
                            anchors.fill: headerIcon
                            source: headerIcon
                            colorization: 1.0
                            colorizationColor: root.foreground
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "OpenVPN3"
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.bold: true
                        font.pixelSize: Math.round(Qt.application.font.pixelSize * 1.15)
                        elide: Text.ElideRight
                    }
                }

                // ---- 2. Status subtitle: state dot + label -----------------

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Style.space(2)
                    spacing: Style.space(6)

                    Rectangle {
                        implicitWidth: Style.space(9)
                        implicitHeight: Style.space(9)
                        radius: width / 2
                        color: root.colorForState(root.overallState)
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.25)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.statusLabel
                        textFormat: Text.PlainText
                        color: root.available ? root.dim : root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Math.round(Qt.application.font.pixelSize * 0.9)
                        elide: Text.ElideRight
                    }
                }

                // ---- 3. Separator rule -------------------------------------

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(2)
                    Layout.bottomMargin: Style.space(2)
                    implicitHeight: 1
                    color: root.ruleColor
                }

                // ---- 4. Available profiles ---------------------------------

                Text {
                    Layout.fillWidth: true
                    visible: root.configs.length === 0 && root.available
                    text: "No configs — import one with:\nopenvpn3 config-import --config <file>.ovpn"
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.configs

                    // Each profile is a framed card so rows read as discrete
                    // units; the framed card highlights under the keyboard
                    // cursor.
                    Rectangle {
                        id: card
                        required property var modelData
                        required property int index

                        readonly property string rowState: root.service
                            ? root.service.displayState(modelData.name)
                            : "disconnected"
                        readonly property bool underCursor:
                            root.cursorActive && root.cursorIndex === index

                        Layout.fillWidth: true
                        implicitHeight: cardRow.implicitHeight + Style.space(14)
                        radius: Style.space(6)
                        color: underCursor ? root.cardCursorColor : root.cardColor
                        border.width: 1
                        border.color: underCursor ? root.ruleColor : "transparent"

                        RowLayout {
                            id: cardRow
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            anchors.topMargin: Style.space(7)
                            anchors.bottomMargin: Style.space(7)
                            spacing: Style.space(8)

                            Rectangle {
                                implicitWidth: Style.space(8)
                                implicitHeight: Style.space(8)
                                radius: width / 2
                                color: root.colorForState(card.rowState)
                                border.width: 1
                                border.color: Qt.rgba(0, 0, 0, 0.25)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(1)

                                Text {
                                    Layout.fillWidth: true
                                    text: Model.clipName(card.modelData.name)
                                    textFormat: Text.PlainText
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Math.round(Qt.application.font.pixelSize * 0.9)
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: Model.stateLabel(card.rowState)
                                    textFormat: Text.PlainText
                                    color: card.rowState === "error"
                                        ? root.urgent
                                        : root.colorForState(card.rowState)
                                    font.family: root.fontFamily
                                    font.pixelSize: Math.round(Qt.application.font.pixelSize * 0.75)
                                    elide: Text.ElideRight
                                }
                            }

                            ToggleSwitch {
                                checked: card.rowState === "connected" || card.rowState === "connecting"
                                busy: root.service ? root.service.isPending(card.modelData.name) : false
                                hasCursor: card.underCursor
                                foreground: root.foreground
                                onToggled: root.toggleRow(String(card.modelData.name))
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.service && root.service.lastError !== ""
                    text: root.service ? Model.clipError(root.service.lastError) : ""
                    textFormat: Text.PlainText
                    color: root.urgent
                    font.family: root.fontFamily
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
