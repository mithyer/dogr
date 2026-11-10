# dogr

One command that puts [Collie](https://github.com/AltanS/collie) on your computer and pairs your phone with it, for the
[Herdogr](https://github.com/mithyer/herdogr) iOS app.

It does not replace Collie and it does not edit your files. It calls Collie's own commands, checks that each step worked, and
stops with a clear message when something on your side (Tailscale, mostly) still needs doing.

## Run it

```sh
curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh
```

The script first says what it is about to do and asks once. Then it:

1. installs Collie with Collie's own installer, only if Collie is not installed yet;
2. makes sure the terminal program Collie drives is there and running: **herdr** (the terminal app) or **herdr-core** (a
   background service). One that is missing is installed with its own installer; herdr-core is started with `hc server
   start`; herdr has to be opened by you, and the script says how when it is not;
3. runs `collie start`, which starts Collie in the background and publishes it on your tailnet (`tailscale serve`);
4. checks that Collie answers on this computer and on its Tailscale address, and that it drives the program you picked;
5. runs `collie pair` last, so the one-time code still has all of its ten minutes left, and shows it as a QR code.

Which terminal program? `--mux herdr` or `--mux herdr-core` decides. Without it the script uses the one that is installed, and
asks when both or neither are. The Herdogr app shows the same choice next to the command, so you can copy the right one.

On your phone: open Herdogr, tap `+`, tap **Scan QR code**, and point the camera at the code. The scan only fills in the form;
you still tap **Pair and add** yourself.

It is safe to run again. A step that is already done is skipped, and Collie is never installed twice. Run it again whenever you
want a fresh pairing code.

**Read the script before you pipe it into a shell.** Collie is a remote terminal for your computer, so what runs on it deserves
that. The script is one file, about 550 lines: [setup.sh](setup.sh).

## Routes

| Route | Status |
| --- | --- |
| Tailscale (HTTPS on your tailnet, nothing exposed to the internet) | Scripted. This is what `setup.sh` does. |
| Tailscale or Headscale without HTTPS certificates (address starts with `http://`) | Scripted, only when you agree or pass `--http`. Traffic is still encrypted by Tailscale between your devices; the address is just not HTTPS. |
| Your own domain behind a reverse proxy | Not scripted yet. See Collie's `docs/deployment.md`. |
| Local network without encryption | Not scripted yet, and not recommended. |

The first question is "Do you reach this computer from your phone through Tailscale?". Answer no and the script says the route is
not scripted yet, changes nothing, and exits with code 2.

## Options

Options go after `-s --` when the script comes through a pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh -s -- --tailscale --yes
```

| Option | Meaning |
| --- | --- |
| `--tailscale` | Answer the first question for you. |
| `--mux herdr` or `--mux herdr-core` | The terminal program Collie drives. Without it: the one that is installed, else a question. A program that is missing is installed after you agree to the plan. |
| `--yes`, `-y` | Do not ask before changing anything. Needed when there is no terminal. Does not agree to `http://` addresses; use `--http` for that. |
| `--http` | If your tailnet has no HTTPS certificates, switch Collie to `http://` addresses (`COLLIE_SERVE_MODE=http`) without asking. |
| `--dry-run` | Say what would happen, change nothing, stop. |
| `--help`, `-h` | Show the usage text. |

| Environment variable | Meaning |
| --- | --- |
| `DOGR_COLLIE_TAG` | Install this Collie release (for example `v1.27.0`) instead of the newest. |
| `DOGR_COLLIE_INSTALL_URL` | Where Collie's installer comes from. Default `https://colliepwa.dev/install.sh`. |
| `DOGR_TTY` | Where answers are read from. Default `/dev/tty`. Tests point it at a file. |
| `DOGR_TRIES`, `DOGR_POLL_DELAY` | How often, and how many seconds apart, to check that Collie answers. Default 20 and 1. |

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Done (or a dry run, or `--help`). | Scan the code. |
| 1 | Wrong use, unsupported computer, or no terminal to ask on. | Read the message; add `--yes` when there is no terminal. |
| 2 | The route you chose is not scripted yet. | Set it up by hand with Collie's guide. |
| 3 | Something needs you first: herdr is installed but not running, Collie reports a missing piece (for example Tailscale not signed in, or HTTPS not enabled and `http://` not agreed to), a setting of yours could not be used, or Collie drives another terminal program than the one you picked. | Do what the message says, then run the command again. |
| 4 | Collie did not start or does not answer, or herdr-core could not be started. | `collie logs`. |
| 5 | Collie, herdr or herdr-core could not be downloaded or installed. | Read the installer's output above the message. |
| 6 | You answered no at the question. | Nothing was changed. |

## What changes on your computer

Only what Collie's own commands change:

| What | Where |
| --- | --- |
| Collie's program files | `~/.local/share/collie` (or `$COLLIE_DIR`), and a `collie` link in `~/.local/bin` |
| herdr or herdr-core, only when missing | Each installer's own place: `~/.local/bin` (no `sudo`). herdr-core also keeps its program under `~/.local/share/herdr-core`. |
| A running herdr-core | `hc server start` starts the core in the background. It stays running until you stop it (`hc server stop`). |
| One line, only when Collie's `.env` names the other terminal program | `COLLIE_MUX=` in `~/.config/collie/.env` is replaced where it stands, and Collie is restarted. The plan names the change before you agree. |
| Collie's settings and state | `~/.config/collie`, `~/.local/state/collie` |
| A background service that runs Collie | a launchd agent on macOS, a `systemd --user` unit on Linux |
| A Tailscale front door | `tailscale serve`: HTTPS on port 443 of your tailnet name, forwarded to `127.0.0.1:8787` (with `--http`: plain HTTP on port 8787 of your tailnet name) |
| One line, only when the tailnet has no HTTPS certificates and you agreed | `COLLIE_SERVE_MODE=http` appended to `~/.config/collie/.env` (file mode 600). If the file already sets `COLLIE_SERVE_MODE`, the script stops and leaves it alone. |
| A one-time pairing code, and later the paired devices | `~/.local/state/collie` (or `$COLLIE_STATE_DIR`); only hashes are kept |

Apart from the `.env` lines above, the script writes nothing of its own except a temporary folder, which it removes when it ends. Nothing needs `sudo`.

## Undo

These are Collie's own steps, in this order. Each removes one layer.

```sh
collie uninstall          # stops the service, removes the launchd/systemd entry and Collie's tailscale serve mapping
collie unlink             # removes the ~/.local/bin/collie link
rm -rf ~/.local/share/collie   # removes the program files (or $COLLIE_DIR)
```

If you chose `http://`, also delete the `COLLIE_SERVE_MODE=http` line (and the comment above it) from `~/.config/collie/.env`, then run `collie restart`.

To forget a paired phone without removing Collie, run `collie devices list`, then `collie devices revoke <label>`. To stop Collie for now and keep everything, run
`collie stop`.

## Tests

```sh
sh tests/run.sh
```

The tests run `setup.sh` against a stub `curl`, `collie`, `hc` and `herdr`, each case in its own empty home folder. They cover the
normal path, running twice, `--dry-run`, installing first, a failed download or installer, Collie naming a missing setup step,
no Tailscale address, Collie not answering, the Tailscale address not answering from this computer, a failed start, a QR
code that could not be drawn, a tailnet without HTTPS certificates (agreed, declined, `--http`, an existing `.env`, a setting
Collie does not pick up), the terminal program (found, named, asked for, installed, not running, a failing installer or start, an
`.env` that names the other one, Collie driving the wrong one), answering at the terminal, no terminal, wrong options, running through a pipe, and a download
that stops half way. `shellcheck` runs too when it is installed.

## What has and has not been checked

| Checked | How |
| --- | --- |
| The logic of every step and every exit code | `tests/run.sh`, with stubs |
| The shape of Collie's `start`, `status --json` and `pair` output the script reads | Read from Collie's source |
| That `COLLIE_SERVE_MODE=http` in `~/.config/collie/.env` turns the address from `https://name` into `http://name:8787` | Real `collie status --json` in an empty home folder |
| The script runs on macOS 15 (Intel) over ssh: `--help`, `--dry-run`, no terminal, unknown option, "no" at the route question, "no" at the confirmation. Each exits with the documented code and changes nothing | Run once on a spare Mac, 2026-11-10 |
| That `COLLIE_MUX` in the `.env` wins over the environment, and an empty `.env` follows the environment | Real `collie status --json` in an empty home folder |
| `hc server start` is safe to repeat, and `herdr` has no way to start without a terminal | Real `hc` in an isolated session; `herdr --help` and its README |
| The real installers of herdr and herdr-core, and a real `herdr status server` text when it is not running | Not yet (the tests use stubs; the "not running" wording was read from a real Herdr) |
| A real `collie start` with a real Tailscale, with or without HTTPS certificates | Not yet |
| Windows | Not supported. Use Collie's own Windows guide. |

## Limits

- macOS and Linux only.
- The script cannot sign you in to Tailscale, enable HTTPS in the Tailscale admin console, or install Tailscale for you. It
  tells you which of these is missing, because Collie says so, and you run it again.
- Some computers cannot reach their own Tailscale name even though other devices can. The script then prints a warning and still
  shows the pairing code.
- The pairing code lasts ten minutes and works once.
