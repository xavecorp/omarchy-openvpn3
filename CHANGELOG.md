# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-09-05

### Removed

- Delete ~235 lines of dead code with no observable behaviour change. The
  text-based `configs-list` parser (`parseConfigsList` and its private helpers)
  is gone now that the plugin reads `configs-list --json` exclusively;
  `isSeparator` is kept as `parseSessionsList` still uses it. The unused
  resolvers `configPathForName`, `sessionPathForName`,
  `sessionPathForConfigPath` and `heroText` are removed. In `Service.qml` the
  `refreshing` property (written but never read) and the `errorHold` timer (no
  handler, no reader — inert) are removed. Tests dropped from 35 to 30: the
  ones covering deleted code were removed, and those that used the text parser
  only as a fixture factory were migrated to `parseConfigsListJson` / `rowByPath`
  so live coverage (validated paths, name clipping, record cap) is preserved.
  (A15, A16, A17)

## [0.3.1] - 2026-09-05

### Fixed

- Keep the profile list inside the popup card and make it scrollable. Beyond
  roughly sixteen profiles the list used to be painted outside the card and
  then off-screen, unreachable by mouse or keyboard, and the error text (the
  last child) went with it. The body now lives in a clipped `Flickable` with an
  as-needed scrollbar, a height cap, and `ensureVisible` so the keyboard cursor
  always scrolls into view. (A10)
- Give each profile card the 2px it was missing: the frame now reserves
  `Style.spacing.md * 2` to match the row's top and bottom margins, so the row
  content is no longer vertically compressed. (A11)

## [0.3.0] - 2026-09-05

### Fixed

- Never leave an orphaned `openvpn3` process behind. Command invocations are
  wrapped with `timeout --signal=KILL` instead of `--signal=TERM`: a child that
  ignores SIGTERM (which `session-start` does) previously survived the wrapper,
  reparented and burning CPU until reboot. KILL to the process group cannot be
  trapped or ignored. (A5)
- Bound command output at the OS level for stderr too, not just stdout. Reads
  run `… 2>/dev/null | head -c N` and the disconnect action runs `… 2>&1 | head
  -c N`, so a noisy or hostile subprocess can no longer stream unbounded stderr
  into the shell's memory. `2>&1` is deliberately never applied to
  `configs-list --json`, whose stream must stay valid JSON. The unused stderr
  collectors were removed. (A6)
- Invalidate `probeProcess` on component destruction like the other processes,
  so a probe result can no longer re-arm a half-destroyed service. (A7)
- Re-arm the read watchdog at the start of each read rather than once for the
  whole configs→sessions chain, so a slow-but-healthy pair of reads no longer
  trips a false "openvpn3 stopped responding". (A8)

### Changed

- Start sessions in a floating terminal instead of a headless process. A
  user-locked / 2FA / static-challenge profile prompts for credentials on
  stdin; a headless process had no stdin to answer with, so it looped on the
  prompt for 40s, surfaced a D-Bus path as the "error", and left a stuck
  backend — the plugin's main use case was effectively broken. `session-start`
  now runs through the host shell's floating-terminal launcher where the user
  can authenticate; the connect/disconnect decision moved to the panel and bar
  widget (which own `bar`), and `Service` only validates and hands back the
  argv. A profile awaiting input reads `Auth required`. (A9)

### Fixed

- Stop reporting a dead tunnel as connected. Session state is now derived from
  an explicit map of the openvpn3 *StatusMinor* labels, anchored on
  `\bclient connected\b`, instead of a substring test that also matched
  `"disconnected"` and `"disconnected by server"`. The state now defaults to
  `connecting` (never `connected`) for any status it does not recognise. (A1)
- Parse every session from `sessions-list`, not just the last one. Blocks are
  now delimited on their `Path:` line rather than on a separator, since the CLI
  only prints a separator at the very top and bottom of the listing — with two
  or more sessions the connected one was previously dropped and the wrong
  session was reported active. (A2)
- Surface the states the UI could not previously express: a session awaiting
  credentials shows `Auth required`, a paused one `Paused`, and an
  authentication/connection failure `Failed`, each with a non-green colour —
  instead of an indefinite `Connecting…`. (A3)
- Never let a failure degrade towards "connected". When the active session is
  not yet reflected in a row the derived state falls back to `connecting`, and
  when a `configs-list` read returns invalid data the previous view is kept but
  flagged stale so the icon reports `error` rather than a leftover green until a
  clean read returns. (A4)

### Fixed

- Paint the bar icon from the bar's `barForeground` colour instead of
  `foreground`. On a transparent bar over a light wallpaper the shell resolves
  `barForeground` to a contrast-appropriate colour, whereas `foreground` stays
  the theme/popup text colour — using the latter rendered the icon light on a
  dark bar. This matches every stock bar widget (WidgetButton, tailscale,
  dropbox), which all source bar chrome from `barForeground`.
- Align the panel with the shell's design tokens. Typography now uses the
  `Style.font.*` scale (title / body / caption) driven by the system font size
  (`omarchy display text size`) instead of hard-coded `Qt.application.font`
  multipliers, so text is consistent with the rest of the shell and other
  plugins. Spacing/padding now uses the semantic `Style.spacing.*` tokens
  (`panelPadding`, `panelGap`, `rowPaddingX`, `controlGap`, …) and
  `Style.cornerRadius` rather than arbitrary pixel values, fixing the padding
  and margin inconsistencies. The separator rule reuses the shared
  `PanelSeparator` component.
- Stop double-padding the panel body. The `KeyboardPanel` card already insets
  its content by `padding` on every side; the column also carried
  `anchors.margins`, stacking a second inset that made the left/right/top gaps
  oversized while the bottom was clipped. The column now anchors top/left/right
  only and lets its `implicitHeight` drive the card height, so all four sides
  are padded symmetrically by the card. The header mark is sized to the title's
  display height so it no longer looks shrunken next to the title.

## [0.2.1] - 2026-09-04

### Security

- Cap every CLI invocation's output at the OS level: the command now runs as
  `openvpn3 … | head -c <ceiling>` under `timeout`, so at most the ceiling ever
  reaches the collector. The byte limit bites *before* buffering rather than
  truncating an already fully-buffered stream, closing a memory-exhaustion
  vector from a runaway or hostile subprocess. `set -o pipefail` keeps the
  openvpn3 exit status authoritative (never `head`'s). The wrapper is
  injection-safe: a fixed shell script with every dynamic value passed as a
  quoted positional parameter, over already path-validated arguments.
- Reject any non-zero CLI exit outright, regardless of what text the command
  emitted. A failed `configs-list`/`sessions-list`/session action can no longer
  slip partial, stale, or hostile output into parsing or the last-good view
  just because it printed something before failing.

### Fixed

- Key profile selection, optimistic state, and every UI action on the profile's
  unique config object path instead of its display name. Two profiles that
  share a name are now individually addressable — a toggle, the keyboard
  cursor, the busy indicator, and the bar right-click quick-toggle all target
  the exact profile the user acted on. Duplicate display names are preserved as
  distinct rows keyed by path rather than being silently dropped.
- Invalidate service state and reap every active process group on component
  destruction (shell reload / widget removal). A new `Component.onDestruction`
  latches the service dead, stops all timers, and terminates each running
  process — SIGTERM to the `timeout` parent relays to its whole process group
  (bash + openvpn3 + head), so no tunnel helper survives the widget.

## [0.2.0] - 2026-09-02

### Added

- Redesigned panel layout with clearer visual grouping, top to bottom: a header
  band with the plugin icon and an "OpenVPN3" title; a status subtitle with a
  coloured state dot (green connected, amber connecting, red error, grey off)
  and, when connected, the active configuration name; a horizontal separator
  rule; then the list of profiles.
- Each profile is now a framed card carrying its own coloured state dot, name,
  a small coloured state label, and its toggle. The card under the keyboard
  cursor is highlighted with a stronger fill and border.
- Add a root `preview.png` screenshot of the panel, shown in the README and
  detected by the Omarchy plugin marketplace as the listing preview.

## [0.1.2] - 2026-09-02

### Security

- Resolve the `openvpn3` client to a trusted absolute path from a fixed
  allowlist instead of looking it up through the inherited `PATH`, so a hostile
  binary earlier on `PATH` can no longer shadow the real client.
- Start and stop sessions by their exact validated D-Bus object path
  (`session-start --config-path`, `session-manage --session-path --disconnect`)
  rather than by an ambiguous profile name, so two profiles sharing a name can
  never be confused. Configuration paths are read from
  `openvpn3 configs-list --json`, whose keys are the object paths, so the exact
  ID is always available regardless of the CLI's table layout.
- Sanitize and length-cap every field parsed from the CLI (profile names,
  status lines, object paths, error text) and render them as `PlainText`,
  preventing terminal-escape or rich-text injection from the subprocess output.
- Bound retained command output and cap the number of parsed records so a
  runaway or hostile process cannot exhaust memory.

### Fixed

- Run every `openvpn3` invocation under `timeout`, which terminates the command
  and its child process group as a unit, so a hung tunnel process no longer
  lingers after a watchdog fires.
- Chain the sessions read only after a successful configs read and apply parsed
  output only on a clean exit, so an aborted or failed read never resurrects the
  read chain or overwrites good state with garbage.

### Changed

- Render the profile name in the panel slightly smaller than the default font
  so long names take less horizontal room.

## [0.1.1] - 2026-09-01

### Fixed

- Parse the compact `openvpn3 configs-list` table layout used by current
  openvpn3 versions. Previously only the older path-based layout was
  recognized, so profiles were listed as "No configs" and no toggle switch was
  shown even while a session was connected. Both layouts are now supported.

### Documentation

- Document how to update the plugin, both with `omarchy plugin update` and by a
  manual `git pull` in the install directory.

## [0.1.0] - 2026-09-01

### Added

- Omarchy `bar-widget` plugin (`xavecorp.openvpn3`) to manage OpenVPN
  connections from the bar, backed by the `openvpn3` CLI.
- Bar icon reflecting the VPN state (off, connecting, connected, error) with a
  connecting pulse, colorized from a bundled SVG.
- Panel listing every installed profile from `openvpn3 configs-list`, each row
  showing its state derived from `openvpn3 sessions-list`.
- Per-profile toggle switch: connecting runs `openvpn3 session-start --config
  <name>`, disconnecting runs `openvpn3 session-manage --config <name>
  --disconnect`. Optimistic state so the switch reacts before the next poll.
- Right-click on the bar icon to toggle the obvious target (active session,
  else last connected, else the only profile) without opening the panel.
- Keyboard navigation in the panel: `j`/`k` to move, `space`/`enter` to toggle,
  `d` to disconnect the active session, `r` to refresh, `esc` to close.
- Configurable refresh interval (default 5 seconds, range 2–60).
- Pure parsing helpers in `Model.js` covered by Node unit tests
  (`node --test`).

[Unreleased]: https://github.com/xavecorp/omartchy-openvpn3/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/xavecorp/omartchy-openvpn3/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/xavecorp/omartchy-openvpn3/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/xavecorp/omartchy-openvpn3/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/xavecorp/omartchy-openvpn3/releases/tag/v0.1.0
