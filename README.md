# Omarchy OpenVPN3

Manage OpenVPN connections from the Omarchy bar, backed by the
[`openvpn3`](https://openvpn.net/community-docs/openvpn-client-for-linux.html)
command-line client.

The widget lists your installed configuration profiles, shows which sessions
are running, and lets you start or stop a session with a single toggle. Every
action is a plain `openvpn3` CLI call — there is no helper daemon, no D-Bus
binding to install, and nothing runs as root.

![The OpenVPN3 panel: a header with the plugin icon and title, a coloured
connection-status subtitle, a separator, and a list of profiles — each a card
with a state dot, name, state label and toggle.](preview.png)

## Requirements

- `openvpn3` — the OpenVPN 3 Linux client, on your `PATH`
- Omarchy (Quattro shell)

Everything runs as your own user. The plugin never asks for `sudo` and never
stores or prompts for a credential.

## Install

```sh
omarchy plugin add https://github.com/xavecorp/omarchy-openvpn3.git --enable
omarchy restart shell
```

The restart is required: the bar builds its widgets when the shell starts, so a
widget added afterwards stays invisible until the shell restarts.

To choose where the icon sits (it defaults to the right section):

```sh
omarchy bar move xavecorp.openvpn3 --section right
```

## Usage

Import your profiles into `openvpn3` once:

```sh
openvpn3 config-import --config /path/to/profile.ovpn
```

Then click the bar icon to open the panel:

- The panel lists every profile returned by `openvpn3 configs-list`.
- Each row shows its state (`Off`, `Connecting…`, `Connected`) derived from
  `openvpn3 sessions-list`.
- **Toggle a row's switch** to connect or disconnect that profile. Connecting
  runs `openvpn3 session-start --config <name>`; disconnecting runs
  `openvpn3 session-manage --config <name> --disconnect`.
- **Right-click the bar icon** to toggle the obvious target without opening the
  panel: the active session, else the last one you connected, else the only
  profile you have.

### Keyboard (panel focused)

| Key         | Action                          |
| ----------- | ------------------------------- |
| `j` / `k`   | Move the cursor down / up       |
| `space` / `enter` | Toggle the selected profile |
| `d`         | Disconnect the active session   |
| `r`         | Refresh now                     |
| `esc`       | Close the panel                 |

## How it maps to `openvpn3`

| Widget action              | Command                                                     |
| -------------------------- | ---------------------------------------------------------- |
| List installed profiles    | `openvpn3 configs-list`                                     |
| Detect running sessions    | `openvpn3 sessions-list`                                    |
| Start a session (toggle on)| `openvpn3 session-start --config <name>`                   |
| Stop a session (toggle off)| `openvpn3 session-manage --config <name> --disconnect`     |

The reads run on a poll (default every 5 seconds, configurable 2–60s). Writes
are dispatched immediately on toggle, with an optimistic state so the switch
reacts without waiting for the next poll.

## Configuration

- **Refresh interval** (default 5 seconds, range 2–60) — how often the widget
  re-reads configs and sessions.

## Update

The plugin is git-managed, so Omarchy can pull the latest revision for you:

```sh
omarchy plugin update xavecorp.openvpn3
omarchy restart shell
```

To update every git-managed plugin at once, run `omarchy plugin update` with no
id. The shell restart is required for the reloaded widget to be rebuilt in the
bar.

If you cloned the plugin somewhere and want to update it by hand, pull the
repository in place and restart the shell:

```sh
cd ~/.config/omarchy/plugins/xavecorp.openvpn3   # your install path
git pull --ff-only
omarchy restart shell
```

## Removal

Disconnect any active session first — removing the plugin does not close a
tunnel, because the session belongs to `openvpn3`, not to the widget:

```sh
openvpn3 session-manage --config <name> --disconnect
omarchy plugin remove xavecorp.openvpn3
omarchy restart shell
```

## Development

The parsing logic lives in `Model.js` as pure functions with no Qt
dependencies, so it can be unit-tested with Node:

```sh
node --test
```

## License

MIT — see [LICENSE](LICENSE).
