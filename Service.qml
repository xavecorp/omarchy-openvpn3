import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless owner of every openvpn3 CLI invocation. It holds no visuals so the
// panel can change shape without touching any of this. It also has no `bar`
// reference, which is why the one interactive command — session-start, which
// may prompt for credentials on stdin — is NOT run here: it is delegated to a
// real terminal by the panel (which owns `bar`). This service resolves and
// validates the start argv (startArgv) but never launches it.
//
// Two read commands feed the UI on a poll:
//   openvpn3 configs-list --json  -> installed profiles, keyed by object path
//   openvpn3 sessions-list        -> running sessions
// One write command is dispatched here by the toggle. It acts on the exact,
// validated D-Bus object path of the session (never an ambiguous name), so two
// profiles that share a display name can never be confused:
//   openvpn3 session-manage --session-path <session object path> --disconnect
//
// Security posture (the CLI is a subprocess whose output is untrusted):
//   - The openvpn3 binary is resolved to a trusted absolute path once, never
//     looked up through the inherited PATH at call time.
//   - Every invocation runs under a hard time limit via GNU `timeout` with
//     `--signal=KILL`: on expiry the whole process group is KILLed, which a
//     stuck child cannot ignore. (A TERM-based timeout does NOT guarantee this
//     — see the wrap() comment.)
//   - Command output is capped in-band (head -c) with stderr folded in or
//     dropped at the source, so no stream can bloat memory; every external
//     string is also clipped/sanitized by Model before it reaches the UI.
Item {
    id: root

    property var settings: ({})
    property bool available: true
    property var configs: []           // [{ name, configPath, sessionPath, state }]
    // A19: the active identity is a session object PATH, not a display name.
    // sessions-list exposes no config path and no JSON mode (a hard CLI
    // constraint), so the session path is the one unambiguous handle a running
    // session carries. The UI re-derives the readable name from the matching
    // row (Model.rowBySessionPath) — it never renders this raw object path.
    property string activeSessionPath: ""
    property string lastError: ""

    // Optimistic target state so a flipped switch reacts instantly instead of
    // waiting for the next poll. Keyed by the profile's unique config object
    // path — never its display name — so the optimistic highlight and the
    // in-flight action land on the exact row the user acted on, even when two
    // profiles share a name. Empty path means "just follow reality". Only the
    // disconnect action is optimistic here; connect is delegated to a terminal
    // and confirmed by the next poll, so it has no in-service pending state.
    property string pendingPath: ""
    property string pendingAction: ""  // "disconnect" (the only in-service action)

    readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)

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
    // call. Reads chain two commands, each bounded independently. The action is
    // now only session-manage --disconnect (session-start is delegated to a
    // terminal), which is short and non-interactive, so it shares the read
    // ceiling rather than the old 40 s connect budget.
    readonly property int readTimeoutSec: 12
    readonly property int actionTimeoutSec: 12

    // Cap on how much command output we retain, mirroring Model's own ceiling.
    readonly property int maxStoredChars: 262144

    // Builds an argv that runs the trusted binary under a hard timeout with its
    // output hard-capped at the OS level. Three layers, each load-bearing:
    //
    //   1. GNU `timeout` is the DIRECT child of Quickshell. On expiry it signals
    //      the process group it created. It is invoked with `--signal=KILL`, not
    //      TERM: openvpn3 (and a hostile/stuck child) can trap and ignore TERM,
    //      in which case `timeout` reaps its direct child `bash` on TERM and
    //      exits *before* the `--kill-after` grace ever fires, leaving the
    //      grandchild alive and reparented (proven: `trap '' TERM` survives a
    //      TERM-based timeout, dies under KILL). A group KILL cannot be ignored,
    //      so the whole tree dies at the ceiling. (The direct-child SIGTERM sent
    //      by `running = false` / onDestruction still only guarantees the
    //      launcher; it is best-effort for the tree — see onDestruction.)
    //
    //   2. Inside, bash runs `<binary> <args> <redir> | head -c maxStoredChars`.
    //      The cap is enforced by the kernel pipe + `head`, and the redirection
    //      is what makes it bite: `2>/dev/null` (reads) or `2>&1` (action) means
    //      BOTH streams go through — or are dropped before — the cap, so no
    //      unbounded (or hostile, memory-exhausting) stream can reach the
    //      StdioCollector. Without the redirection stderr bypasses `head`
    //      entirely (proven: 5 MB on stderr reached the collector uncapped).
    //      `set -o pipefail` makes the exit status reflect the openvpn3 command,
    //      never head's, so a failing command is still detected.
    //
    // This is injection-safe by construction: each cap script is a fixed
    // constant, and every dynamic value (binary path, args) is passed as a
    // separate positional parameter referenced only through the quoted "$@",
    // which the shell never re-parses for metacharacters. The args are anyway
    // pre-validated D-Bus object paths (Model.validatePath) with no shell
    // metacharacters. When the path is not yet resolved the caller must not run.
    //
    // Two scripts, chosen by use:
    //   - Reads never consume stderr, so it is dropped at the source. This is
    //     mandatory for `configs-list --json`: an openvpn3 warning on stderr
    //     folded into stdout would corrupt the JSON and fail the parse.
    //   - The action (disconnect) needs its error text, so stderr is merged
    //     INTO stdout before the cap.
    readonly property string capScriptRead:
        "set -o pipefail; \"$@\" 2>/dev/null | /usr/bin/head -c " + maxStoredChars
    readonly property string capScriptAction:
        "set -o pipefail; \"$@\" 2>&1 | /usr/bin/head -c " + maxStoredChars
    function wrap(timeoutSec, capScript, args) {
        var argv = ["/usr/bin/timeout", "--kill-after=2", "--signal=KILL",
                    String(timeoutSec), "/usr/bin/bash", "-c", capScript,
                    "openvpn3-wrap", root.openvpn3Path]
        for (var i = 0; i < args.length; i++) argv.push(args[i])
        return argv
    }

    // Derived overall state for the bar icon.
    readonly property string state: {
        if (!available) return "error"
        if (pendingPath !== "")
            return "disconnected"
        // A corrupted configs read left us on a stale view; it cannot prove the
        // tunnel is still up, so never surface "connected" from it. Report
        // "error" (urgent color; lastError/tooltip explains). Placed after the
        // pendingPath block so an in-flight optimistic action still wins.
        if (_configsStale) return "error"
        if (activeSessionPath === "") return "disconnected"
        var row = Model.rowBySessionPath(configs, activeSessionPath)
        // If the active session path is not (yet) reflected in exactly one row
        // — not merged yet, or ambiguous because two profiles share a name —
        // never claim "connected": the tunnel state is unproven. Fall back to
        // "connecting".
        return row ? row.state : "connecting"
    }

    // Raw command output buffers (already truncated on assignment).
    property string _configsOutput: ""
    property string _sessionsOutput: ""

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
    // touch a half-gone object), stop every timer, then stop every active
    // process. Flipping `running` to false sends SIGTERM to the DIRECT child —
    // GNU `timeout` — which relays TERM to its group; this cleanly ends the
    // short read/disconnect commands run here (they do not ignore TERM). Note
    // this is NOT a guaranteed full-tree reap: a child that ignores TERM would
    // survive a TERM relay. The hard guarantee is the per-command `timeout
    // --signal=KILL` ceiling (see wrap()); on teardown we rely on TERM plus
    // that ceiling, and the only long/stubborn command (session-start) is no
    // longer launched here at all.
    Component.onDestruction: {
        _destroyed = true
        _readAborted = true
        clearPending()

        refreshTimer.stop()
        ramp.stop()
        watchdog.stop()
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
        // The component is tearing down; do not launch another probe on a
        // half-gone object (a late probe onExited would otherwise re-enter here).
        if (root._destroyed) return
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
        // A12: run with a scrubbed environment. `bash -c` reads BASH_ENV even
        // when non-interactive, so an inherited BASH_ENV would execute
        // arbitrary code on every poll. Clearing the environment and pinning a
        // minimal PATH removes that vector (defence in depth: whoever can set
        // the variable already runs as this user). Proven under `env -i`:
        // `test -x`, configs-list --json, sessions-list and session-manage all
        // exit 0 / behave identically with an empty environment. Repeated
        // verbatim on each Process rather than hidden in a factory (INV-2).
        clearEnvironment: true
        environment: ({ PATH: "/usr/bin" })
        onExited: function (exitCode) {
            // Reaped by onDestruction, not a real probe result: touch nothing
            // and never re-arm a Process on a component being destroyed.
            if (root._destroyed) return
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
        configsProcess.command = wrap(readTimeoutSec, capScriptRead, ["configs-list", "--json"])
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
        activeSessionPath = Model.activeSessionPath(sessionsResult)

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

    // Resolves the argv that starts a session for a profile, or [] when the
    // profile can't be safely started. This service does NOT run session-start
    // itself: that command can prompt for credentials on stdin (user-locked /
    // 2FA / static-challenge profiles) and, given no stdin, loops forever on
    // the prompt while leaving a stuck backend behind. A headless Process has
    // no stdin to offer, so the start is delegated to a real terminal by the
    // panel (which owns `bar`). Here we only do the validation: resolve the
    // exact row by config object path and refuse an unknown/empty path.
    function startArgv(configPath) {
        if (openvpn3Path === "" || configPath === "")
            return []
        var row = Model.rowByPath(configs, configPath)
        if (!row || row.configPath === "") {
            root.lastError = "Cannot start: unknown configuration path"
            return []
        }
        return [openvpn3Path, "session-start", "--config-path", row.configPath]
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
        // A19: refuse rather than guess. buildRows pairs sessions to configs by
        // name (a CLI constraint — sessions-list has no config path), so when
        // two profiles share a display name they are assigned the SAME
        // sessionPath. Disconnecting one would then tear down the other's
        // tunnel. If more than one row carries this session path the identity
        // is ambiguous, so we refuse (rowBySessionPath returns null) instead of
        // acting on the wrong profile.
        if (Model.rowBySessionPath(configs, sessionPath) === null) {
            root.lastError = "Cannot disconnect: two profiles share this name"
            return
        }
        pendingPath = configPath
        pendingAction = "disconnect"
        lastError = ""
        actionProcess.command = wrap(actionTimeoutSec, capScriptAction,
            ["session-manage", "--session-path", sessionPath, "--disconnect"])
        actionProcess.running = true
        ramp.restart()
        if (!actionWatchdog.running) actionWatchdog.restart()
    }
    // the bar quick-toggle). Resolves the active session's row by its session
    // object path so it acts on an exact object path, never a name. If two
    // profiles share a display name the active session path maps to more than
    // one row (buildRows pairs by name — a CLI constraint); rowBySessionPath
    // then returns null and we refuse rather than disconnect the wrong tunnel.
    function disconnectActive() {
        if (activeSessionPath === "") return
        var row = Model.rowBySessionPath(configs, activeSessionPath)
        if (!row) {
            root.lastError = "Cannot disconnect: two profiles share this name"
            return
        }
        disconnectConfig(row.configPath)
    }

    // What the UI should draw for one profile, optimism included. Keyed by the
    // profile's config object path. The only optimistic action is disconnect,
    // so a pending row reads as "disconnected" until the poll confirms it.
    function displayState(configPath) {
        if (pendingPath === configPath && configPath !== "")
            return "disconnected"
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

    // Fast poll for a few seconds after a disconnect so the row updates live
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

    // Backstop for a read whose onExited never arrives (e.g. a Process that
    // hangs past its own `timeout` ceiling). Re-armed at the START of EACH read
    // (refresh() for configs, configsProcess.onExited for sessions), so it
    // bounds one command at a time — 15 s comfortably exceeds a single read's
    // 12 s `timeout` budget without punishing a slow-but-healthy pair. On fire
    // we latch _readAborted and drop both read processes.
    Timer {
        id: watchdog
        interval: 15000
        repeat: false
        onTriggered: {
            root._readAborted = true
            if (configsProcess.running) configsProcess.running = false
            if (sessionsProcess.running) sessionsProcess.running = false
            root.lastError = "openvpn3 stopped responding"
        }
    }

    // Backstop for the disconnect action (the only command run through
    // actionProcess now that session-start is delegated to a terminal).
    // session-manage --disconnect is short and non-interactive, but if its
    // onExited never arrives this clears pendingPath and reports the timeout.
    // Flipping running to
    // false sends SIGTERM to `timeout`; the command also carries its own
    // `--signal=KILL` ceiling, which is the guaranteed reap of a stuck child.
    Timer {
        id: actionWatchdog
        interval: (root.actionTimeoutSec + 5) * 1000
        repeat: false
        onTriggered: {
            if (actionProcess.running) actionProcess.running = false
            root.clearPending()
            root.lastError = "openvpn3 command timed out"
        }
    }

    // ---- Processes ---------------------------------------------------------

    Process {
        id: configsProcess
        running: false
        command: []
        // A12: scrubbed environment (see probeProcess) — bash -c would
        // otherwise source an inherited BASH_ENV on every poll.
        clearEnvironment: true
        environment: ({ PATH: "/usr/bin" })
        // stderr is dropped in-band by capScriptRead (2>/dev/null); a stderr
        // collector here would only buffer bytes we never read.
        stdout: StdioCollector { id: configsOut; waitForEnd: true }
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
                root.available = false
                root.lastError = "openvpn3 configs-list failed"
                return
            }

            root.available = true
            // Chain into the sessions read. Re-arm the watchdog so the sessions
            // command gets its OWN full budget: the two reads run sequentially,
            // each with its own `timeout` ceiling, so a single 15 s watchdog for
            // the whole chain would falsely kill a slow-but-healthy pair (e.g.
            // 11 s + 5 s) and report "openvpn3 stopped responding". Restarting
            // here (and once in refresh() for the configs read) bounds each read
            // independently instead of the chain as a whole.
            watchdog.restart()
            root._sessionsOutput = ""
            sessionsProcess.command = root.wrap(root.readTimeoutSec, root.capScriptRead, ["sessions-list"])
            sessionsProcess.running = true
        }
    }

    Process {
        id: sessionsProcess
        running: false
        command: []
        // A12: scrubbed environment (see probeProcess).
        clearEnvironment: true
        environment: ({ PATH: "/usr/bin" })
        // stderr dropped in-band by capScriptRead (2>/dev/null); see configsProcess.
        stdout: StdioCollector { id: sessionsOut; waitForEnd: true }
        onExited: function (exitCode) {
            if (root._destroyed) return
            if (root._readAborted) return

            watchdog.stop()
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
        // A12: scrubbed environment (see probeProcess).
        clearEnvironment: true
        environment: ({ PATH: "/usr/bin" })
        // Only session-manage --disconnect runs here now (session-start is
        // delegated to a terminal by the panel). With capScriptAction the
        // command's stderr is folded into stdout, so actionOut carries any
        // error text; no separate stderr collector is needed.
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        onExited: function (exitCode) {
            if (root._destroyed) return
            actionWatchdog.stop()
            if (exitCode !== 0) {
                root.lastError = Model.clipError(
                    firstLine(root.boundStored(actionOut.text))) || "openvpn3 command failed"
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
