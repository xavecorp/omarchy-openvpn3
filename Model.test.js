const { test } = require("node:test");
const assert = require("node:assert");
const Model = require("./Model.js");

const configsOutput = `Configuration path
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

const sessionsOutput = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/aaaa
     Created: Fri Jan 10 09:16:00 2025                     PID: 12345
       Owner: xavier                                    Device: tun0
 Config name: testamento-profile-userlocked
Session name: testamento-profile-userlocked
      Status: Connection, Client connected
-----------------------------------------------------------------------------`;

test("parseConfigsList extracts profile names and paths", () => {
    const result = Model.parseConfigsList(configsOutput);
    assert.strictEqual(result.ok, true);
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
    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.sessions.length, 1);
    assert.strictEqual(result.sessions[0].name, "testamento-profile-userlocked");
    assert.strictEqual(result.sessions[0].connected, true);
    assert.strictEqual(result.sessions[0].path, "/net/openvpn/v3/sessions/aaaa");
});

test("parseSessionsList handles no sessions", () => {
    assert.deepStrictEqual(
        Model.parseSessionsList("No sessions available"),
        { ok: true, sessions: [], error: "" }
    );
});

test("buildRows merges configs and sessions into states", () => {
    const configs = Model.parseConfigsList(configsOutput);
    const sessions = Model.parseSessionsList(sessionsOutput);
    const rows = Model.buildRows(configs, sessions);
    assert.strictEqual(rows.length, 2);
    assert.strictEqual(Model.rowByName(rows, "testamento-profile-userlocked").state, "connected");
    assert.strictEqual(Model.rowByName(rows, "testamento").state, "disconnected");
});

test("activeSessionName returns the connected session", () => {
    const sessions = Model.parseSessionsList(sessionsOutput);
    assert.strictEqual(Model.activeSessionName(sessions), "testamento-profile-userlocked");
    assert.strictEqual(Model.activeSessionName(Model.parseSessionsList("")), "");
});

test("connecting state when session exists but not yet connected", () => {
    const connecting = `-----------------------------------------------------------------------------
        Path: /net/openvpn/v3/sessions/bbbb
 Config name: testamento
      Status: Connection, Client connecting
-----------------------------------------------------------------------------`;
    const sessions = Model.parseSessionsList(connecting);
    assert.strictEqual(sessions.sessions[0].connected, false);
    const rows = Model.buildRows(Model.parseConfigsList(configsOutput), sessions);
    assert.strictEqual(Model.rowByName(rows, "testamento").state, "connecting");
});
