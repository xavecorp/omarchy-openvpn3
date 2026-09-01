import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless owner of every openvpn3 CLI invocation. It holds no visuals so the
// panel can change shape without touching any of this.
//
// Two read commands feed the UI on a poll:
//   openvpn3 configs-list   -> installed configuration profiles
//   openvpn3 sessions-list  -> running sessions
// Two write commands are dispatched by the toggle:
//   openvpn3 session-start  --config <name>
//   openvpn3 session-manage --config <name> --disconnect
Item {
    id: root

    property var settings: ({})
    property bool available: true
    property var configs: []           // [{ name, path, state }]
    property string activeName: ""
    property string lastError: ""
    property bool refreshing: false

    // Optimistic target state so a flipped switch reacts instantly instead of
    // waiting for the next poll. Empty name means "just follow reality".
    property string pendingName: ""
    property string pendingAction: ""  // "connect" | "disconnect"

    readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)
    readonly property bool busy: actionProcess.running

    // Derived overall state for the bar icon.
    readonly property string state: {
        if (!available) return "error"
        if (pendingName !== "")
            return pendingAction === "connect" ? "connecting" : "disconnected"
        if (activeName === "") return "disconnected"
        var row = Model.rowByName(configs, activeName)
        return row ? row.state : "connected"
    }

    // Raw command output buffers.
    property string _configsOutput: ""
    property string _sessionsOutput: ""
    property string _actionOutput: ""

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    function intSetting(name, fallback, min, max) {
        var n = parseInt(String(setting(name, fallback)), 10)
        if (!isFinite(n)) n = fallback
        if (n < min) n = min
        if (n > max) n = max
        return n
    }

    // ---- Reads -------------------------------------------------------------

    // A refresh reads configs first; its onExited chains into the sessions
    // read, and the sessions read merges both into `configs` rows.
    function refresh() {
        if (configsProcess.running || sessionsProcess.running) return
        _configsOutput = ""
        refreshing = true
        configsProcess.command = ["openvpn3", "configs-list"]
        configsProcess.running = true
        if (!watchdog.running) watchdog.restart()
    }

    function applyReads() {
        var configsResult = Model.parseConfigsList(_configsOutput)
        var sessionsResult = Model.parseSessionsList(_sessionsOutput)
        configs = Model.buildRows(configsResult, sessionsResult)
        activeName = Model.activeSessionName(sessionsResult)

        // Reality caught up with the optimistic state — stop overriding it.
        if (pendingName !== "" && !actionProcess.running) clearPending()
    }

    // ---- Writes (toggle) ---------------------------------------------------

    function connectConfig(name) {
        if (actionProcess.running || name === "") return
        pendingName = name
        pendingAction = "connect"
        lastError = ""
        _actionOutput = ""
        actionProcess.command = ["openvpn3", "session-start", "--config", name]
        actionProcess.running = true
        ramp.restart()
        if (!actionWatchdog.running) actionWatchdog.restart()
    }

    function disconnectConfig(name) {
        if (actionProcess.running || name === "") return
        pendingName = name
        pendingAction = "disconnect"
        lastError = ""
        _actionOutput = ""
        actionProcess.command = ["openvpn3", "session-manage", "--config", name, "--disconnect"]
        actionProcess.running = true
        ramp.restart()
        if (!actionWatchdog.running) actionWatchdog.restart()
    }

    // The single toggle entry point: connect a disconnected profile, or
    // disconnect a connected/connecting one.
    function toggleConfig(name) {
        var current = displayState(name)
        if (current === "connected" || current === "connecting")
            disconnectConfig(name)
        else
            connectConfig(name)
    }

    // What the UI should draw for one profile, optimism included.
    function displayState(name) {
        if (pendingName === name)
            return pendingAction === "connect" ? "connecting" : "disconnected"
        var row = Model.rowByName(configs, name)
        return row ? row.state : "disconnected"
    }

    function isPending(name) {
        return pendingName === name
    }

    function clearPending() {
        pendingName = ""
        pendingAction = ""
    }

    // ---- Timers ------------------------------------------------------------

    Timer {
        id: refreshTimer
        interval: root.refreshIntervalSec * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Fast poll for a few seconds after an action so a connect looks live
    // without polling at 1s forever.
    Timer {
        id: ramp
        property int ticks: 0
        interval: 1000
        repeat: true
        onTriggered: {
            ticks += 1
            root.refresh()
            if (ticks >= 12) { ramp.running = false; ticks = 0 }
        }
        onRunningChanged: if (running) ticks = 0
    }

    // A read that never returns would otherwise freeze the widget on old data
    // forever, because every later poll is skipped while one is running.
    Timer {
        id: watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            if (configsProcess.running) configsProcess.running = false
            if (sessionsProcess.running) sessionsProcess.running = false
            root.refreshing = false
            root.lastError = "openvpn3 stopped responding"
        }
    }

    // Keeps an action error on screen long enough to read, since the status
    // poll that follows lands under a second later and would wipe it out.
    Timer {
        id: errorHold
        interval: 6000
        repeat: false
    }

    // session-start can block on a slow server; without this a hang would
    // leave busy/pendingName stuck until the next successful poll.
    Timer {
        id: actionWatchdog
        interval: 45000
        repeat: false
        onTriggered: {
            if (actionProcess.running) actionProcess.running = false
            root.clearPending()
            root.lastError = "openvpn3 command timed out"
            errorHold.restart()
        }
    }

    // ---- Processes ---------------------------------------------------------

    Process {
        id: configsProcess
        running: false
        command: []
        stdout: StdioCollector { id: configsOut; waitForEnd: true }
        stderr: StdioCollector { id: configsErr; waitForEnd: true }
        onExited: function (exitCode) {
            root._configsOutput = String(configsOut.text || "")
            root.available = exitCode === 0 || root._configsOutput !== ""
            // Chain into the sessions read.
            root._sessionsOutput = ""
            sessionsProcess.command = ["openvpn3", "sessions-list"]
            sessionsProcess.running = true
        }
    }

    Process {
        id: sessionsProcess
        running: false
        command: []
        stdout: StdioCollector { id: sessionsOut; waitForEnd: true }
        stderr: StdioCollector { id: sessionsErr; waitForEnd: true }
        onExited: function (exitCode) {
            watchdog.stop()
            root.refreshing = false
            root._sessionsOutput = String(sessionsOut.text || "")
            root.applyReads()
        }
    }

    Process {
        id: actionProcess
        running: false
        command: []
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        stderr: StdioCollector { id: actionErr; waitForEnd: true }
        onExited: function (exitCode) {
            actionWatchdog.stop()
            root._actionOutput = String(actionOut.text || "") + String(actionErr.text || "")
            if (exitCode !== 0) {
                root.lastError = firstLine(root._actionOutput) || "openvpn3 command failed"
                errorHold.restart()
                root.clearPending()
            }
            // Poll immediately, then let the ramp confirm the new state and
            // clear the optimistic pending flag once reality agrees.
            root.refresh()
        }
    }

    // First non-empty line of a command's output, for compact error display.
    function firstLine(text) {
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var trimmed = lines[i].trim()
            if (trimmed !== "") return trimmed
        }
        return ""
    }
}
