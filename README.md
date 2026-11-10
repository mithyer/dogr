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
2. runs `collie start`, which starts Collie in the background and publishes it on your tailnet (`tailscale serve`);
3. checks that Collie answers on this computer and on its Tailscale address;
4. runs `collie pair` last, so the one-time code still has all of its ten minutes left, and shows it as a QR code.

On your phone: open Herdogr, tap `+`, tap **Scan QR code**, and point the camera at the code. The scan only fills in the form;
you still tap **Pair and add** yourself.

It is safe to run again. A step that is already done is skipped, and Collie is never installed twice. Run it again whenever you
want a fresh pairing code.

**Read the script before you pipe it into a shell.** Collie is a remote terminal for your computer, so what runs on it deserves
that. The script is one file, about 260 lines: [setup.sh](setup.sh).

## Routes

| Route | Status |
| --- | --- |
| Tailscale (HTTPS on your tailnet, nothing exposed to the internet) | Scripted. This is what `setup.sh` does. |
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
| `--yes`, `-y` | Do not ask before changing anything. Needed when there is no terminal. |
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
| 3 | Collie runs, but something it needs is missing (for example Tailscale not signed in, or HTTPS not enabled). | Do what the `fix:` lines say, then run the command again. |
| 4 | Collie did not start, or does not answer. | `collie logs`. |
| 5 | Collie could not be downloaded or installed. | Read the installer's output above the message. |
| 6 | You answered no at the question. | Nothing was changed. |

## What changes on your computer

Only what Collie's own commands change:

| What | Where |
| --- | --- |
| Collie's program files | `~/.local/share/collie` (or `$COLLIE_DIR`), and a `collie` link in `~/.local/bin` |
| Collie's settings and state | `~/.config/collie`, `~/.local/state/collie` |
| A background service that runs Collie | a launchd agent on macOS, a `systemd --user` unit on Linux |
| A Tailscale front door | `tailscale serve`: HTTPS on port 443 of your tailnet name, forwarded to `127.0.0.1:8787` |
| A one-time pairing code, and later the paired devices | `~/.local/state/collie` (or `$COLLIE_STATE_DIR`); only hashes are kept |

The script writes nothing of its own except a temporary folder, which it removes when it ends. Nothing needs `sudo`.

## Undo

These are Collie's own steps, in this order. Each removes one layer.

```sh
collie uninstall          # stops the service, removes the launchd/systemd entry and Collie's tailscale serve mapping
collie unlink             # removes the ~/.local/bin/collie link
rm -rf ~/.local/share/collie   # removes the program files (or $COLLIE_DIR)
```

To forget a paired phone without removing Collie, run `collie devices list`, then `collie devices revoke <label>`. To stop Collie for now and keep everything, run
`collie stop`.

## Tests

```sh
sh tests/run.sh
```

The tests run `setup.sh` against a stub `curl` and a stub `collie`, each case in its own empty home folder. They cover the
normal path, running twice, `--dry-run`, installing first, a failed download or installer, Collie naming a missing setup step,
no Tailscale address, Collie not answering, the Tailscale address not answering from this computer, a failed start, a QR
code that could not be drawn, answering at the terminal, no terminal, wrong options, running through a pipe, and a download
that stops half way. `shellcheck` runs too when it is installed.

## What has and has not been checked

| Checked | How |
| --- | --- |
| The logic of every step and every exit code | `tests/run.sh`, with stubs |
| The shape of Collie's `start`, `status --json` and `pair` output the script reads | Read from Collie's source |
| A real `collie start` with a real Tailscale | Not yet |
| Windows | Not supported. Use Collie's own Windows guide. |

## Limits

- macOS and Linux only.
- The script cannot sign you in to Tailscale, enable HTTPS in the Tailscale admin console, or install Tailscale for you. It
  tells you which of these is missing, because Collie says so, and you run it again.
- Some computers cannot reach their own Tailscale name even though other devices can. The script then prints a warning and still
  shows the pairing code.
- The pairing code lasts ten minutes and works once.
