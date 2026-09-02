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
// Two write commands are dispatched by the toggle. They act on the exact,
// validated D-Bus object path of the profile/session (never an ambiguous
// name), so two profiles that share a display name can never be confused:
//   openvpn3 session-start  --config-path <config object path>
//   openvpn3 session-manage --session-path <session object path> --disconnect
//
// Security posture (the CLI is a subprocess whose output is untrusted):
//   - The openvpn3 binary is resolved to a trusted absolute path once, never
//     looked up through the inherited PATH at call time.
//   - Every invocation is wrapped so it runs under a hard time limit via GNU
//     `timeout`, which times out the command and its children as one process
//     group, so a hung tunnel process (and its children) is killed together
//     instead of lingering.
//   - Stored command output is truncated before it is retained, and every
//     external string is clipped/sanitized by Model before it reaches the UI.
Item {
    id: root

    property var settings: ({})
    property bool available: true
    property var configs: []           // [{ name, configPath, sessionPath, state }]
    property string activeName: ""
    property string lastError: ""
    property bool refreshing: false

    // Optimistic target state so a flipped switch reacts instantly instead of
    // waiting for the next poll. Empty name means "just follow reality".
    property string pendingName: ""
    property string pendingAction: ""  // "connect" | "disconnect"

    readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)
    readonly property bool busy: actionProcess.running

    // ---- Trusted executable ------------------------------------------------

    // The openvpn3 binary is pinned to a trusted absolute path rather than
    // resolved through the inherited PATH, which an attacker could prepend to
    // shadow the real client with a hostile binary. The first existing path in
    // this allowlist wins; the list is fixed at build time, not user-supplied.
    readonly property var openvpn3Candidates: [
        "/usr/bin/openvpn3",
        "/usr/local/bin/openvpn3",
        "/bin/openvpn3",
        "/sbin/openvpn3",
        "/usr/sbin/openvpn3"
    ]
    property string openvpn3Path: ""

    // Hard wall-clock ceilings (seconds) enforced by `timeout` around each
    // call, matching the QML watchdogs but killing the whole process group.
    readonly property int readTimeoutSec: 12
    readonly property int actionTimeoutSec: 40

    // Cap on how much command output we retain, mirroring Model's own ceiling.
    readonly property int maxStoredChars: 262144

    // Builds an argv that runs the trusted binary under a hard timeout. GNU
    // `timeout` (invoked without --foreground) places the command in its own
    // background process group and, on expiry, signals that whole group — so a
    // hung openvpn3 and any children it spawned are killed together, not just
    // the launcher. TERM first, then KILL two seconds later if it ignores TERM.
    // When the path is not yet resolved the caller must not run the process.
    function wrap(timeoutSec, args) {
        var argv = ["/usr/bin/timeout", "--kill-after=2", "--signal=TERM",
                    String(timeoutSec), root.openvpn3Path]
        for (var i = 0; i < args.length; i++) argv.push(args[i])
        return argv
    }

    // Derived overall state for the bar icon.
    readonly property string state: {
        if (!available) return "error"
        if (pendingName !== "")
            return pendingAction === "connect" ? "connecting" : "disconnected"
        if (activeName === "") return "disconnected"
        var row = Model.rowByName(configs, activeName)
        return row ? row.state : "connected"
    }

    // Raw command output buffers (already truncated on assignment).
    property string _configsOutput: ""
    property string _sessionsOutput: ""
    property string _actionOutput: ""

    // Latch set when a read watchdog fires, so a late onExited cannot resurrect
    // the aborted read chain or apply stale output.
    property bool _readAborted: false

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

    // Truncates retained output so a runaway process cannot bloat memory.
    function boundStored(text) {
        var s = String(text || "")
        return s.length > maxStoredChars ? s.slice(0, maxStoredChars) : s
    }

    // ---- Executable resolution --------------------------------------------

    Component.onCompleted: resolveExecutable()

    // Probes the candidate list with `test -x` and pins the first hit. Until a
    // path is pinned the service reports unavailable and dispatches nothing.
    function resolveExecutable() {
        probeProcess.tryIndex = 0
        probeNext()
    }

    function probeNext() {
        if (probeProcess.tryIndex >= openvpn3Candidates.length) {
            root.openvpn3Path = ""
            root.available = false
            root.lastError = "openvpn3 executable not found"
            return
        }
        probeProcess.candidate = openvpn3Candidates[probeProcess.tryIndex]
        probeProcess.command = ["/usr/bin/test", "-x", probeProcess.candidate]
        probeProcess.running = true
    }

    Process {
        id: probeProcess
        property int tryIndex: 0
        property string candidate: ""
        running: false
        command: []
        onExited: function (exitCode) {
            if (exitCode === 0) {
                root.openvpn3Path = probeProcess.candidate
                root.available = true
                root.refresh()
                return
            }
            probeProcess.tryIndex += 1
            root.probeNext()
        }
    }

    // ---- Reads -------------------------------------------------------------

    // A refresh reads configs first; its onExited chains into the sessions
    // read, and the sessions read merges both into `configs` rows.
    function refresh() {
        if (openvpn3Path === "") return
        if (configsProcess.running || sessionsProcess.running) return
        _configsOutput = ""
        _readAborted = false
        refreshing = true
        configsProcess.command = wrap(readTimeoutSec, ["configs-list"])
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
    //
    // Writes resolve the row's exact validated object path and act on that.
    // If the path did not validate we refuse the action rather than fall back
    // to an ambiguous name.

    function connectConfig(name) {
        if (openvpn3Path === "" || actionProcess.running || name === "") return
        var configPath = Model.configPathForName(configs, name)
        if (configPath === "") {
            root.lastError = "Cannot start: unknown configuration path"
            errorHold.restart()
            return
        }
        pendingName = name
        pendingAction = "connect"
        lastError = ""
        _actionOutput = ""
        actionProcess.command = wrap(actionTimeoutSec,
            ["session-start", "--config-path", configPath])
        actionProcess.running = true
        ramp.restart()
        if (!actionWatchdog.running) actionWatchdog.restart()
    }

    function disconnectConfig(name) {
        if (openvpn3Path === "" || actionProcess.running || name === "") return
        var sessionPath = Model.sessionPathForName(configs, name)
        if (sessionPath === "") {
            // No running session to act on; refresh reality instead of guessing.
            root.refresh()
            return
        }
        pendingName = name
        pendingAction = "disconnect"
        lastError = ""
        _actionOutput = ""
        actionProcess.command = wrap(actionTimeoutSec,
            ["session-manage", "--session-path", sessionPath, "--disconnect"])
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
    // forever, because every later poll is skipped while one is running. On
    // fire we latch _readAborted and kill both read processes as a group.
    Timer {
        id: watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            root._readAborted = true
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
    // leave busy/pendingName stuck until the next successful poll. Killing the
    // process ends the whole session group thanks to the setsid+timeout wrap.
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
            // If the watchdog already aborted this read, do not chain the
            // sessions process or touch state — the cycle is over.
            if (root._readAborted) return

            root._configsOutput = root.boundStored(configsOut.text)
            var succeeded = exitCode === 0

            // Only advance the chain on a clean read. A failed configs read
            // must not feed parsing or trigger the sessions read; report it
            // and stop the cycle so stale/garbage output is never applied.
            if (!succeeded && root._configsOutput === "") {
                watchdog.stop()
                root.refreshing = false
                root.available = false
                root.lastError = "openvpn3 configs-list failed"
                return
            }

            root.available = true
            // Chain into the sessions read.
            root._sessionsOutput = ""
            sessionsProcess.command = root.wrap(root.readTimeoutSec, ["sessions-list"])
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
            if (root._readAborted) return

            watchdog.stop()
            root.refreshing = false
            root._sessionsOutput = root.boundStored(sessionsOut.text)

            // Apply the merged reads only on a successful sessions read. On
            // failure keep the last good view rather than wiping rows with a
            // partial/garbage listing.
            if (exitCode !== 0 && root._sessionsOutput === "") {
                root.lastError = "openvpn3 sessions-list failed"
                return
            }
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
            root._actionOutput = root.boundStored(
                String(actionOut.text || "") + "\n" + String(actionErr.text || ""))
            if (exitCode !== 0) {
                root.lastError = Model.clipError(
                    firstLine(root._actionOutput)) || "openvpn3 command failed"
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
