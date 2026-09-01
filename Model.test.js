const { test } = require("node:test");
const assert = require("node:assert");
const Model = require("./Model.js");

// Real output from the installed openvpn3 (compact table layout).
const configsCompact = `Configuration Name                                        Last used
------------------------------------------------------------------------------
testamento-profile-userlocked                             2026-09-01 11:15:31
------------------------------------------------------------------------------
`;

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

// Legacy verbose layout (older openvpn3), still supported.
const configsVerbose = `Configuration path
Imported                                     Last used                 Used
Name                                                                   Owner
------------------------------------------------------------------------------
/net/openvpn/v3/configuration/1a2b3c
 Fri Jan 10 09:15:22 2025                     Fri Jan 10 09:16:00 2025     3
 testamento-profile-userlocked                                          xavier
------------------------------------------------------------------------------
/net/openvpn/v3/configuration/4d5e6f
 Fri Jan 10 10:00:00 2025                     Fri Jan 10 10:01:00 2025     1
 testamento                                                             xavier
------------------------------------------------------------------------------`;

test("parseConfigsList reads the compact table layout", () => {
    const result = Model.parseConfigsList(configsCompact);
    assert.strictEqual(result.ok, true);
    assert.deepStrictEqual(
        result.configs.map((c) => c.name),
        ["testamento-profile-userlocked"]
    );
});

test("parseConfigsList reads the legacy verbose layout", () => {
    const result = Model.parseConfigsList(configsVerbose);
    assert.deepStrictEqual(
        result.configs.map((c) => c.name),
        ["testamento-profile-userlocked", "testamento"]
    );
    assert.strictEqual(result.configs[0].path, "/net/openvpn/v3/configuration/1a2b3c");
});

test("parseConfigsList handles empty listing", () => {
    assert.deepStrictEqual(Model.parseConfigsList(""), { ok: true, configs: [], error: "" });
    assert.deepStrictEqual(
        Model.parseConfigsList("No configuration profiles available"),
        { ok: true, configs: [], error: "" }
    );
});

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

test("buildRows merges the compact configs with the active session", () => {
    const rows = Model.buildRows(
        Model.parseConfigsList(configsCompact),
        Model.parseSessionsList(sessionsOutput)
    );
    assert.strictEqual(rows.length, 1);
    assert.strictEqual(
        Model.rowByName(rows, "testamento-profile-userlocked").state,
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
        Model.parseConfigsList(configsCompact),
        Model.parseSessionsList(connecting)
    );
    assert.strictEqual(
        Model.rowByName(rows, "testamento-profile-userlocked").state,
        "connecting"
    );
});
