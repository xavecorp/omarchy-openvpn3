# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/xavecorp/omartchy-openvpn3/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/xavecorp/omartchy-openvpn3/releases/tag/v0.1.0
