import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless owner of every openvpn3 CLI invocation. It holds no visuals so the
// panel can change shape without touching any of this.
//
// Two read commands feed the UI on a poll:
//   openvpn3 configs-list --json  -> installed profiles, keyed by object path
//   openvpn3 sessions-list        -> running sessions
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
    // waiting for the next poll. Keyed by the profile's unique config object
    // path — never its display name — so the optimistic highlight and the
    // in-flight action land on the exact row the user acted on, even when two
    // profiles share a name. Empty path means "just follow reality".
    property string pendingPath: ""
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

    // Builds an argv that runs the trusted binary under a hard timeout with its
    // output hard-capped at the OS level. Two nested layers, each load-bearing:
    //
    //   1. GNU `timeout` is the DIRECT child of Quickshell. Invoked without
    //      --foreground it runs its command in a fresh process group and, both
    //      on expiry and on any signal it receives, signals that whole group —
    //      so when the watchdog/onDestruction flips `running` to false (SIGTERM
    //      to timeout) the entire tunnel process tree is reaped together, not
    //      just the launcher. TERM first, then KILL two seconds later.
    //
    //   2. Inside, bash runs `<binary> <args> | head -c maxStoredChars`. The
    //      cap is enforced by the kernel pipe + `head`: at most maxStoredChars
    //      bytes ever leave the child, so StdioCollector can never buffer an
    //      unbounded (or hostile, memory-exhausting) stream — the ceiling bites
    //      *before* collection, not after. `set -o pipefail` makes the exit
    //      status reflect the openvpn3 command, never head's, so a failing
    //      command is still detected (and a runaway that trips head's early
    //      exit surfaces as a non-zero SIGPIPE, i.e. also a failure).
    //
    // This is injection-safe by construction: the bash script is a fixed
    // constant, and every dynamic value (binary path, args) is passed as a
    // separate positional parameter referenced only through the quoted "$@",
    // which the shell never re-parses for metacharacters. The args are anyway
    // pre-validated D-Bus object paths (Model.validatePath) with no shell
    // metacharacters. When the path is not yet resolved the caller must not run.
    readonly property string capScript:
        "set -o pipefail; \"$@\" | /usr/bin/head -c " + maxStoredChars
    function wrap(timeoutSec, args) {
        var argv = ["/usr/bin/timeout", "--kill-after=2", "--signal=TERM",
                    String(timeoutSec), "/usr/bin/bash", "-c", capScript,
                    "openvpn3-wrap", root.openvpn3Path]
        for (var i = 0; i < args.length; i++) argv.push(args[i])
        return argv
    }

    // Derived overall state for the bar icon.
    readonly property string state: {
        if (!available) return "error"
        if (pendingPath !== "")
            return pendingAction === "connect" ? "connecting" : "disconnected"
        // A corrupted configs read left us on a stale view; it cannot prove the
        // tunnel is still up, so never surface "connected" from it. Report
        // "error" (urgent color; lastError/tooltip explains). Placed after the
        // pendingPath block so an in-flight optimistic action still wins.
        if (_configsStale) return "error"
        if (activeName === "") return "disconnected"
        var row = Model.rowByName(configs, activeName)
        // If the active session name is not yet reflected in a row, never claim
        // "connected" — the tunnel state is unproven. Fall back to "connecting".
        return row ? row.state : "connecting"
    }

    // Raw command output buffers (already truncated on assignment).
    property string _configsOutput: ""
    property string _sessionsOutput: ""
    property string _actionOutput: ""

    // Latch set when a read watchdog fires, so a late onExited cannot resurrect
    // the aborted read chain or apply stale output.
    property bool _readAborted: false

    // Latch set when a configs read returns invalid data. We deliberately keep
    // the last good view on screen (so profiles do not vanish), but that view
    // may describe a tunnel that has since dropped. While stale we must never
    // report "connected" from it: the Lot 1 rule is to never claim protection
    // without proof, and a corrupted read is not proof. Cleared on any clean
    // configs read.
    property bool _configsStale: false

    // Latch set the moment the component starts tearing down. Every onExited
    // handler bails on it so a process reaped during destruction can never
    // touch (already half-gone) state, and no timer can re-arm a dead service.
    property bool _destroyed: false

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

    // Teardown: when the shell reloads or the widget is removed the component
    // is destroyed, but any openvpn3 invocation it launched would otherwise
    // outlive it. Invalidate all state first (so no late onExited or timer can
    // touch a half-gone object), stop every timer, then reap every active
    // process group. Flipping `running` to false sends SIGTERM to the DIRECT
    // child — GNU `timeout` — which relays it to the whole process group it
    // created (bash + openvpn3 + head), so the entire tree dies together.
    Component.onDestruction: {
        _destroyed = true
        _readAborted = true
        refreshing = false
        clearPending()

        refreshTimer.stop()
        ramp.stop()
        watchdog.stop()
        errorHold.stop()
        actionWatchdog.stop()

        if (probeProcess.running) probeProcess.running = false
        if (configsProcess.running) configsProcess.running = false
        if (sessionsProcess.running) sessionsProcess.running = false
        if (actionProcess.running) actionProcess.running = false
    }

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
        if (_destroyed) return
        if (openvpn3Path === "") return
        if (configsProcess.running || sessionsProcess.running) return
        _configsOutput = ""
        _readAborted = false
        refreshing = true
        configsProcess.command = wrap(readTimeoutSec, ["configs-list", "--json"])
        configsProcess.running = true
        if (!watchdog.running) watchdog.restart()
    }

    function applyReads() {
        var configsResult = Model.parseConfigsListJson(_configsOutput)
        var sessionsResult = Model.parseSessionsList(_sessionsOutput)

        // If the configs read produced invalid data (e.g. malformed JSON from a
        // stderr warning bleeding into the stream), do NOT wipe the view: an
        // empty list would make every profile silently vanish behind a bland
        // "No configs" message. Surface the failure and keep the last good view.
        if (configsResult.ok === false) {
            root.lastError = "openvpn3 configs-list returned invalid data"
            _configsStale = true
            return
        }
        _configsStale = false

        configs = Model.buildRows(configsResult, sessionsResult)
        activeName = Model.activeSessionName(sessionsResult)

        // Reality caught up with the optimistic state — stop overriding it.
        if (pendingPath !== "" && !actionProcess.running) clearPending()
    }

    // ---- Writes (toggle) ---------------------------------------------------
    //
    // Every write is addressed by the profile's unique config object path, not
    // its display name. The path selects the exact row, and the row carries the
    // exact validated D-Bus object paths the CLI acts on. If a required path did
    // not validate we refuse the action rather than fall back to an ambiguous
    // name — two profiles sharing a name can never be confused.

    function connectConfig(configPath) {
        if (openvpn3Path === "" || actionProcess.running || configPath === "")
            return
        var row = Model.rowByPath(configs, configPath)
        if (!row || row.configPath === "") {
            root.lastError = "Cannot start: unknown configuration path"
            errorHold.restart()
            return
        }
        pendingPath = row.configPath
        pendingAction = "connect"
        lastError = ""
        _actionOutput = ""
        actionProcess.command = wrap(actionTimeoutSec,
            ["session-start", "--config-path", row.configPath])
        actionProcess.running = true
        ramp.restart()
        if (!actionWatchdog.running) actionWatchdog.restart()
    }

    function disconnectConfig(configPath) {
        if (openvpn3Path === "" || actionProcess.running || configPath === "")
            return
        var row = Model.rowByPath(configs, configPath)
        var sessionPath = row ? row.sessionPath : ""
        if (sessionPath === "") {
            // No running session to act on; refresh reality instead of guessing.
            root.refresh()
            return
        }
        pendingPath = configPath
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
    // disconnect a connected/connecting one. Addressed by config object path.
    function toggleConfig(configPath) {
        var current = displayState(configPath)
        if (current === "connected" || current === "connecting")
            disconnectConfig(configPath)
        else
            connectConfig(configPath)
    }

    // Disconnects whatever session is currently active (the `d` shortcut and
    // the bar quick-toggle). Resolves the active session's row so it acts on an
    // exact object path rather than the raw name.
    function disconnectActive() {
        if (activeName === "") return
        var row = Model.rowByName(configs, activeName)
        if (row) disconnectConfig(row.configPath)
    }

    // What the UI should draw for one profile, optimism included. Keyed by the
    // profile's config object path.
    function displayState(configPath) {
        if (pendingPath === configPath && configPath !== "")
            return pendingAction === "connect" ? "connecting" : "disconnected"
        var row = Model.rowByPath(configs, configPath)
        return row ? row.state : "disconnected"
    }

    function isPending(configPath) {
        return configPath !== "" && pendingPath === configPath
    }

    function clearPending() {
        pendingPath = ""
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
    // leave busy/pendingPath stuck until the next successful poll. Flipping
    // running to false SIGTERMs `timeout`, which reaps the whole process group
    // (bash + openvpn3 + head), ending the stuck session attempt cleanly.
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
            // The component is tearing down: the process was reaped by
            // onDestruction, not a real read. Touch nothing.
            if (root._destroyed) return
            // If the watchdog already aborted this read, do not chain the
            // sessions process or touch state — the cycle is over.
            if (root._readAborted) return

            root._configsOutput = root.boundStored(configsOut.text)

            // Reject any non-zero exit outright, regardless of what text the
            // command emitted. A failed configs read must never feed parsing or
            // trigger the sessions read: partial, stale or hostile output on a
            // failing command is exactly what we must not apply.
            if (exitCode !== 0) {
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
            if (root._destroyed) return
            if (root._readAborted) return

            watchdog.stop()
            root.refreshing = false
            root._sessionsOutput = root.boundStored(sessionsOut.text)

            // Apply the merged reads only on a clean exit. Any non-zero exit is
            // rejected outright, whatever text was emitted, so a partial or
            // hostile listing never wipes or corrupts the last good view.
            if (exitCode !== 0) {
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
            if (root._destroyed) return
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
