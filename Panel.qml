import QtQuick
import QtQuick.Controls
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

    // A19: the service now tracks the active session by its object PATH, not a
    // display name. Re-derive the readable NAME from the matching row for
    // display — never render the raw object path. rowBySessionPath returns null
    // when the path is not yet merged or is ambiguous (two profiles share a
    // name), in which case there is no single honest name to show.
    readonly property string activeName: {
        if (!service || service.activeSessionPath === "") return ""
        var row = Model.rowBySessionPath(service.configs, service.activeSessionPath)
        return row ? row.name : ""
    }

    // Colour for a given state string, used by both the header status dot and
    // each row dot. Only `connected` is ever green — everything else must read
    // as "not fully protected": auth/paused/connecting share the amber
    // connecting hue, error takes the theme urgent colour, and anything else is
    // the muted off colour.
    function colorForState(state) {
        if (state === "connected") return connectedColor
        if (state === "connecting") return connectingColor
        if (state === "auth") return connectingColor
        if (state === "paused") return connectingColor
        if (state === "error") return urgent
        return offColor
    }

    // The status subtitle: the state label, plus the active config when up.
    // When connected, append the active profile's readable NAME (re-derived
    // from the row, never the raw object path) — but only when we have one:
    // if activeName is empty (ambiguous duplicate names), fall back to the
    // bare "Connected" label rather than a dangling separator.
    readonly property string statusLabel: {
        if (!available) return "openvpn3 not available"
        if (overallState === "connected")
            return activeName === ""
                ? "Connected"
                : "Connected · " + Model.clipName(activeName)
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
        // Keep the freshly-selected card inside the scroll viewport. The
        // Flickable no-ops when everything already fits (contentHeight <=
        // height), so short lists never scroll.
        scrollArea.ensureVisible(cardRepeater.itemAt(cursorIndex))
    }

    function activateCursor() {
        if (configs.length === 0) return
        clampCursor()
        root.toggleRow(String(configs[cursorIndex].configPath))
    }

    // Toggle a profile addressed by its unique config object path, never its
    // display name — two profiles sharing a name stay individually targetable.
    function toggleRow(configPath) {
        if (!service) return
        var row = Model.rowByPath(configs, configPath)
        if (!row) return
        // A pending row needs no guard: Service's disconnectConfig already
        // no-ops while an action is in flight, and startInTerminal resolves a
        // fresh argv each call.
        var current = service.displayState(configPath)
        if (current === "connected" || current === "connecting")
            service.disconnectConfig(configPath)
        else
            startInTerminal(configPath)
    }

    // Start a session in a floating terminal instead of a headless Process.
    // session-start may prompt for credentials on stdin (user-locked / 2FA /
    // static-challenge profiles); a headless Process has no stdin to offer and
    // would loop forever on the prompt while leaving a stuck backend. The host
    // shell's launcher runs the command in a real terminal where the user can
    // answer. Service.startArgv does the path validation and refuses an
    // unknown/empty path (returning []); we only run a validated argv.
    function startInTerminal(configPath) {
        if (!service) return
        var argv = service.startArgv(configPath)
        if (argv.length === 0) return
        // Rebuild the command as a single quoted string for the launcher. Each
        // argv element is shell-quoted independently so a validated D-Bus path
        // can never break out of its token.
        var cmd = ""
        for (var i = 0; i < argv.length; i++)
            cmd += (i > 0 ? " " : "") + Util.shellQuote(argv[i])
        var launcher = "omarchy-launch-floating-terminal-with-presentation"
        if (bar && typeof bar.run === "function")
            bar.run(launcher + " " + Util.shellQuote(cmd))
        else
            Quickshell.execDetached([launcher, cmd])
        root.close()
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
        contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

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
                else if (t === "d" || t === "D") root.service.disconnectActive()
            }

            // A long profile list must scroll: nothing on the
            // BorderSurface → contentHolder → PanelKeyCatcher chain clips, so
            // without this the cards below the card-height cap would paint
            // outside the popup and then off-screen, unreachable. Mirrors the
            // Docker plugin's scroll pattern.
            Flickable {
                id: scrollArea
                anchors.fill: parent
                contentWidth: width
                contentHeight: column.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                // Below the cap the whole list fits, so we must NOT capture
                // gestures — otherwise a click meant for a toggle would be
                // eaten by the Flickable. Only interactive once it overflows.
                interactive: contentHeight > height

                // Scroll the given item's card fully into view. No-op while
                // everything fits. Same exact maths as the Docker plugin.
                function ensureVisible(item) {
                    if (!item || contentHeight <= height) return
                    var top = item.mapToItem(column, 0, 0).y
                    var margin = Style.spacing.lg
                    if (top - margin < contentY) contentY = Math.max(0, top - margin)
                    else if (top + item.height + margin > contentY + height)
                        contentY = Math.min(contentHeight - height, top + item.height + margin - height)
                }

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id: column
                    // The KeyboardPanel card already insets its content by
                    // `padding` on every side (see contentHolder in
                    // KeyboardPanel.qml), and the Flickable fills that padded
                    // area — so no anchors.margins here (that stacked a second
                    // inset). Inside a Flickable a ColumnLayout's anchors would
                    // bind to the contentItem and not pin the width, so set the
                    // width explicitly to the viewport and let implicitHeight
                    // be the sole driver of contentHeight (no binding loop:
                    // width never depends on height). ColumnLayout is kept over
                    // a plain Column so the existing Layout.* children need no
                    // rewrite.
                    width: scrollArea.width
                    spacing: Style.spacing.panelGap

                    // ---- 1. Header: plugin icon + title ------------------------

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.controlGap

                        Item {
                            // Match the title's cap height so the mark reads as
                            // its sibling rather than a shrunken afterthought. The
                            // SVG is square, so the slot is square at display size.
                            implicitWidth: Style.font.display
                            implicitHeight: Style.font.display

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
                            font.pixelSize: Style.font.title
                            elide: Text.ElideRight
                        }
                    }

                    // ---- 2. Status subtitle: state dot + label -----------------

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Style.spacing.xxs
                        spacing: Style.spacing.md

                        Rectangle {
                            implicitWidth: Style.spacing.lg
                            implicitHeight: Style.spacing.lg
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
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                        }
                    }

                    // ---- 3. Separator rule -------------------------------------

                    PanelSeparator {
                        Layout.fillWidth: true
                        Layout.topMargin: Style.spacing.xxs
                        Layout.bottomMargin: Style.spacing.xxs
                        foreground: root.foreground
                    }

                    // ---- 4. Available profiles ---------------------------------

                    Text {
                        Layout.fillWidth: true
                        visible: root.configs.length === 0 && root.available
                        text: "No configs — import one with:\nopenvpn3 config-import --config <file>.ovpn"
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        id: cardRepeater
                        model: root.configs

                        // Each profile is a framed card so rows read as discrete
                        // units; the framed card highlights under the keyboard
                        // cursor.
                        Rectangle {
                            id: card
                            required property var modelData
                            required property int index

                            readonly property string rowState: root.service
                                ? root.service.displayState(modelData.configPath)
                                : "disconnected"
                            readonly property bool underCursor:
                                root.cursorActive && root.cursorIndex === index

                            Layout.fillWidth: true
                            // topMargin + bottomMargin below are both Style.spacing.md,
                            // so the frame must add md*2 (=12) to fit the row without
                            // compressing it — not xl (=10), which left it 2px short.
                            implicitHeight: cardRow.implicitHeight + Style.spacing.md * 2
                            radius: Style.cornerRadius
                            color: underCursor ? root.cardCursorColor : root.cardColor
                            border.width: 1
                            border.color: underCursor ? root.ruleColor : "transparent"

                            RowLayout {
                                id: cardRow
                                anchors.fill: parent
                                anchors.leftMargin: Style.spacing.rowPaddingX
                                anchors.rightMargin: Style.spacing.rowPaddingX
                                anchors.topMargin: Style.spacing.md
                                anchors.bottomMargin: Style.spacing.md
                                spacing: Style.spacing.controlGap

                                Rectangle {
                                    implicitWidth: Style.spacing.lg
                                    implicitHeight: Style.spacing.lg
                                    radius: width / 2
                                    color: root.colorForState(card.rowState)
                                    border.width: 1
                                    border.color: Qt.rgba(0, 0, 0, 0.25)
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.spacing.xxs

                                    Text {
                                        Layout.fillWidth: true
                                        text: Model.clipName(card.modelData.name)
                                        textFormat: Text.PlainText
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: true
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
                                        font.pixelSize: Style.font.caption
                                        elide: Text.ElideRight
                                    }
                                }

                                ToggleSwitch {
                                    checked: card.rowState === "connected" || card.rowState === "connecting"
                                    busy: root.service ? root.service.isPending(card.modelData.configPath) : false
                                    hasCursor: card.underCursor
                                    foreground: root.foreground
                                    onToggled: root.toggleRow(String(card.modelData.configPath))
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
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
