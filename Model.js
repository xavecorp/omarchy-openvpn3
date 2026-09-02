// Pure helpers shared by Panel.qml, BarWidget.qml and Service.qml.
// No Qt objects here so this file can be unit-tested with `node --test` as
// well as loaded by the shell.
//
// These parsers read the plain-text output of the openvpn3 CLI:
//   - `openvpn3 configs-list`  -> installed configuration profiles
//   - `openvpn3 sessions-list` -> currently running VPN sessions
// The CLI emits human-oriented tables, so parsing keys off the labelled rows
// and the fixed separator lines rather than fixed column offsets.

var CONFIG_PATH_PREFIX = "/net/openvpn/v3/configuration/";
var SESSION_PATH_PREFIX = "/net/openvpn/v3/sessions/";

// Hard caps. The openvpn3 CLI output is untrusted input from a subprocess: a
// runaway, corrupt, or hostile process must never be able to exhaust memory or
// smuggle rich-text/terminal escapes into the UI. Every external string is
// clipped and every record list is bounded before it reaches the widgets.
var MAX_OUTPUT_CHARS = 262144; // 256 KiB of stdout/stderr is far beyond any real listing.
var MAX_RECORDS = 256;         // No sane machine has hundreds of profiles/sessions.
var MAX_NAME_LEN = 128;        // Profile / session config names.
var MAX_STATUS_LEN = 160;      // Human-readable status line.
var MAX_PATH_LEN = 256;        // D-Bus object paths.
var MAX_ERROR_LEN = 240;       // Error text surfaced to the user.

// The characters allowed inside a validated D-Bus object path segment. The
// openvpn3 paths are ASCII word chars plus separators; anything else is a sign
// the token was not really a path and must be rejected.
var PATH_TAIL = /^[A-Za-z0-9._\/-]+$/;

// Truncates raw command output to a sane ceiling before any parsing runs, so a
// process emitting gigabytes cannot blow up the string ops downstream.
function boundRaw(raw) {
    var text = String(raw || "");
    return text.length > MAX_OUTPUT_CHARS ? text.slice(0, MAX_OUTPUT_CHARS) : text;
}

// Sanitizes and clips an arbitrary external string for safe display. Strips
// control characters (including ANSI escapes and newlines) that could corrupt
// the layout or smuggle markup, collapses inner whitespace, then truncates to
// `max`. This is the single choke point every user-visible external field
// passes through.
function clip(value, max) {
    var limit = typeof max === "number" && max > 0 ? max : MAX_NAME_LEN;
    var text = String(value === undefined || value === null ? "" : value)
        // eslint-disable-next-line no-control-regex
        .replace(/[\u0000-\u001F\u007F-\u009F]/g, " ")
        .replace(/\s+/g, " ")
        .trim();
    return text.length > limit ? text.slice(0, limit) : text;
}

// Validates a candidate D-Bus object path against an expected prefix. Returns
// the clipped path only when it starts with the prefix and its tail is a plain
// path token; otherwise "". Writes must never act on a path that failed this.
function validatePath(candidate, prefix) {
    var text = clip(candidate, MAX_PATH_LEN);
    if (text.indexOf(prefix) !== 0) return "";
    var tail = text.slice(prefix.length);
    if (tail === "" || !PATH_TAIL.test(tail)) return "";
    return text;
}

// Splits raw command output into trimmed, non-empty lines, bounded by the
// output ceiling and the record cap so a huge listing cannot grow unbounded.
function toLines(raw) {
    var lines = boundRaw(raw)
        .split("\n")
        .map(function (line) { return line.replace(/\s+$/, ""); });
    // Even after the byte ceiling, cap the line count: pathological output made
    // of millions of one-char lines would otherwise slip past MAX_OUTPUT_CHARS
    // only loosely. Keep generous headroom over MAX_RECORDS for header rows.
    var lineCeiling = MAX_RECORDS * 16;
    return lines.length > lineCeiling ? lines.slice(0, lineCeiling) : lines;
}

// A separator row is the dashed rule the CLI prints between records.
function isSeparator(line) {
    var trimmed = String(line || "").trim();
    return trimmed.length > 0 && /^-+$/.test(trimmed);
}

// Parses `openvpn3 configs-list`.
//
// Each profile is a record introduced by its D-Bus config path line, followed
// by a timestamp/usage row and then a "<name>   <owner>" row. The record ends
// at the next path line or separator. The profile name is the first token of
// the last data row of the record, because the timestamp row starts with a
// weekday token while the name row does not.
//
// Two layouts exist across openvpn3 versions:
//
//   Compact table (current):
//     Configuration Name                       Last used
//     ----------------------------------------------------
//     testamento-profile-userlocked            2026-09-01 11:15:31
//     ----------------------------------------------------
//
//   Verbose, path-based (older):
//     /net/openvpn/v3/configuration/1a2b3c
//      Fri Jan 10 09:15:22 2025    ...    3
//      testamento-profile-userlocked           owner
//
// Both are supported: a record introduced by a config path line is parsed the
// verbose way; any other data row between separators is a compact row whose
// first column (before the run of spaces) is the profile name.
//
// Returns { ok, configs: [{ name, path }], error }.
function parseConfigsList(raw) {
    var text = String(raw || "").trim();
    if (text === "") {
        return { ok: true, configs: [], error: "" };
    }
    if (/no configuration/i.test(text)) {
        return { ok: true, configs: [], error: "" };
    }

    var lines = toLines(raw);
    var configs = [];
    var seen = {};
    var pendingPath = "";
    var recordLines = [];

    function push(name, path) {
        var safeName = clip(name, MAX_NAME_LEN);
        if (safeName === "" || seen[safeName] === true) return;
        if (configs.length >= MAX_RECORDS) return;
        seen[safeName] = true;
        configs.push({ name: safeName, path: validatePath(path, CONFIG_PATH_PREFIX) });
    }

    function flushVerbose() {
        if (pendingPath !== "") {
            push(nameFromRecord(recordLines), pendingPath);
        }
        pendingPath = "";
        recordLines = [];
    }

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var trimmed = line.trim();
        if (trimmed === "" || isSeparator(line)) {
            continue;
        }

        var pathIndex = trimmed.indexOf(CONFIG_PATH_PREFIX);
        if (pathIndex !== -1) {
            flushVerbose();
            pendingPath = trimmed.slice(pathIndex).split(/\s+/)[0];
            continue;
        }

        if (isHeaderRow(trimmed)) {
            continue;
        }

        if (pendingPath !== "") {
            // Inside a verbose record: collect its rows for nameFromRecord.
            recordLines.push(trimmed);
            continue;
        }

        // Compact table row: "<name>   <last used>".
        push(firstColumn(trimmed), "");
    }
    flushVerbose();

    return { ok: true, configs: configs, error: "" };
}

// Column-label rows that must never be treated as profiles. The compact table
// header is exactly "Configuration Name ... Last used"; the verbose layout has
// "Configuration path", "Imported", and a bare "Name" header.
function isHeaderRow(trimmed) {
    if (/^Configuration (Name|path)\b/.test(trimmed)) return true;
    if (/^(Imported|Name)\b/.test(trimmed)) return true;
    return false;
}

// The profile name is the first column, delimited from the trailing column
// (last-used date or owner) by a run of two or more spaces.
function firstColumn(rowText) {
    var parts = rowText.trim().split(/\s{2,}/);
    return parts.length > 0 ? parts[0].trim() : "";
}

var WEEKDAY_PREFIX = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/;

// Picks the profile name out of a verbose record's data rows. The timestamp
// row starts with a weekday, so the name row is the first row that does not —
// or, failing that, the last row.
function nameFromRecord(recordLines) {
    if (!(recordLines instanceof Array) || recordLines.length === 0) {
        return "";
    }
    var nameRow = "";
    for (var i = 0; i < recordLines.length; i++) {
        if (!WEEKDAY_PREFIX.test(recordLines[i])) {
            nameRow = recordLines[i];
            break;
        }
    }
    if (nameRow === "") {
        nameRow = recordLines[recordLines.length - 1];
    }
    return firstColumn(nameRow);
}

// Parses `openvpn3 sessions-list`.
//
// Each session is a labelled block delimited by separators. We collect the
// "Config name" and "Status" fields for every block.
//
// Returns { ok, sessions: [{ name, path, status, connected }], error }.
function parseSessionsList(raw) {
    var text = String(raw || "").trim();
    if (text === "" || /no sessions/i.test(text)) {
        return { ok: true, sessions: [], error: "" };
    }

    var lines = toLines(raw);
    var sessions = [];
    var current = null;

    for (var i = 0; i < lines.length; i++) {
        var trimmed = lines[i].trim();
        if (isSeparator(lines[i])) {
            if (current && current.name !== "") {
                if (sessions.length < MAX_RECORDS) sessions.push(finalizeSession(current));
            }
            current = { name: "", path: "", status: "" };
            continue;
        }
        if (current === null) {
            current = { name: "", path: "", status: "" };
        }
        assignSessionField(current, trimmed);
    }
    if (current && current.name !== "") {
        if (sessions.length < MAX_RECORDS) sessions.push(finalizeSession(current));
    }

    return { ok: true, sessions: sessions, error: "" };
}

// Fills a single labelled field into the session accumulator.
function assignSessionField(session, trimmed) {
    var pathIndex = trimmed.indexOf(SESSION_PATH_PREFIX);
    if (pathIndex !== -1) {
        session.path = validatePath(
            trimmed.slice(pathIndex).split(/\s+/)[0],
            SESSION_PATH_PREFIX
        );
        return;
    }
    var match = /^([A-Za-z ]+):\s*(.+)$/.exec(trimmed);
    if (!match) {
        return;
    }
    var label = match[1].trim().toLowerCase();
    var value = match[2].trim();
    if (label === "config name") {
        session.name = clip(value, MAX_NAME_LEN);
    } else if (label === "status") {
        session.status = clip(value, MAX_STATUS_LEN);
    }
}

// A session counts as connected once its status line reports "connected".
function finalizeSession(session) {
    return {
        name: session.name,
        path: session.path,
        status: session.status,
        connected: /connected/i.test(session.status),
    };
}

// Merges configs and sessions into the rows the panel renders.
//
// Returns [{ name, configPath, sessionPath, state }] where state is one of:
//   "connected" | "connecting" | "disconnected".
//
// Both paths are already validated D-Bus object paths (or "") so that state
// changes can target an exact object ID instead of an ambiguous name.
function buildRows(configsResult, sessionsResult) {
    var configs = configsResult && configsResult.configs instanceof Array
        ? configsResult.configs
        : [];
    var sessions = sessionsResult && sessionsResult.sessions instanceof Array
        ? sessionsResult.sessions
        : [];

    return configs.map(function (cfg) {
        var session = sessionByName(sessions, cfg.name);
        return {
            name: clip(cfg.name, MAX_NAME_LEN),
            configPath: validatePath(cfg.path, CONFIG_PATH_PREFIX),
            sessionPath: session ? validatePath(session.path, SESSION_PATH_PREFIX) : "",
            state: sessionState(session),
        };
    });
}

function sessionByName(sessions, name) {
    for (var i = 0; i < sessions.length; i++) {
        if (sessions[i].name === name) {
            return sessions[i];
        }
    }
    return null;
}

function sessionState(session) {
    if (!session) {
        return "disconnected";
    }
    return session.connected ? "connected" : "connecting";
}

// The name of the first connected session, else "".
function activeSessionName(sessionsResult) {
    var sessions = sessionsResult && sessionsResult.sessions instanceof Array
        ? sessionsResult.sessions
        : [];
    for (var i = 0; i < sessions.length; i++) {
        if (sessions[i].connected) {
            return clip(sessions[i].name, MAX_NAME_LEN);
        }
    }
    // Fall back to a connecting session so the bar still reflects activity.
    return sessions.length > 0 ? clip(sessions[0].name, MAX_NAME_LEN) : "";
}

function rowByName(rows, name) {
    var list = rows instanceof Array ? rows : [];
    for (var i = 0; i < list.length; i++) {
        if (list[i].name === name) {
            return list[i];
        }
    }
    return null;
}

// Human label for a row state.
function stateLabel(state) {
    if (state === "connected") {
        return "Connected";
    }
    if (state === "connecting") {
        return "Connecting…";
    }
    if (state === "error") {
        return "Failed";
    }
    return "Off";
}

// The bar-widget tooltip / hero title.
function heroText(activeName, state) {
    if (!activeName) {
        return "Disconnected";
    }
    return stateLabel(state) + " · " + clip(activeName, MAX_NAME_LEN);
}

// Resolves the validated config object path for a row, used to start a session
// against an exact ID rather than an ambiguous name. Returns "" when the row is
// unknown or its path did not validate.
function configPathForName(rows, name) {
    var row = rowByName(rows, name);
    return row && typeof row.configPath === "string" ? row.configPath : "";
}

// Resolves the validated session object path for a row, used to disconnect an
// exact running session rather than by name. Returns "" when there is no
// running session or its path did not validate.
function sessionPathForName(rows, name) {
    var row = rowByName(rows, name);
    return row && typeof row.sessionPath === "string" ? row.sessionPath : "";
}

// Clips arbitrary error text (e.g. a CLI stderr line) for safe, bounded display.
function clipError(value) {
    return clip(value, MAX_ERROR_LEN);
}

// Clips a display name for safe, bounded rendering in the UI layers.
function clipName(value) {
    return clip(value, MAX_NAME_LEN);
}

if (typeof module !== "undefined") {
    module.exports = {
        parseConfigsList: parseConfigsList,
        parseSessionsList: parseSessionsList,
        buildRows: buildRows,
        activeSessionName: activeSessionName,
        rowByName: rowByName,
        stateLabel: stateLabel,
        heroText: heroText,
        configPathForName: configPathForName,
        sessionPathForName: sessionPathForName,
        validatePath: validatePath,
        clip: clip,
        clipError: clipError,
        clipName: clipName,
        CONFIG_PATH_PREFIX: CONFIG_PATH_PREFIX,
        SESSION_PATH_PREFIX: SESSION_PATH_PREFIX,
        MAX_NAME_LEN: MAX_NAME_LEN,
        MAX_ERROR_LEN: MAX_ERROR_LEN,
        MAX_RECORDS: MAX_RECORDS,
    };
}
