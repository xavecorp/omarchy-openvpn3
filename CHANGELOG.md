# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-09-05

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
