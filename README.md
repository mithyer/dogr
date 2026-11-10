# dogr

One command that puts [Collie](https://github.com/AltanS/collie) on your computer and pairs your phone with it, for the
[Herdogr](https://github.com/mithyer/herdogr) iOS app.

It does not replace Collie and it does not edit your files. It calls Collie's own commands, checks that each step worked, and
stops with a clear message when something on your side (Tailscale, mostly) still needs doing.

## Run it

```sh
curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh
```

The script first asks how your phone reaches this computer (see [Routes](#routes)), then says what it is about to do and asks
once. Then it:

1. installs Collie with Collie's own installer, only if Collie is not installed yet;
2. makes sure the terminal program Collie drives is there and running: **herdr** (the terminal app) or **herdr-core** (a
   background service). One that is missing is installed with its own installer; herdr-core is started with `hc server
   start`; herdr has to be opened by you, and the script says how when it is not;
3. runs `collie start`, which starts Collie in the background. Over Tailscale it also publishes Collie on your tailnet
   (`tailscale serve`); with `--proxy` or `--lan` Collie publishes nothing itself;
4. checks that Collie answers where your phone will look for it (its Tailscale address, your proxy's address, or this
   computer's local-network address), and that it drives the program you picked;
5. runs `collie pair` last, so the one-time code still has all of its ten minutes left, and shows it as a QR code.

Which terminal program? `--mux herdr` or `--mux herdr-core` decides. Without it the script asks, and marks the one that is
already installed; with no terminal to ask on it stops and tells you to add `--mux`. The Herdogr app shows the same choice next
to the command, so the command you copy already has it.

On your phone: open Herdogr, tap `+`, tap **Scan QR code**, and point the camera at the code. The scan only fills in the form;
you still tap **Pair and add** yourself.

It is safe to run again. A step that is already done is skipped, and Collie is never installed twice. Run it again whenever you
want a fresh pairing code.

**Read the script before you pipe it into a shell.** Collie is a remote terminal for your computer, so what runs on it deserves
that. The script is one file, about 900 lines, most of them comments and checks: [setup.sh](setup.sh).

## Routes

| Route | Option | What the script does | What is yours to do |
| --- | --- | --- | --- |
| Tailscale (HTTPS on your tailnet, nothing exposed to the internet) | `--tailscale` | Collie publishes itself with `tailscale serve`; the address is your Tailscale name, which Collie finds. | Sign in to Tailscale, turn on HTTPS in its admin console. |
| Tailscale or Headscale without HTTPS certificates (address starts with `http://`) | `--tailscale --http` | The same, with `COLLIE_SERVE_MODE=http`. Only when you agree or pass `--http`. Tailscale still encrypts the traffic between your devices; the address is just not HTTPS. | Nothing more. |
| Your own domain behind a reverse proxy | `--proxy --url https://collie.example.com` | Collie answers on `127.0.0.1` only and is told its public address (`COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS`, `COLLIE_PUBLIC_URL`). Checks that the address answers, prints a Caddy example, and makes the pairing code only when it does. | The proxy itself, its certificate, and who may reach it. |
| Local network, plain http, no encryption | `--lan` (and `--host 192.168.1.20` to name the address) | Finds this computer's local-network address (asks when there are several), makes Collie answer on that address only (`COLLIE_HOST`, `COLLIE_ALLOW_NON_LOOPBACK_BIND` and the four settings above) and checks it. | Keep it to a network you trust. |

Without a route option the first question is "Do you reach this computer from your phone through Tailscale?". Answer no and it asks
whether it is your own domain behind a reverse proxy, or the local network. Another route than the one you ran before is fine:
the lines the script added are replaced where they stand. Only the Tailscale route refuses to run over a leftover of the other
two (`COLLIE_SKIP_SERVE=1` or a `COLLIE_HOST` that is not loopback), because Collie would silently not publish itself; it names the
lines to delete.

### What the local-network route opens up

Collie then answers to everything on your local network, over plain http. From Collie's source, every API request other than the
health check and the pairing needs the key that pairing hands out, and pairing needs the one-time code (ten minutes, five tries).
That is a lock, not encryption: do not use this route on a shared or public network. A real Collie, bound the same way in an empty
home folder, answered `device not paired` to unpaired requests on the routes tried and paired with the Herdogr app on a simulator.

## Options

Options go after `-s --` when the script comes through a pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh -s -- --tailscale --yes
```

| Option | Meaning |
| --- | --- |
| `--tailscale` | The phone reaches this computer through Tailscale. Answers the first question for you. |
| `--proxy` | The phone reaches it through your own domain and a reverse proxy. |
| `--url https://collie.example.com` | The public address of that proxy: `https://`, a host name, an optional port, no path. Implies `--proxy`. Without it the script asks. Port 443 is dropped, any other port is kept (Collie compares the Host header with the port). |
| `--lan` | The phone reaches it over the local network, plain http. |
| `--host 192.168.1.20` | This computer's address on the local network. Implies `--lan`. Without it the script looks for one (private ranges only, not Tailscale, Docker or virtual machines) and asks when there are several; with no terminal to ask on it stops and lists them. |
| `--mux herdr` or `--mux herdr-core` | The terminal program Collie drives. Without it the script asks (and stops when there is no terminal to ask on). A program that is missing is installed after you agree to the plan. |
| `--yes`, `-y` | Do not ask before changing anything. Needed when there is no terminal. Does not agree to `http://` addresses; use `--http` for that. |
| `--http` | If your tailnet has no HTTPS certificates, switch Collie to `http://` addresses (`COLLIE_SERVE_MODE=http`) without asking. |
| `--dry-run` | Say what would happen, change nothing, stop. |
| `--help`, `-h` | Show the usage text. |

| Environment variable | Meaning |
| --- | --- |
| `DOGR_COLLIE_TAG` | Install this Collie release (for example `v1.27.0`) instead of the newest. |
| `DOGR_COLLIE_INSTALL_URL` | Where Collie's installer comes from. Default `https://colliepwa.dev/install.sh`. |
| `DOGR_HERDR_INSTALL_URL`, `DOGR_HERDR_CORE_INSTALL_URL` | Where the installers of herdr and herdr-core come from. Defaults `https://herdr.dev/install.sh` and `https://releases.herdr.dev/core/install.sh`. |
| `DOGR_TTY` | Where answers are read from. Default `/dev/tty`. Tests point it at a file. |
| `DOGR_TRIES`, `DOGR_POLL_DELAY` | How often, and how many seconds apart, to check that Collie answers. Default 20 and 1. |

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Done (or a dry run, or `--help`). | Scan the code. |
| 1 | Wrong use (two routes at once, a bad `--url` or `--host`), unsupported computer, or no terminal to ask on. | Read the message; add `--yes` (and the route and `--mux`) when there is no terminal. |
| 2 | Not used. It once meant "route not scripted"; the number stays free so the others keep their meaning. | |
| 3 | Something needs you first: herdr is installed but not running, Collie reports a missing piece (for example Tailscale not signed in, or HTTPS not enabled and `http://` not agreed to), no local-network address was found, a proxy address that does not answer yet, settings of another route left in the `.env`, a setting of yours could not be used, or Collie drives another terminal program or gives another address than the one asked for. | Do what the message says, then run the command again. For the proxy: set it up, then `collie pair`. |
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
| For `--proxy` and `--lan`: the settings of that route | `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS`, `COLLIE_PUBLIC_URL`, and for `--lan` also `COLLIE_HOST` and `COLLIE_ALLOW_NON_LOOPBACK_BIND=1`, in `~/.config/collie/.env`. A line that is there is replaced where it stands, a missing one is added under a comment (`# Added by dogr setup.sh`). Behind a proxy, a `COLLIE_HOST` left by an earlier `--lan` run goes back to `127.0.0.1`. The plan lists each `add` and `change` before you agree, and Collie is restarted when it was installed before. |
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
For `--proxy` or `--lan`, delete the lines the plan listed (they sit under a `# Added by dogr setup.sh` comment): `COLLIE_SKIP_SERVE`,
`COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS`, `COLLIE_PUBLIC_URL`, and for `--lan` `COLLIE_HOST` and `COLLIE_ALLOW_NON_LOOPBACK_BIND`.
Then run `collie restart` (or `collie uninstall` as above).

To forget a paired phone without removing Collie, run `collie devices list`, then `collie devices revoke <label>`. To stop Collie for now and keep everything, run
`collie stop`.

## Tests

```sh
sh tests/run.sh
```

The tests run `setup.sh` against a stub `curl`, `collie`, `hc`, `herdr`, `ifconfig` and `ip`, each case in its own empty home folder. They cover the
normal path, running twice, `--dry-run`, installing first, a failed download or installer, Collie naming a missing setup step,
no Tailscale address, Collie not answering, the Tailscale address not answering from this computer, a failed start, a QR
code that could not be drawn, a tailnet without HTTPS certificates (agreed, declined, `--http`, an existing `.env`, a setting
Collie does not pick up), the terminal program (named, asked for, installed, not running, a failing installer or start, an
`.env` that names the other one, Collie driving the wrong one), the reverse proxy route (addresses that are accepted and refused, the port, asked for or
given, settings added, replaced or already there, a wide bind from an earlier run, the proxy not answering, Collie not reading the settings), the local-network route
(which addresses are offered, one or several, `--host` and its checks, Linux's `ip`, another port, no address, the risk being named before the question),
the Tailscale route refusing leftovers, answering at the terminal, no terminal, wrong options, running through a pipe, and a download that stops half way. `shellcheck` runs too when it is installed.

## What has and has not been checked

| Checked | How |
| --- | --- |
| The logic of every step and every exit code | `tests/run.sh`, with stubs |
| The shape of Collie's `start`, `status --json` and `pair` output the script reads | Read from Collie's source |
| That `COLLIE_SERVE_MODE=http` in `~/.config/collie/.env` turns the address from `https://name` into `http://name:8787` | Real `collie status --json` in an empty home folder |
| The script runs on macOS 15 (Intel) over ssh: `--help`, `--dry-run`, no terminal, unknown option, "no" at the route question, "no" at the confirmation. Each exits with the documented code and changes nothing | Run once on a spare Mac, 2026-11-10 |
| That the proxy and local-network settings make Collie report the address the phone should use (and, for `--lan`, the bind address as its local address) | Real `collie status --json` in an empty home folder, with the lines written to `~/.config/collie/.env` as the script writes them (also `COLLIE_PORT`, which moves every address to that port) |
| That Collie bound to a local-network address only (the settings above) answers on that address, not on loopback, reports it as both its local and phone address, accepts `POST /api/pair` with an `Origin` (and refuses without), and pairs with the Herdogr app | A real Collie bridge in an empty home folder, then the app in the iPhone simulator against `http://<this Mac's address>:<port>` |
| That every API request except the health check and the pairing is refused with `device not paired` | A real bridge, eight routes tried without a token |
| `--lan --host ... --dry-run` on a Mac with several addresses (it lists them, and stops when there is no terminal to ask on) | Run on the author's Mac, changing nothing |
| That `COLLIE_MUX` in the `.env` wins over the environment, and an empty `.env` follows the environment | Real `collie status --json` in an empty home folder |
| `hc server start` is safe to repeat, and `herdr` has no way to start without a terminal | Real `hc` in an isolated session; `herdr --help` and its README |
| The real installers of herdr and herdr-core, and a real `herdr status server` text when it is not running | Not yet (the tests use stubs; the "not running" wording was read from a real Herdr) |
| A real `collie start` with a real Tailscale, with or without HTTPS certificates | Not yet |
| A real `collie start` for `--proxy` or `--lan` (the service reading the `.env` lines), a real Caddy in front, a phone behind it | Not yet. The service reading the `.env` is only inferred from the `status` check above. |
| Collie after the computer's local-network address changes | Not checked; the script says to run it again |
| Windows | Not supported. Use Collie's own Windows guide. |

## Limits

- macOS and Linux only.
- The script cannot sign you in to Tailscale, enable HTTPS in the Tailscale admin console, or install Tailscale for you. It
  tells you which of these is missing, because Collie says so, and you run it again.
- Some computers cannot reach their own Tailscale name even though other devices can. The script then prints a warning and still
  shows the pairing code. (With `--proxy` it stops instead and says to run `collie pair` once the proxy is up.)
- `--proxy` does not set up the proxy, its certificate, or who may reach it. It prints a Caddy example and the guide to read.
- `--lan` ties Collie to one address. If the computer gets another one (a new network, a DHCP lease that changed), Collie cannot
  start until you run the script again. A fixed address for the computer avoids that.
- The pairing code lasts ten minutes and works once.
