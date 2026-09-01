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
    var pendingPath = "";
    var recordLines = [];

    function flush() {
        if (pendingPath !== "") {
            var name = extractConfigName(recordLines);
            if (name !== "") {
                configs.push({ name: name, path: pendingPath });
            }
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
            flush();
            pendingPath = trimmed.slice(pathIndex).split(/\s+/)[0];
            continue;
        }

        // Header rows carry these column labels; skip them.
        if (/^(Configuration|Imported|Name)\b/.test(trimmed)) {
            continue;
        }

        if (pendingPath !== "") {
            recordLines.push(trimmed);
        }
    }
    flush();

    return { ok: true, configs: configs, error: "" };
}

var WEEKDAY_PREFIX = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/;

// Picks the profile name out of a record's data rows. The timestamp/usage row
// starts with a weekday, so the name row is the first row that does not — or,
// failing that, the last row. The name is the first whitespace-delimited
// column (owner is the trailing column).
function extractConfigName(recordLines) {
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
    var parts = nameRow.trim().split(/\s{2,}/);
    return parts.length > 0 ? parts[0].trim() : "";
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
