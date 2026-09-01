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

// Splits raw command output into trimmed, non-empty lines.
function toLines(raw) {
    return String(raw || "")
        .split("\n")
        .map(function (line) { return line.replace(/\s+$/, ""); });
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
        if (name === "" || seen[name] === true) return;
        seen[name] = true;
        configs.push({ name: name, path: path });
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
                sessions.push(finalizeSession(current));
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
        sessions.push(finalizeSession(current));
    }

    return { ok: true, sessions: sessions, error: "" };
}

// Fills a single labelled field into the session accumulator.
function assignSessionField(session, trimmed) {
    var pathIndex = trimmed.indexOf(SESSION_PATH_PREFIX);
    if (pathIndex !== -1) {
        session.path = trimmed.slice(pathIndex).split(/\s+/)[0];
        return;
    }
    var match = /^([A-Za-z ]+):\s*(.+)$/.exec(trimmed);
    if (!match) {
        return;
    }
    var label = match[1].trim().toLowerCase();
    var value = match[2].trim();
    if (label === "config name") {
        session.name = value;
    } else if (label === "status") {
        session.status = value;
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
// Returns [{ name, path, state }] where state is one of:
//   "connected" | "connecting" | "disconnected".
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
            name: cfg.name,
            path: cfg.path,
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
            return sessions[i].name;
        }
    }
    // Fall back to a connecting session so the bar still reflects activity.
    return sessions.length > 0 ? sessions[0].name : "";
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
    return stateLabel(state) + " · " + activeName;
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
    };
}
