# Optional helper scripts

These are **not required** for the core plugin. Traffic accounting, SMS, the
settings pages, desktop notifications and cell/GPS location all work with just
`nmcli`, `mmcli` and `notify-send`.

The helpers unlock the optional features. `Store.qml` looks for them in
`~/.local/bin/` (override with the `SIMNETWORK_HELPER_DIR` environment
variable). Anything missing is skipped automatically — no errors, the feature
simply stays off.

Install all of them:

```sh
install -Dm755 extras/* ~/.local/bin/
```

| Script | Feature | Notes |
| --- | --- | --- |
| `eg25-mms-send` | MMS with attachments | Sends via the modem's native AT commands because the carrier WAP gateway rejects `mmsd` submissions (HTTP 502). Handles the ctwap PDP context, `AT+QMMSEND`, file transfer and cleanup on failure. |
| `eg25-mm-heal` | Self-healing data link | Brings ModemManager back if an MMS send was interrupted (including `state: failed` and leftover PDP contexts). Called by the plugin's watchdog; `eg25-unstick` is the low-level unstick routine it falls back to. |
| `eg25-unstick` | — | USB/ModemManager reset routine used by `eg25-mm-heal`. |
| `mms-export` | MMS in the message list | Parses the raw MMS PDUs that `mmsd-tng` drops in `~/.mms/modemmanager/` and extracts attachments, so received MMS show up in the plugin. |
| `eg25-sms-obsidian` | Obsidian archive | Copies SMS/MMS into an Obsidian vault. `--vault` defaults to `~/Documents`; the plugin passes its own setting. |
| `dns-probe` | Troubleshooting | Quick DNS reachability probe over the cellular link. |

## Sudoers

`eg25-mms-send` stops and starts ModemManager around the AT transfer, and does it
without a password prompt. The narrow rule — put it in `/etc/sudoers.d/modemmanager-mms`
and check it with `visudo -cf /etc/sudoers.d/modemmanager-mms`:

```
youruser ALL=(root) NOPASSWD: /usr/bin/systemctl start ModemManager, /usr/bin/systemctl stop ModemManager
```

Replace `youruser` with your login. **Do not** grant `/usr/bin/systemctl`
itself: that is effectively passwordless root.

## Flag file

The scripts record "we stopped ModemManager" in
`$XDG_RUNTIME_DIR/eg25-mm-stopped` (per-user, mode-protected directory), never
in `/tmp`, so another local user cannot plant the flag and make the watchdog
reset your modem.

## Carrier assumptions

`eg25-mms-send` and `mms-export` encode the China Telecom APN layout
(`ctnet` for data, `ctwap` for MMS) and expect an MMS center reachable on
that APN. On another carrier you will need to adjust the APN/MMS center
values — they are grouped in constants at the top of each script.
