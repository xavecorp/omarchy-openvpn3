const { test } = require("node:test");
const assert = require("node:assert");
const Model = require("./Model.js");

// Real output from the installed openvpn3 (session block).
const sessionsOutput = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/d1b24861s3d90s4e7dsa445s8ae0a1c9b59b
     Created: 2026-09-01 11:15:31                       PID: 58665
       Owner: xavierviricel                          Device: tun0
 Config name: testamento-profile-userlocked
Connected to: tcp:15.188.133.251:443
      Status: Connection, Client connected
-----------------------------------------------------------------------------
`;

// Real `openvpn3 configs-list --json` output — the object path is the key, the
// only source the code actually uses. One profile matching the session above
// (so buildRows can merge them) and one idle profile with no running session.
const configsListing = `{
    "/net/openvpn/v3/configuration/1a2b3c" : {
        "name" : "testamento-profile-userlocked",
        "owner" : "xavierviricel",
        "valid" : true
    },
    "/net/openvpn/v3/configuration/4d5e6f" : {
        "name" : "testamento",
        "owner" : "xavierviricel",
        "valid" : true
    }
}`;

test("parseSessionsList extracts a connected session", () => {
    const result = Model.parseSessionsList(sessionsOutput);
    assert.strictEqual(result.sessions.length, 1);
    assert.strictEqual(result.sessions[0].name, "testamento-profile-userlocked");
    assert.strictEqual(result.sessions[0].connected, true);
    assert.strictEqual(
        result.sessions[0].path,
        "/net/openvpn/v3/sessions/d1b24861s3d90s4e7dsa445s8ae0a1c9b59b"
    );
});

test("parseSessionsList handles no sessions", () => {
    assert.deepStrictEqual(
        Model.parseSessionsList("No sessions available"),
        { ok: true, sessions: [], error: "" }
    );
});

test("buildRows merges the configs listing with the active session", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsListing),
        Model.parseSessionsList(sessionsOutput)
    );
    assert.strictEqual(rows.length, 2);
    assert.strictEqual(
        Model.rowByPath(rows, "/net/openvpn/v3/configuration/1a2b3c").state,
        "connected"
    );
});

test("activeSessionName returns the connected session", () => {
    assert.strictEqual(
        Model.activeSessionName(Model.parseSessionsList(sessionsOutput)),
        "testamento-profile-userlocked"
    );
    assert.strictEqual(Model.activeSessionName(Model.parseSessionsList("")), "");
});

test("connecting state when a session exists but is not yet connected", () => {
    const connecting = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/bbbb
 Config name: testamento-profile-userlocked
      Status: Connection, Client connecting
-----------------------------------------------------------------------------`;
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsListing),
        Model.parseSessionsList(connecting)
    );
    assert.strictEqual(
        Model.rowByPath(rows, "/net/openvpn/v3/configuration/1a2b3c").state,
        "connecting"
    );
});

// ---- Security / robustness (reviewer fixes) --------------------------------

test("clip strips control characters and rich-text/escape injection", () => {
    // ANSI escape + newline + tab must not survive into a display string.
    const hostile = "profile\u001b[31m\nDROP\tTABLE";
    const cleaned = Model.clip(hostile, Model.MAX_NAME_LEN);
    assert.ok(!/[\u0000-\u001F]/.test(cleaned), "no control chars remain");
    assert.strictEqual(cleaned, "profile [31m DROP TABLE");
});

test("clip truncates to the requested ceiling", () => {
    const long = "a".repeat(5000);
    assert.strictEqual(Model.clip(long, Model.MAX_NAME_LEN).length, Model.MAX_NAME_LEN);
    assert.strictEqual(Model.clipError(long).length, Model.MAX_ERROR_LEN);
});

test("clip coerces null/undefined to an empty string", () => {
    assert.strictEqual(Model.clip(undefined, 10), "");
    assert.strictEqual(Model.clip(null, 10), "");
});

test("parseConfigsListJson clips overly long profile names", () => {
    const longName = "z".repeat(400);
    const raw = `{ "/net/openvpn/v3/configuration/1a2b3c" : { "name" : "${longName}" } }`;
    const result = Model.parseConfigsListJson(raw);
    assert.strictEqual(result.configs.length, 1);
    assert.strictEqual(result.configs[0].name.length, Model.MAX_NAME_LEN);
});

test("parseConfigsListJson caps the number of records", () => {
    const entries = [];
    // Emit far more entries than the cap; each has a distinct object path.
    for (let i = 0; i < Model.MAX_RECORDS + 50; i++) {
        entries.push(`"/net/openvpn/v3/configuration/p${i}" : { "name" : "profile-${i}" }`);
    }
    const raw = `{ ${entries.join(",")} }`;
    const result = Model.parseConfigsListJson(raw);
    assert.strictEqual(result.configs.length, Model.MAX_RECORDS);
});

test("validatePath accepts a well-formed object path and rejects the rest", () => {
    const good = "/net/openvpn/v3/configuration/1a2b3c";
    assert.strictEqual(Model.validatePath(good, Model.CONFIG_PATH_PREFIX), good);

    // Wrong prefix.
    assert.strictEqual(
        Model.validatePath("/etc/passwd", Model.CONFIG_PATH_PREFIX),
        ""
    );
    // Prefix present but injected shell metacharacters in the tail.
    assert.strictEqual(
        Model.validatePath("/net/openvpn/v3/configuration/x;rm -rf ~", Model.CONFIG_PATH_PREFIX),
        ""
    );
    // Empty tail.
    assert.strictEqual(
        Model.validatePath("/net/openvpn/v3/configuration/", Model.CONFIG_PATH_PREFIX),
        ""
    );
});

test("buildRows exposes validated config and session object paths", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsListing),
        Model.parseSessionsList(sessionsOutput)
    );
    const active = Model.rowByPath(rows, "/net/openvpn/v3/configuration/1a2b3c");
    assert.strictEqual(active.configPath, "/net/openvpn/v3/configuration/1a2b3c");
    assert.strictEqual(
        active.sessionPath,
        "/net/openvpn/v3/sessions/d1b24861s3d90s4e7dsa445s8ae0a1c9b59b"
    );
    // A profile with no running session has an empty session path.
    const idle = Model.rowByPath(rows, "/net/openvpn/v3/configuration/4d5e6f");
    assert.strictEqual(idle.sessionPath, "");
});

test("parseSessionsList sanitizes injected escape codes in status/name", () => {
    const hostile = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/cccc
 Config name: evil\u001b]0;pwned\u0007
      Status: Connection, \u001b[2JClient connected
-----------------------------------------------------------------------------`;
    const result = Model.parseSessionsList(hostile);
    assert.strictEqual(result.sessions.length, 1);
    assert.ok(!/[\u0000-\u001F]/.test(result.sessions[0].name));
    assert.ok(!/[\u0000-\u001F]/.test(result.sessions[0].status));
    // No control chars survive into the displayed status. Note the state is
    // resolved from the sanitized status with an ANCHORED "\bclient connected\b"
    // match: an escape glued to the label (…[2JClient connected) breaks the word
    // boundary and is deliberately NOT trusted as connected — corrupt input must
    // never be reported as a live tunnel.
    assert.strictEqual(result.sessions[0].connected, false);
    assert.strictEqual(result.sessions[0].state, "connecting");
});

test("parseSessionsList classifies a clean connected status with an injected name escape", () => {
    // Escapes injected into the NAME field must not affect the status parse: a
    // well-formed status still reads as connected.
    const hostile = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/dddd
 Config name: evil\u001b]0;pwned\u0007
      Status: Connection, Client connected
-----------------------------------------------------------------------------`;
    const result = Model.parseSessionsList(hostile);
    assert.strictEqual(result.sessions.length, 1);
    assert.ok(!/[\u0000-\u001F]/.test(result.sessions[0].name));
    assert.strictEqual(result.sessions[0].connected, true);
    assert.strictEqual(result.sessions[0].state, "connected");
});

// ---- JSON configs listing (preferred source, keyed by object path) ---------

const configsJson = `{
    "/net/openvpn/v3/configuration/0c19147cx7ecex4846xbc1axb44fdb7e730c" : {
        "name" : "testamento-profile-userlocked",
        "owner" : "xavierviricel",
        "valid" : true
    }
}`;

test("parseConfigsListJson extracts name keyed by the exact object path", () => {
    const result = Model.parseConfigsListJson(configsJson);
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.configs.length, 1);
    assert.strictEqual(result.configs[0].name, "testamento-profile-userlocked");
    assert.strictEqual(
        result.configs[0].path,
        "/net/openvpn/v3/configuration/0c19147cx7ecex4846xbc1axb44fdb7e730c"
    );
});

test("parseConfigsListJson feeds a resolvable configPath end to end", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsJson),
        Model.parseSessionsList("")
    );
    const row = Model.rowByPath(
        rows,
        "/net/openvpn/v3/configuration/0c19147cx7ecex4846xbc1axb44fdb7e730c"
    );
    assert.ok(row);
    assert.strictEqual(row.name, "testamento-profile-userlocked");
    assert.strictEqual(
        row.configPath,
        "/net/openvpn/v3/configuration/0c19147cx7ecex4846xbc1axb44fdb7e730c"
    );
});

test("parseConfigsListJson handles empty and malformed input", () => {
    assert.deepStrictEqual(
        Model.parseConfigsListJson(""),
        { ok: true, configs: [], error: "" }
    );
    const bad = Model.parseConfigsListJson("{ not json");
    assert.strictEqual(bad.ok, false);
    assert.deepStrictEqual(bad.configs, []);
});

test("parseConfigsListJson skips entries with an invalid object path", () => {
    const raw = `{
        "/etc/passwd" : { "name" : "evil" },
        "/net/openvpn/v3/configuration/good" : { "name" : "real" }
    }`;
    const result = Model.parseConfigsListJson(raw);
    assert.deepStrictEqual(
        result.configs.map((c) => c.name),
        ["real"]
    );
});

// ---- Identity is the object path, never the display name -------------------

// Two distinct profiles that deliberately share the same display name. Only
// their object paths tell them apart — exactly the case that must not collide.
const configsDuplicateNames = `{
    "/net/openvpn/v3/configuration/aaaaaaaa" : { "name" : "work" },
    "/net/openvpn/v3/configuration/bbbbbbbb" : { "name" : "work" }
}`;

test("parseConfigsListJson keeps duplicate display names as distinct rows keyed by path", () => {
    const result = Model.parseConfigsListJson(configsDuplicateNames);
    assert.strictEqual(result.configs.length, 2);
    assert.deepStrictEqual(
        result.configs.map((c) => c.name),
        ["work", "work"]
    );
    assert.deepStrictEqual(
        result.configs.map((c) => c.path),
        [
            "/net/openvpn/v3/configuration/aaaaaaaa",
            "/net/openvpn/v3/configuration/bbbbbbbb",
        ]
    );
});

test("parseConfigsListJson dedups on the object path, not the name", () => {
    // The same object path appearing twice collapses to one row; two different
    // paths with the same name do not.
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsDuplicateNames),
        Model.parseSessionsList("")
    );
    assert.strictEqual(rows.length, 2);
    assert.strictEqual(rows[0].configPath, "/net/openvpn/v3/configuration/aaaaaaaa");
    assert.strictEqual(rows[1].configPath, "/net/openvpn/v3/configuration/bbbbbbbb");
});

test("rowByPath resolves the exact row even when display names collide", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsDuplicateNames),
        Model.parseSessionsList("")
    );
    const a = Model.rowByPath(rows, "/net/openvpn/v3/configuration/aaaaaaaa");
    const b = Model.rowByPath(rows, "/net/openvpn/v3/configuration/bbbbbbbb");
    assert.ok(a && b);
    assert.strictEqual(a.configPath, "/net/openvpn/v3/configuration/aaaaaaaa");
    assert.strictEqual(b.configPath, "/net/openvpn/v3/configuration/bbbbbbbb");
    assert.notStrictEqual(a, b);
});

test("rowByPath never matches an empty, non-string, or unknown path", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsJson),
        Model.parseSessionsList("")
    );
    assert.strictEqual(Model.rowByPath(rows, ""), null);
    assert.strictEqual(Model.rowByPath(rows, undefined), null);
    assert.strictEqual(Model.rowByPath(rows, null), null);
    assert.strictEqual(Model.rowByPath(rows, "/net/openvpn/v3/configuration/nope"), null);
    assert.strictEqual(Model.rowByPath([], "/net/openvpn/v3/configuration/x"), null);
});

test("rowByPath resolves the running session by config path", () => {
    const rows = Model.buildRows(
        Model.parseConfigsListJson(configsJson),
        Model.parseSessionsList(sessionsOutput)
    );
    const activePath = "/net/openvpn/v3/configuration/0c19147cx7ecex4846xbc1axb44fdb7e730c";
    assert.strictEqual(
        Model.rowByPath(rows, activePath).sessionPath,
        "/net/openvpn/v3/sessions/d1b24861s3d90s4e7dsa445s8ae0a1c9b59b"
    );
    // Unknown / empty config paths resolve to no row, never a wrong session.
    assert.strictEqual(Model.rowByPath(rows, "/net/openvpn/v3/configuration/other"), null);
    assert.strictEqual(Model.rowByPath(rows, ""), null);
});


// ---- A1: StatusMinor -> state mapping (anchored, never substring) ----------

// Real StatusMinor labels emitted by openvpn3 (see `strings /usr/bin/openvpn3`),
// each wrapped in the "Connection, <label>" shape the CLI prints on the Status
// row, plus the bare labels for authentication/timeout events.
test("sessionStateFromStatus maps real StatusMinor labels to states", () => {
    // The critical case: "disconnected" contains "connected" as a substring.
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client connected"), "connected");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client disconnected"), "disconnected");
    assert.strictEqual(
        Model.sessionStateFromStatus("Connection, Client disconnected by server"),
        "disconnected"
    );
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client disconnecting"), "disconnected");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client connecting"), "connecting");
    assert.strictEqual(
        Model.sessionStateFromStatus("Configuration requires user input: Username/password"),
        "auth"
    );
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client connection paused"), "paused");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Authentication failed"), "error");
    assert.strictEqual(
        Model.sessionStateFromStatus("Connection, Client authentication failed"),
        "error"
    );
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client connection failed"), "error");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client process exited"), "error");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Connection timeout"), "error");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client reconnect"), "connecting");
    assert.strictEqual(Model.sessionStateFromStatus("Connection, Client connection resuming"), "connecting");
});

test("sessionStateFromStatus defaults to connecting, never connected", () => {
    assert.strictEqual(Model.sessionStateFromStatus(""), "connecting");
    assert.strictEqual(Model.sessionStateFromStatus(undefined), "connecting");
    assert.strictEqual(Model.sessionStateFromStatus("Some unknown status"), "connecting");
});

test("finalizeSession exposes the resolved state and a derived connected flag", () => {
    // A server-side kick is a persistent state whose status still contains the
    // "connected" substring — it must resolve to disconnected, not connected.
    const kicked = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/kkkk
 Config name: kicked-profile
      Status: Connection, Client disconnected by server
-----------------------------------------------------------------------------`;
    const result = Model.parseSessionsList(kicked);
    assert.strictEqual(result.sessions.length, 1);
    assert.strictEqual(result.sessions[0].state, "disconnected");
    assert.strictEqual(result.sessions[0].connected, false);
});

// ---- A2: multi-session parsing (blocks split on the Path: line) ------------

// Two sessions separated only by a blank line — no separator rule between the
// blocks, only at the very top and bottom. The connected one must survive.
const twoSessionsBlankSeparated = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/1111
 Config name: alpha
      Status: Connection, Client connected

        Path: /net/openvpn/v3/sessions/2222
 Config name: beta
      Status: Connection, Client connecting
-----------------------------------------------------------------------------`;

test("parseSessionsList splits two blocks separated by a blank line", () => {
    const result = Model.parseSessionsList(twoSessionsBlankSeparated);
    assert.strictEqual(result.sessions.length, 2);
    assert.deepStrictEqual(
        result.sessions.map((s) => s.name),
        ["alpha", "beta"]
    );
    // The connected session is preserved and correctly classified.
    const alpha = result.sessions.find((s) => s.name === "alpha");
    assert.strictEqual(alpha.state, "connected");
    assert.strictEqual(alpha.connected, true);
    const beta = result.sessions.find((s) => s.name === "beta");
    assert.strictEqual(beta.state, "connecting");
});

test("activeSessionName picks the connected session out of a blank-separated list", () => {
    assert.strictEqual(
        Model.activeSessionName(Model.parseSessionsList(twoSessionsBlankSeparated)),
        "alpha"
    );
});

// Two sessions delimited by a separator rule between blocks (the other layout)
// must also yield two sessions.
const twoSessionsSeparatorSeparated = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/1111
 Config name: alpha
      Status: Connection, Client connected
-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/2222
 Config name: beta
      Status: Connection, Client connecting
-----------------------------------------------------------------------------`;

test("parseSessionsList splits two blocks separated by a separator rule", () => {
    const result = Model.parseSessionsList(twoSessionsSeparatorSeparated);
    assert.strictEqual(result.sessions.length, 2);
    assert.deepStrictEqual(
        result.sessions.map((s) => s.name),
        ["alpha", "beta"]
    );
    assert.strictEqual(Model.activeSessionName(result), "alpha");
});

// ---- A3: state -> label table ----------------------------------------------

test("stateLabel covers every reachable state with English labels", () => {
    assert.strictEqual(Model.stateLabel("connected"), "Connected");
    assert.strictEqual(Model.stateLabel("connecting"), "Connecting…");
    assert.strictEqual(Model.stateLabel("auth"), "Auth required");
    assert.strictEqual(Model.stateLabel("paused"), "Paused");
    assert.strictEqual(Model.stateLabel("error"), "Failed");
    assert.strictEqual(Model.stateLabel("disconnected"), "Off");
    assert.strictEqual(Model.stateLabel("anything-else"), "Off");
});
