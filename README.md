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
   (`tailscale serve`); with `--tailcat`, `--iroh`, `--proxy` or `--lan` Collie publishes nothing itself (for tailcat the script
   first installs tailcat, makes a saved key and runs `tailcat serve` as a background service of your own user, see
   [the tailcat route](#the-tailcat-route); for iroh it installs dumbpipe, makes two saved secrets and runs `dumbpipe listen-tcp`
   the same way, see [the iroh route](#the-iroh-route));
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
that. The script is one file, about 1,600 lines, most of them comments and checks: [setup.sh](setup.sh).

## Routes

| Route | Option | What the script does | What is yours to do |
| --- | --- | --- | --- |
| Tailscale (HTTPS on your tailnet, nothing exposed to the internet) | `--tailscale` | Collie publishes itself with `tailscale serve`; the address is your Tailscale name, which Collie finds. | Sign in to Tailscale, turn on HTTPS in its admin console. |
| Tailscale or Headscale without HTTPS certificates (address starts with `http://`) | `--tailscale --http` | The same, with `COLLIE_SERVE_MODE=http`. Only when you agree or pass `--http`. Tailscale still encrypts the traffic between your devices; the address is just not HTTPS. | Nothing more. |
| tailcat: an end-to-end encrypted tunnel with no account, no server of yours and no open port | `--tailcat` (optionally `--derpmap-url`, `--region`) | Installs tailcat, makes a saved key, runs `tailcat serve` for Collie's port as a background service of your user, and puts the secret tailcat address into the pairing QR code (`COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_PUBLIC_URL`). | On macOS, Homebrew. On Linux, nothing (systemd `--user` is used). |
| iroh: another end-to-end encrypted tunnel with no account, no server of yours and no open port, over n0's public relay servers, or one of yours | `--iroh` (optionally `--relay-url`) | Installs dumbpipe (a pinned release, checked against its SHA-256), makes two saved secrets, runs `dumbpipe listen-tcp` for Collie's port as a background service of your user, and puts the secret iroh address into the pairing QR code (`COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_PUBLIC_URL`). With `--relay-url` it builds dumbpipe with `cargo` so that it uses your relay. | Nothing: the release file is downloaded, so no Homebrew either. With `--relay-url`: Rust's `cargo`. |
| Your own domain behind a reverse proxy | `--proxy --url https://collie.example.com` | Collie answers on `127.0.0.1` only and is told its public address (`COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS`, `COLLIE_PUBLIC_URL`). Checks that the address answers, prints a Caddy example, and makes the pairing code only when it does. | The proxy itself, its certificate, and who may reach it. |
| Local network, plain http, no encryption | `--lan` (and `--host 192.168.1.20` to name the address) | Finds this computer's local-network address (asks when there are several), makes Collie answer on that address only (`COLLIE_HOST`, `COLLIE_ALLOW_NON_LOOPBACK_BIND` and the four settings above) and checks it. | Keep it to a network you trust. |

Without a route option the first question is "Do you reach this computer from your phone through Tailscale?". Answer no and it asks
whether it is tailcat, iroh, your own domain behind a reverse proxy, or the local network (answer with the number or the word). Another route than the one you ran before is fine:
the lines the script added are replaced where they stand. Only the Tailscale route refuses to run over a leftover of the others
(`COLLIE_SKIP_SERVE=1` or a `COLLIE_HOST` that is not loopback), because Collie would silently not publish itself; it names the
lines to delete.

### What the local-network route opens up

Collie then answers to everything on your local network, over plain http. From Collie's source, every API request other than the
health check and the pairing needs the key that pairing hands out, and pairing needs the one-time code (ten minutes, five tries).
That is a lock, not encryption: do not use this route on a shared or public network. A real Collie, bound the same way in an empty
home folder, answered `device not paired` to unpaired requests on the routes tried and paired with the Herdogr app on a simulator.

### The tailcat route

[tailcat](https://github.com/tailscale/tailcat) is "Tailscale without Tailscale": a tunnel between your phone and this computer,
encrypted end to end (WireGuard), that needs no account and no open port. The two ends find each other through a **tailcat address**
(a 154-character word starting with `tc`); relays that tailcat runs help when the two cannot reach each other directly.

What the script sets up:

1. **tailcat itself.** On macOS with Homebrew (`brew install tailcat`; the releases have no Mac file). On Linux the release file for
   your processor (amd64, arm64, armv7) is downloaded from GitHub, checked against the release's `checksums.txt`, and the
   program goes into `~/.local/bin`.
2. **A saved key** named `herdogr` (`tailcat genkey --key=herdogr --fixed-region`). The relay region is baked into the key, so the
   address is the same after every restart. If picking the nearest region fails (it sometimes does), it is tried three times and
   then the script asks you to run it again with `--region NAME` (`tailcat genkey --region=list` shows the names). An existing key
   is kept as it is.
3. **A background service** running `tailcat serve --key=herdogr <Collie's port>`: a launchd agent on macOS
   (`~/Library/LaunchAgents/dev.dogr.tailcat.plist`), a `systemd --user` unit on Linux (`~/.config/systemd/user/dogr-tailcat.service`).
   Its log, `~/.local/state/dogr/tailcat.log`, is where the script reads the address from. It starts again after a restart (on Linux
   servers, `loginctl enable-linger $USER` once keeps it running when nobody is logged in).
4. **Collie's settings** in `~/.config/collie/.env`: `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and
   `COLLIE_PUBLIC_URL=http://tailcat.invalid/<tailcat address>`. That last line is how `collie pair` puts the address into its QR code:
   the link is `http://tailcat.invalid/<address>/settings?pair=<code>`. The host name never resolves; the Herdogr app recognises it and
   opens the tunnel instead (it asks first if you chose another way of connecting).

`--derpmap-url https://relay.example.com/map.json` uses your own relay map instead of tailcat's public one (both for the key and for
the service); the phone needs the same address (a field on the add page). `--region` names the relay region for a new key; it is
not applied to a key that exists already (the script says so; delete the key with `tailcat genkey --delete --key=herdogr` to change it).

**The tailcat address is a secret.** Whoever has it can reach Collie's door through the tunnel. From a real Collie bridge: every
API request other than the health check and the pairing is refused with `device not paired`, and pairing needs the one-time code. That
is a lock, not a wall: treat the address like a password. It is in the QR code, in `~/.config/collie/.env` (a file only you can
read), and in the output of `collie status` and `collie doctor`. The script itself never prints it.

Things to know:

- tailcat says of itself that it is early and experimental, makes no promise about its command line or wire format, and that its
  public relays are rate-limited and may be switched off. If you depend on this, run your own relay (`--derpmap-url`).
- The first request through a new tunnel took 4 to 8 seconds in tests; over a relay on mobile data every request took about 0.6 to 2
  seconds. The Herdogr app slows its polling down by itself when requests are slow.
- The phone's tunnel library is built from a tailcat commit a little newer than the 0.7.0 release the script installs. A 0.7.0 server and
  that client talked to each other in a test; a later tailcat release may not.

### The iroh route

[iroh](https://github.com/n0-computer/iroh) is a library from n0 that connects two devices by a public key and finds a direct path
between them, or goes through n0's relay servers when it cannot. [dumbpipe](https://github.com/n0-computer/dumbpipe) is n0's small
program that hands one TCP port of this computer to such a connection. The Herdogr app links the same library and opens the other
end, so the route needs no account, no server of yours and no open port, and is separate from tailcat: a phone uses one or the other
per computer, and the two can run side by side.

What the script sets up:

1. **dumbpipe 0.40.1.** The release file for your system and processor (macOS or Linux, amd64 or arm64) is downloaded from GitHub and
   checked against the SHA-256 the script carries (the release has no `checksums.txt`; `DOGR_DUMBPIPE_SHA256` replaces the digest when
   you use another release file). The program goes into `~/.local/bin`. One you have installed already is used when it is at least
   this version and understands `--custom-alpn`.
2. **Two saved secrets** in `~/.config/dogr/iroh` (folder mode 700, files 600): `secret`, the key of this computer's iroh endpoint (64
   hex digits), and `alpn`, a random name (32 hex digits) that only the phone is told. The script lets dumbpipe accept connections that
   carry that name only (`--custom-alpn`), so knowing this computer's endpoint id, which is public, is not enough to knock. Both are
   kept between runs, so the address stays the same; a file that is not a key is replaced.
3. **A background service** that runs `~/.config/dogr/iroh/run.sh`, which reads the key from its file and starts `dumbpipe listen-tcp
   --host 127.0.0.1:<Collie's port> --custom-alpn utf8:<name>`: a launchd agent on macOS
   (`~/Library/LaunchAgents/dev.dogr.iroh.plist`), a `systemd --user` unit on Linux (`~/.config/systemd/user/dogr-iroh.service`).
   The service file itself holds no secret. The log, `~/.local/state/dogr/iroh.log`, is where the script reads the ticket (and so the
   endpoint id) the service prints; it is checked against the key's own id, so an old log is never trusted.
4. **Collie's settings** in `~/.config/collie/.env`: `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and
   `COLLIE_PUBLIC_URL=http://iroh.invalid/ir<endpoint id><name>`. That last line is how `collie pair` puts the address into its QR code;
   the host name never resolves, and the Herdogr app recognises it and opens the tunnel instead.

**The iroh address is a secret**, like the tailcat one: the endpoint id plus the name. The script never prints it (the QR code shows it,
and so do `collie status` and `collie doctor`), and the plan shows `<your iroh address>`.

#### Your own relay

A relay is the server both ends fall back on when they cannot find a direct path; it only passes encrypted data on, and **both ends
must use the same one**. By default that is n0's public relays. `--relay-url https://relay.example.com` makes this computer use a relay
of yours instead: the open-source [`iroh-relay`](https://github.com/n0-computer/iroh/tree/main/iroh-relay) that you run yourself, or a
paid relay of n0's with its authentication switched off. A relay that asks for a token made from a project API key is not supported:
this script and the Herdogr app only take an address, never a key.

- dumbpipe 0.40.1 has no relay option, so with `--relay-url` the script builds one with `cargo install --git` from a pinned commit of
  dumbpipe's `ramfox/relay-flag` branch (not released yet) into `~/.config/dogr/iroh/bin`, and the service runs
  `dumbpipe listen-tcp ... --relay '<url>' --custom-alpn ...`. **Rust's `cargo` must be installed** (the script stops with exit code 5
  and says so when it is not); the first build takes a few minutes. Without `--relay-url` nothing changes: the release file is used.
- The address has to be given to the phone as well: the Herdogr app has a relay field next to the command and puts the same address into
  the tunnel it opens on the phone. With a relay of your own the phone does not ask n0's directory for this computer's relay, so the
  relay has to be in the address it dials.
- If this computer cannot reach the relay, the script says so after starting the service; the phone cannot connect either until it can.

Things to know:

- Until the phone and this computer find a direct path, everything goes through n0's **public relay servers**. They are free; n0 says
  they are for development and testing, with no promise of speed or uptime (a relay of your own is possible, see [your own relay](#your-own-relay)). The traffic is encrypted end to end, so a relay sees only that two endpoints talk.
- In a test with both ends on one Mac, the first request through a new connection took about 3 seconds, one that went over a relay
  around 0.5 seconds of delay per round trip (the relay was on the US west coast), and requests on a direct path a few milliseconds.
  That says nothing yet about a phone on mobile data, nor about China.
- The name is on the command line of the service, so another user of the same computer can read it with `ps`. The key is not (it is
  passed through the environment of a script only you can read). Use this route on a computer you share only with people you trust.
- Every connection the phone opens locally becomes one connection to dumbpipe, so a phone that keeps one HTTP connection open uses one.
- The Herdogr app needs iOS 17.5 or newer for the iroh route (the library's own minimum).

## Options

Options go after `-s --` when the script comes through a pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh -s -- --tailscale --yes
```

| Option | Meaning |
| --- | --- |
| `--tailscale` | The phone reaches this computer through Tailscale. Answers the first question for you. |
| `--tailcat` | The phone reaches it through a tailcat tunnel. |
| `--iroh` | The phone reaches it through an iroh tunnel (dumbpipe). |
| `--relay-url URL` | iroh: use a relay server of your own (`https://`, or `http://` on this computer or the local network; a host name, no user name, no query or fragment) instead of n0's public relays. Implies `--iroh`. The phone must be given the same address; the Herdogr app puts it into this command from its own field. Needs Rust's `cargo`, see [your own relay](#your-own-relay). |
| `--derpmap-url https://relay.example.com/map.json` | tailcat: your own relay map (`https://`, a host name, no user name, and only letters, digits and `. _ ~ : / ? = & # + , -`). Used for the key and the service. Implies `--tailcat`. |
| `--region NAME` | tailcat: the relay region for a new key (an ID, code or name from `tailcat genkey --region=list`, or the host name of your own relay). Implies `--tailcat`. |
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
| `DOGR_TAILCAT_VERSION`, `DOGR_TAILCAT_RELEASE_URL` | Linux: which tailcat release to download (default `0.7.0`) and where its files are (default `https://github.com/tailscale/tailcat/releases/download/v<version>`). On macOS Homebrew decides the version. |
| `DOGR_DUMBPIPE_GIT`, `DOGR_DUMBPIPE_REV` | `--iroh --relay-url`: the git repository and the commit that dumbpipe is built from (default `https://github.com/n0-computer/dumbpipe` at `e2181df077ff`). |
| `DOGR_DUMBPIPE_RELEASE_URL`, `DOGR_DUMBPIPE_SHA256` | `--iroh`: where dumbpipe's release files are (default `https://github.com/n0-computer/dumbpipe/releases/download/v0.40.1`) and the SHA-256 the downloaded file must have. Without the second, the digest the script carries for the default release is used; set it when you use another release file. |
| `DOGR_PROGRESS` | `always`, `never` or `auto` (default). While the installers download, a line such as `collie-1.28.1-macos-arm64.tar.gz  12.3 / 47.1 MB  (26%)  0.3 MB/s` is drawn. `auto` draws it on a terminal only, so a log or a pipe stays clean; files under 1 MB (scripts, checksums) are never drawn. Nothing about the download changes: every call still reaches the real `curl` with its own options. |
| `DOGR_TTY` | Where answers are read from. Default `/dev/tty`. Tests point it at a file. |
| `DOGR_TRIES`, `DOGR_POLL_DELAY` | How often, and how many seconds apart, to check that Collie answers. Default 20 and 1. |

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Done (or a dry run, or `--help`). | Scan the code. |
| 1 | Wrong use (two routes at once, a bad `--url`, `--host` or `--derpmap-url`), unsupported computer, or no terminal to ask on. | Read the message; add `--yes` (and the route and `--mux`) when there is no terminal. |
| 2 | Not used. It once meant "route not scripted"; the number stays free so the others keep their meaning. | |
| 3 | Something needs you first: herdr is installed but not running, Collie reports a missing piece (for example Tailscale not signed in, or HTTPS not enabled and `http://` not agreed to), no local-network address was found, a proxy address that does not answer yet, settings of another route left in the `.env`, a setting of yours could not be used, or Collie drives another terminal program or gives another address than the one asked for. | Do what the message says, then run the command again. For the proxy: set it up, then `collie pair`. |
| 4 | Collie did not start or does not answer, herdr-core could not be started, or (tailcat, iroh) the key could not be made, the service could not be started, it printed no address, or (iroh) the running service has another endpoint id than the saved key. | `collie logs`; for tailcat and iroh the message names the command, and `~/.local/state/dogr/tailcat.log` or `iroh.log` has the service's own words. |
| 5 | Collie, herdr, herdr-core, tailcat or dumbpipe could not be downloaded or installed: no Homebrew on a Mac, no tailcat or dumbpipe release for the processor, a checksum that does not match. | Read the installer's output above the message. |
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
| For `--tailcat`: the tailcat program | macOS: Homebrew's own place. Linux: `~/.local/bin/tailcat`. |
| For `--tailcat`: the saved key `herdogr` | macOS `~/Library/Application Support/tailcat/keys/herdogr.private.json`, Linux `~/.config/tailcat/keys/herdogr.private.json` (the key is the secret behind the address) |
| For `--tailcat`: the service and its log | macOS `~/Library/LaunchAgents/dev.dogr.tailcat.plist`, Linux `~/.config/systemd/user/dogr-tailcat.service`; the log is `~/.local/state/dogr/tailcat.log` (folder and file private to you, emptied at each run) |
| For `--tailcat`: the settings of that route | `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and `COLLIE_PUBLIC_URL=http://tailcat.invalid/<tailcat address>` in `~/.config/collie/.env`; a wide `COLLIE_HOST` goes back to `127.0.0.1`. The plan shows the address as `<your tailcat address>`, and so does the script's own output. |
| For `--iroh`: the dumbpipe program | `~/.local/bin/dumbpipe`, unless a new enough one is installed already. With `--relay-url`: a build of your own in `~/.config/dogr/iroh/bin/dumbpipe` |
| For `--iroh`: the two saved secrets and the runner | `~/.config/dogr/iroh/secret` (the key, the secret behind the address), `alpn` (the name, also secret) and `run.sh`, in a folder only you can open |
| For `--iroh`: the service and its log | macOS `~/Library/LaunchAgents/dev.dogr.iroh.plist`, Linux `~/.config/systemd/user/dogr-iroh.service`; the log is `~/.local/state/dogr/iroh.log` (private to you, emptied at each run) |
| For `--iroh`: the settings of that route | `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and `COLLIE_PUBLIC_URL=http://iroh.invalid/<iroh address>` in `~/.config/collie/.env`; a wide `COLLIE_HOST` goes back to `127.0.0.1`. The plan shows the address as `<your iroh address>`, and so does the script's own output. |
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

For `--tailcat`, also stop and remove the tunnel service, then the key (without the key the address is gone for good), then the program:

```sh
# macOS
launchctl bootout gui/$(id -u)/dev.dogr.tailcat && rm ~/Library/LaunchAgents/dev.dogr.tailcat.plist
# Linux
systemctl --user disable --now dogr-tailcat.service && rm ~/.config/systemd/user/dogr-tailcat.service

tailcat genkey --delete --key=herdogr
rm -r ~/.local/state/dogr
brew uninstall tailcat    # macOS;  on Linux: rm ~/.local/bin/tailcat
```

For `--iroh`, stop and remove its service, then the saved secrets (without them the address is gone for good), then the program:

```sh
# macOS
launchctl bootout gui/$(id -u)/dev.dogr.iroh && rm ~/Library/LaunchAgents/dev.dogr.iroh.plist
# Linux
systemctl --user disable --now dogr-iroh.service && rm ~/.config/systemd/user/dogr-iroh.service

rm -r ~/.config/dogr/iroh ~/.local/state/dogr/iroh.log
rm ~/.local/bin/dumbpipe    # only if the script installed it
```

If you chose `http://`, also delete the `COLLIE_SERVE_MODE=http` line (and the comment above it) from `~/.config/collie/.env`, then run `collie restart`.
For `--tailcat`, `--iroh`, `--proxy` or `--lan`, delete the lines the plan listed (they sit under a `# Added by dogr setup.sh` comment): `COLLIE_SKIP_SERVE`,
`COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS` (proxy and local network only), `COLLIE_PUBLIC_URL`, and for `--lan` `COLLIE_HOST` and `COLLIE_ALLOW_NON_LOOPBACK_BIND`.
Then run `collie restart` (or `collie uninstall` as above).

To forget a paired phone without removing Collie, run `collie devices list`, then `collie devices revoke <label>`. To stop Collie for now and keep everything, run
`collie stop`.

## Tests

```sh
sh tests/run.sh
```

The tests run `setup.sh` against a stub `curl`, `collie`, `hc`, `herdr`, `ifconfig`, `ip`, `uname`, `brew`, `tailcat`, `dumbpipe`, `launchctl` and `systemctl`, each case in its own empty home folder. They cover the
normal path, running twice, `--dry-run`, installing first, a failed download or installer, Collie naming a missing setup step,
no Tailscale address, Collie not answering, the Tailscale address not answering from this computer, a failed start, a QR
code that could not be drawn, a tailnet without HTTPS certificates (agreed, declined, `--http`, an existing `.env`, a setting
Collie does not pick up), the terminal program (named, asked for, installed, not running, a failing installer or start, an
`.env` that names the other one, Collie driving the wrong one), the reverse proxy route (addresses that are accepted and refused, the port, asked for or
given, settings added, replaced or already there, a wide bind from an earlier run, the proxy not answering, Collie not reading the settings), the local-network route
(which addresses are offered, one or several, `--host` and its checks, Linux's `ip`, another port, no address, the risk being named before the question),
the tailcat route (macOS with Homebrew and Linux with a downloaded release for three processors, a wrong or unlisted checksum, no Homebrew, a key that exists or fails to be made, a region or relay map, the service not starting or printing no address, an old log that must not be trusted, another port, settings already there or older, Collie not reading them; where the system has `plutil` it also checks that the launchd file is a valid property list),
the iroh route (macOS and Linux for two processors, a processor with no release, a wrong checksum, a failed download, a dumbpipe that is installed, too old or lacks `--custom-alpn`, a relay address that is refused or passed on to the service (and the build of a dumbpipe that has `--relay`, with and without `cargo`), saved secrets that are used again or replaced when malformed, file modes, a ticket that cannot be read, a service that prints no ticket, an old log that must not be trusted, a ticket of another key, a relay that cannot be reached, a service that does not start, another port, settings already there or older, Collie not reading them, and the questions and options that lead to it; the secrets are checked to appear in no output and not in the runner),
the Tailscale route refusing leftovers, answering at the terminal, no terminal, wrong options, running through a pipe, a download that stops half way, and the progress line (drawn when asked, quiet without a terminal or with `DOGR_PROGRESS=never`, the size in megabytes, a server that gives no length, small files, a failing download, both orders of `-o` and the address). `shellcheck` runs too when it is installed.

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
| That the launchd file the script writes is accepted by the real launchd, starts the real `tailcat serve` (Homebrew's 0.7.0) with a saved key, that the service's log carries the address in the form the script reads (154 characters, the same as `tailcat genkey` printed), that launchd starts the service again after it is killed with the same address, and that `bootout` stops it | Run on the author's Mac with a throw-away label, key and port; all removed afterwards |
| That the Linux download steps work on the real release: the file is listed in `checksums.txt`, its sha-256 matches, and `tar -xzf <file> tailcat` yields a statically linked executable (for amd64; arm64 and armv7 are listed too) | The real v0.7.0 files, checked on a Mac (the executable was not run) |
| That a leftover `COLLIE_ALLOWED_ORIGINS` of the proxy route does not stop a phone from pairing over the tunnel | A real Collie bridge: pairing with an `Origin` of the phone's own address returned 200 with and without the setting |
| That a Collie behind `tailcat serve` pairs and answers through the tunnel with `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and a `COLLIE_PUBLIC_URL` carrying the address; that the link `collie pair` prints with it is 200 characters and fits a QR code | Real Collie and real tailcat (a 0.7.0 server with a saved key and a newer client), an iPhone simulator, and two real iPhones (Wi-Fi and mobile data) with a test app |
| The iroh mechanics with the real programs: a real dumbpipe 0.40.1 (`listen-tcp --custom-alpn`) in front of a small web server on one Mac, reached by a Swift program through the Herdogr app's iroh library (iroh-ffi 1.2.0): connect by endpoint id alone, a request over HTTP keep-alive on one stream, a wrong name refused at the handshake with `peer doesn't support any known protocol`, and the endpoint id derived from the key with `openssl` equal to the one in the ticket | Run on the author's Mac in a throw-away folder; both ends were on one Mac, so it says nothing about mobile data or other countries |
| `--relay-url`: a dumbpipe built from the pinned commit (`e2181df077ff`) listens with `--relay http://127.0.0.1:3340` in front of a scripted Collie stand-in; the Herdogr app (iPhone simulator, relay address in its Add form) pairs, shows the machine online and its spaces; with the relay stopped and the app reopened the machine is offline, and online again after the relay and this computer's endpoint came back | Run on the author's Mac with a throw-away `iroh-relay --dev` (http, local only), a scratch folder and no real Collie or service; both ends were on one Mac |
| The real installers of herdr and herdr-core, and a real `herdr status server` text when it is not running | Not yet (the tests use stubs; the "not running" wording was read from a real Herdr) |
| The progress line, drawn by the real `curl` against the real Collie release on GitHub (`2.0 / 47.1 MB  (4%)  0.3 MB/s`, then curl's own timeout message and exit code 28 passed through, no leftover files) | Run on the author's Mac with `DOGR_PROGRESS=always` and an 8-second limit. Not yet seen in a real terminal window with Collie's own installer. |
| A real `collie start` with a real Tailscale, with or without HTTPS certificates | Not yet |
| A real `collie start` for `--proxy` or `--lan` (the service reading the `.env` lines), a real Caddy in front, a phone behind it | Not yet. The service reading the `.env` is only inferred from the `status` check above. |
| The Linux service file under a real `systemd --user`, `loginctl enable-linger`, and `brew install tailcat` run by the script on a Mac that had no tailcat | Not yet (the tests use stubs; the unit file follows systemd's documented format) |
| The four SHA-256 digests the script carries match the real dumbpipe 0.40.1 release files, and the archive holds the program as `./dumbpipe` | The four files downloaded from GitHub and hashed on a Mac, 2026-11-12 |
| The whole `--iroh` run (the real release download by the script, a real launchd or systemd service, a real Collie, a phone that pairs over mobile data) | Not yet. The pieces were checked one by one (rows above). |
| `--relay-url` with an `https://` relay that has a real certificate, a paid relay of n0's (authentication switched off), a phone and a computer on different networks meeting at a relay of yours, and the real `cargo install` run by the script (the tests use a stub; the build was done by hand once, about 1 minute 20 seconds with a warm cache) | Not yet |
| The whole `--tailcat` run on one computer, from `curl ... | sh` to a phone that pairs over mobile data | Not yet. The pieces were checked one by one (rows above). |
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
