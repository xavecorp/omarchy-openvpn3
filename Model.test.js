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

test("parseConfigsList clips overly long profile names", () => {
    const longName = "z".repeat(400);
    const raw = `Configuration Name                                        Last used
------------------------------------------------------------------------------
${longName}            2026-09-01 11:15:31
------------------------------------------------------------------------------`;
    const result = Model.parseConfigsList(raw);
    assert.strictEqual(result.configs.length, 1);
    assert.strictEqual(result.configs[0].name.length, Model.MAX_NAME_LEN);
});

test("parseConfigsList caps the number of records", () => {
    let raw = "Configuration Name                                        Last used\n";
    raw += "------------------------------------------------------------------------------\n";
    // Emit far more rows than the cap; each is a distinct compact-table row.
    for (let i = 0; i < Model.MAX_RECORDS + 50; i++) {
        raw += `profile-${i}            2026-09-01 11:15:31\n`;
    }
    raw += "------------------------------------------------------------------------------\n";
    const result = Model.parseConfigsList(raw);
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
        Model.parseConfigsList(configsVerbose),
        Model.parseSessionsList(sessionsOutput)
    );
    const active = Model.rowByName(rows, "testamento-profile-userlocked");
    assert.strictEqual(active.configPath, "/net/openvpn/v3/configuration/1a2b3c");
    assert.strictEqual(
        active.sessionPath,
        "/net/openvpn/v3/sessions/d1b24861s3d90s4e7dsa445s8ae0a1c9b59b"
    );
    // A profile with no running session has an empty session path.
    const idle = Model.rowByName(rows, "testamento");
    assert.strictEqual(idle.sessionPath, "");
});

test("configPathForName / sessionPathForName resolve exact IDs, empty when absent", () => {
    const rows = Model.buildRows(
        Model.parseConfigsList(configsVerbose),
        Model.parseSessionsList(sessionsOutput)
    );
    assert.strictEqual(
        Model.configPathForName(rows, "testamento-profile-userlocked"),
        "/net/openvpn/v3/configuration/1a2b3c"
    );
    assert.strictEqual(
        Model.sessionPathForName(rows, "testamento"),
        ""
    );
    assert.strictEqual(Model.configPathForName(rows, "does-not-exist"), "");
    assert.strictEqual(Model.sessionPathForName(rows, "does-not-exist"), "");
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
    // Status still classified as connected despite the injected escape.
    assert.strictEqual(result.sessions[0].connected, true);
});

test("heroText clips the active name", () => {
    const longName = "n".repeat(400);
    const hero = Model.heroText(longName, "connected");
    // "Connected · " prefix plus a clipped name.
    assert.ok(hero.length <= "Connected · ".length + Model.MAX_NAME_LEN);
    assert.ok(hero.indexOf("Connected · ") === 0);
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
    assert.strictEqual(
        Model.configPathForName(rows, "testamento-profile-userlocked"),
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
