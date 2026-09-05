import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry point: an icon that answers "am I connected?", and the host for
// the panel that answers "which profile?".
BarWidget {
    id: root
    moduleName: "xavecorp.openvpn3"

    readonly property string vpnState: service.state
    // Bar chrome must paint with `barForeground`, not `foreground`. On a
    // transparent bar over a light wallpaper the shell flips barForeground to a
    // contrast-appropriate colour, while `foreground` stays the theme/popup
    // text colour — using the latter is what made the icon render light on a
    // dark bar. Every stock bar widget (WidgetButton, tailscale, dropbox)
    // sources its icon from barForeground for exactly this reason.
    readonly property color activeColor: bar ? bar.barForeground : Color.foreground
    readonly property color idleColor: Qt.darker(activeColor, 1.55)
    readonly property color urgentColor: bar ? bar.urgent : Color.urgent

    readonly property string labelText: vpnState === "connected"
        ? "OpenVPN3: " + Model.clipName(service.activeName)
        : "OpenVPN3"

    readonly property color iconColor: {
        if (vpnState === "error") return urgentColor
        return vpnState === "connected" ? activeColor : idleColor
    }

    Service {
        id: service
        settings: root.settings
    }

    // Right click acts on the obvious target without opening the panel:
    // what is up, else what was up last, else the only profile there is.
    // Tracked by config object path so a duplicate display name can never
    // resolve the quick-toggle to the wrong profile.
    property string lastConnected: ""

    function configPathExists(configPath) {
        return Model.rowByPath(service.configs, configPath) !== null
    }

    // The config object path of whatever session is currently active, resolved
    // from the active session name through its row. "" when nothing is up.
    function activeConfigPath() {
        if (service.activeName === "") return ""
        var row = Model.rowByName(service.configs, service.activeName)
        return row ? String(row.configPath) : ""
    }

    function quickTarget() {
        var active = activeConfigPath()
        if (active !== "") return active
        if (lastConnected !== "" && configPathExists(lastConnected)) return lastConnected
        if (service.configs.length === 1) return String(service.configs[0].configPath)
        return ""
    }

    function quickToggle() {
        var target = quickTarget()
        if (target === "") root.togglePanel()
        else service.toggleConfig(target)
    }

    Connections {
        target: service
        function onActiveNameChanged() {
            var active = root.activeConfigPath()
            if (active !== "") root.lastConnected = active
        }
    }

    // ---- Panel hosting. Shape contract for shell summon/hide/toggle routing:
    // Bar.findPanelWidget requires open/close/opened on the bar-widget root.
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item
        ? panelLoader.item.popoutSwitchClosing === true
        : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
        if ("service" in target) target.service = service
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    IpcHandler {
        target: "xavecorp.openvpn3"
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.togglePanel() }
        function refresh(): void { service.refresh() }
    }

    // An SVG rather than a font glyph: the bar font is "monospace" and carries
    // no Nerd Font glyphs on a stock install, so a glyph would paint a
    // missing-glyph box. An SVG brings its own artwork.
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        iconComponent: iconArt
        tooltipText: root.labelText

        // Pulse while connecting by toggling `dimmed`, which WidgetButton owns,
        // rather than animating opacity (which carries its own binding).
        dimmed: root.vpnState === "connecting" && root.pulseOff

        onPressed: function (b) {
            if (b === Qt.RightButton) root.quickToggle()
            else root.togglePanel()
        }
    }

    Component {
        id: iconArt
        Item {
            Image {
                id: iconImage
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                source: Qt.resolvedUrl("icon.svg")
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                visible: false
                layer.enabled: true
            }

            // Paints the icon in the bar's colour for the current state. The
            // source artwork is white so colorization can swap the hue while
            // keeping the luminance.
            MultiEffect {
                anchors.fill: iconImage
                source: iconImage
                colorization: 1.0
                colorizationColor: root.iconColor
            }
        }
    }

    property bool pulseOff: false
    Timer {
        interval: 600
        repeat: true
        running: root.vpnState === "connecting"
        onTriggered: root.pulseOff = !root.pulseOff
        onRunningChanged: if (!running) root.pulseOff = false
    }
}
