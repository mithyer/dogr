# dogr

One command that puts [Collie](https://github.com/AltanS/collie) on your computer and pairs your phone with it, for the
Dogr iOS app.

It does not replace Collie and it does not edit your files. It calls Collie's own commands, checks that each step worked, and
stops with a clear message when something on your side (Tailscale, mostly) still needs doing.

## Run it

```sh
curl -fsSL https://dogr.dev/setup.sh | sh
```

The script first asks how your phone reaches this computer (see [Routes](#routes)), then says what it is about to do and asks
once. Then it:

1. installs Collie with Collie's own installer, only if Collie is not installed yet. It installs the **Dogr build of Collie**
   (a release of [`mithyer/collie`](https://github.com/mithyer/collie), named like `v1.28.5-dogr.3`; see
   [Which Collie](#which-collie)). A Collie that is already a Dogr build is left as it is, unless the command asks for a newer Dogr build with
   `--collie`: then it is updated to that build. An upstream Collie is switched to the Dogr build in place. Both print the way back
   (see [Which Collie](#which-collie));
2. makes sure the terminal program Collie drives is there and running: **herdr** (the terminal app) or **herdr-core** (a
   background service). One that is missing is installed with its own installer; herdr-core is started with `hc server
   start`; herdr has to be opened by you, and the script says how when it is not;
3. makes Collie's push keys with `collie push-keys` (two lines in Collie's `.env`), unless they are there already or `--no-push` is given:
   without them Collie never sends a notification to your phone, whatever the app says. Nothing is sent anywhere until you switch
   notifications on in the app, and keys that are already there are never replaced;
4. runs `collie start`, which starts Collie in the background. Over Tailscale it also publishes Collie on your tailnet
   (`tailscale serve`); with `--tailcat`, `--iroh`, `--proxy` or `--lan` Collie publishes nothing itself (for tailcat the script
   first installs tailcat, makes a saved key and runs `tailcat serve` as a background service of your own user, see
   [the tailcat route](#the-tailcat-route); for iroh it installs dumbpipe, makes two saved secrets and runs `dumbpipe listen-tcp`
   the same way, see [the iroh route](#the-iroh-route));
5. checks that Collie answers where your phone will look for it (its Tailscale address, your proxy's address, or this
   computer's local-network address), and that it drives the program you picked;
6. runs `collie pair` last, so the one-time code still has all of its ten minutes left, and shows it as a QR code.

Which terminal program? `--mux herdr` or `--mux herdr-core` decides. Without it the script asks, and marks the one that is
already installed; with no terminal to ask on it stops and tells you to add `--mux`. The Dogr app shows the same choice next
to the command, so the command you copy already has it.

On your phone: open Dogr, tap `+`, tap **Scan QR code**, and point the camera at the code. The scan only fills in the form;
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
| SSH: the phone logs in to this computer's own SSH server and forwards one port to Collie; for a server with a public address, or a network you already reach by SSH | `--ssh` (optionally `--ssh-port`, `--ssh-key`) | Installs nothing. Collie answers on `127.0.0.1` only; with `--ssh-key` the script adds one restricted line to `~/.ssh/authorized_keys`, so the phone's key may open a connection to Collie's port and do nothing else. | Switch on SSH on this computer (macOS: System Settings > General > Sharing > Remote Login) and make it reachable from the phone. |
| Your own domain behind a reverse proxy | `--proxy --url https://collie.example.com` | Collie answers on `127.0.0.1` only and is told its public address (`COLLIE_SKIP_SERVE`, `COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS`, `COLLIE_PUBLIC_URL`). Checks that the address answers, prints a Caddy example, and makes the pairing code only when it does. | The proxy itself, its certificate, and who may reach it. |
| Local network, plain http, no encryption | `--lan` (and `--host 192.168.1.20` to name the address) | Finds this computer's local-network address (asks when there are several), makes Collie answer on that address only (`COLLIE_HOST`, `COLLIE_ALLOW_NON_LOOPBACK_BIND` and the four settings above) and checks it. | Keep it to a network you trust. |

Without a route option the first question is "Do you reach this computer from your phone through Tailscale?". Answer no and it asks
whether it is tailcat, iroh, your own domain behind a reverse proxy, the local network, or SSH (answer with the number or the word). Another route than the one you ran before is fine:
the lines the script added are replaced where they stand. Only the Tailscale route refuses to run over a leftover of the others
(`COLLIE_SKIP_SERVE=1` or a `COLLIE_HOST` that is not loopback), because Collie would silently not publish itself; it names the
lines to delete.

### What the local-network route opens up

Collie then answers to everything on your local network, over plain http. From Collie's source, every API request other than the
health check and the pairing needs the key that pairing hands out, and pairing needs the one-time code (ten minutes, five tries).
That is a lock, not encryption: do not use this route on a shared or public network. A real Collie, bound the same way in an empty
home folder, answered `device not paired` to unpaired requests on the routes tried and paired with the Dogr app on a simulator.

### The tailcat route

[tailcat](https://github.com/tailscale/tailcat) is "Tailscale without Tailscale": a tunnel between your phone and this computer,
encrypted end to end (WireGuard), that needs no account and no open port. The two ends find each other through a **tailcat address**
(a 154-character word starting with `tc`); relays that tailcat runs help when the two cannot reach each other directly.

What the script sets up:

1. **tailcat itself.** On macOS with Homebrew (`brew install tailcat`; the releases have no Mac file). On Linux the release file for
   your processor (amd64, arm64, armv7) is downloaded from GitHub, checked against the release's `checksums.txt`, and the
   program goes into `~/.local/bin`.
2. **A saved key** named `herdogr` (`tailcat genkey --key=herdogr --fixed-region`; the name is an old one, kept so that a key made by
   an earlier run, and the address baked into it, stay the same). The relay region is baked into the key, so the
   address is the same after every restart. If picking the nearest region fails (it sometimes does), it is tried three times and
   then the script asks you to run it again with `--region NAME` (`tailcat genkey --region=list` shows the names). An existing key
   is kept as it is.
3. **A background service** running `tailcat serve --key=herdogr <Collie's port>`: a launchd agent on macOS
   (`~/Library/LaunchAgents/dev.dogr.tailcat.plist`), a `systemd --user` unit on Linux (`~/.config/systemd/user/dogr-tailcat.service`).
   Its log, `~/.local/state/dogr/tailcat.log`, is where the script reads the address from. It starts again after a restart (on Linux
   servers, `loginctl enable-linger $USER` once keeps it running when nobody is logged in).
4. **Collie's settings** in `~/.config/collie/.env`: `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and
   `COLLIE_PUBLIC_URL=http://tailcat.invalid/<tailcat address>`. That last line is how `collie pair` puts the address into its QR code:
   the link is `http://tailcat.invalid/<address>/settings?pair=<code>`. The host name never resolves; the Dogr app recognises it and
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
  seconds. The Dogr app slows its polling down by itself when requests are slow.
- The phone's tunnel library is built from a tailcat commit a little newer than the 0.7.0 release the script installs. A 0.7.0 server and
  that client talked to each other in a test; a later tailcat release may not.

### The iroh route

[iroh](https://github.com/n0-computer/iroh) is a library from n0 that connects two devices by a public key and finds a direct path
between them, or goes through n0's relay servers when it cannot. [dumbpipe](https://github.com/n0-computer/dumbpipe) is n0's small
program that hands one TCP port of this computer to such a connection. The Dogr app links the same library and opens the other
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
   the host name never resolves, and the Dogr app recognises it and opens the tunnel instead.

**The iroh address is a secret**, like the tailcat one: the endpoint id plus the name. The script never prints it (the QR code shows it,
and so do `collie status` and `collie doctor`), and the plan shows `<your iroh address>`.

#### Your own relay

A relay is the server both ends fall back on when they cannot find a direct path; it only passes encrypted data on, and **both ends
must use the same one**. By default that is n0's public relays. `--relay-url https://relay.example.com` makes this computer use a relay
of yours instead: the open-source [`iroh-relay`](https://github.com/n0-computer/iroh/tree/main/iroh-relay) that you run yourself, or a
paid relay of n0's with its authentication switched off. A relay that asks for a token made from a project API key is not supported:
this script and the Dogr app only take an address, never a key.

- dumbpipe 0.40.1 has no relay option, so with `--relay-url` the script builds one with `cargo install --git` from a pinned commit of
  dumbpipe's `ramfox/relay-flag` branch (not released yet) into `~/.config/dogr/iroh/bin`, and the service runs
  `dumbpipe listen-tcp ... --relay '<url>' --custom-alpn ...`. **Rust's `cargo` must be installed** (the script stops with exit code 5
  and says so when it is not); the first build takes a few minutes. Without `--relay-url` nothing changes: the release file is used.
- The address has to be given to the phone as well: the Dogr app has a relay field next to the command and puts the same address into
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
- The Dogr app needs iOS 17.5 or newer for the iroh route (the library's own minimum).

### The SSH route

Many computers can already be reached by SSH: a server with a public address, a machine on a network you trust, a VPN. The
phone then needs nothing more than the sign-in it would use for SSH. The Dogr app opens an SSH connection to this computer and
forwards a local port on the phone to Collie's port here, so Collie keeps answering on `127.0.0.1` only and no new program or
service runs on this computer.

What the script does:

1. **Installs nothing and starts no service.** Collie is told, as for the tunnel routes, to publish nothing itself
   (`COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>`) and to give out `COLLIE_PUBLIC_URL=http://ssh.invalid/<ssh port>:<host key
   fingerprint>:<Collie's port>:<your user name>`. That host name never resolves; the Dogr app recognises it. It names no host, because
   the script cannot know how the phone reaches this computer: the app asks for that address.
2. **With `--ssh-key`**, adds one line to `~/.ssh/authorized_keys` (the folder `~/.ssh` mode 700, the file mode 600, created when missing):

   ```text
   restrict,port-forwarding,permitopen="127.0.0.1:<Collie's port>",command="false" ssh-ed25519 <key> dogr-phone
   ```

   That key can open a connection to Collie's port on this computer and nothing else: no shell, no other port, no agent or X11
   forwarding. A line for the same key is replaced, never duplicated. Your other lines are not touched, and when you already
   allow the same key without limits the script leaves that line as it is and says so.
3. **Without `--ssh-key`** it writes nothing to `~/.ssh`: the phone signs in with the password of your user, which is stored on the
   phone only, in its Keychain. A key is the better choice; a password works for any SSH server that allows passwords.
4. **Checks whether something answers on the SSH port** of this computer and warns when not. It cannot switch SSH on for you (on a
   Mac: System Settings > General > Sharing > Remote Login, or `sudo systemsetup -setremotelogin on`; on Linux: `sudo systemctl
   enable --now ssh` or `sshd`). It does not stop, because the check only sees this computer, not what your phone can reach.

The key is made by the Dogr app, on the phone, and never leaves it; the script only ever sees the public half. The fingerprint of
this computer's `ssh-ed25519` host key travels in the link, so the phone can refuse a computer whose key differs. With no such
key (`none` in the link) the phone shows the fingerprint it sees and asks you once.

Things to know:

- It reaches only as far as SSH does. Unlike tailcat or iroh there is no finding a way through a home router; a computer behind
  one needs its SSH port forwarded or a VPN in between.
- Do not put a password-only SSH server on the internet: that is for you to secure, not for this script.
- `command="false"` makes a connection with this key that asks for a shell end at once; the port forward is what the key is for.

## Which Collie

Dogr uses its own build of [Collie](https://github.com/AltanS/collie), published as releases of
[`mithyer/collie`](https://github.com/mithyer/collie). The code is Collie's; a Dogr release is a Collie release plus a suffix
(`v1.30.0-dogr.26` is Collie 1.30.0; the number after `dogr.` only ever rises and does not restart at 1 with a new Collie release) and its own update address, so `collie update` looks for the next Dogr
build there and never offers an upstream release by mistake. By default the script pins one tag (`DOGR_COLLIE_TAG`), because a person
who runs it by hand should get a build it was tested with. The Dogr app does not rely on that: the command it shows ends with
`--collie <the build the app recommends>`, which replaces the pinned tag, so a new recommended build needs a new app and no new script.

What the script does with a Collie that is already there:

| Collie on this computer | What happens |
| --- | --- |
| none | The pinned Dogr build is installed (or the one `--collie` asks for). |
| a Dogr build (`...-dogr.N`), no `--collie` | Left as it is. |
| a Dogr build older than the one `--collie` asks for | **Updated in place**, the same way as the switch below (the plan says "updated"); the way back names the Dogr repository and the old tag. The same or a newer build is left as it is: the script never goes back. |
| an upstream release not newer than the pin | **Switched in place**: Collie's installer lays the pinned version beside the old one and points `current` at it; Collie is restarted at the end; the line that goes back is printed. |
| an upstream release newer than the pin | Left as it is (switching would be a downgrade). |
| a version it cannot read | Left as it is. |
| the switch fails (no network, a git checkout, ...) | A warning, then the setup goes on with the Collie that is there. |

The way back, as printed by the script (the old version in place of `<old>`):

```sh
curl -fsSL https://raw.githubusercontent.com/AltanS/collie/v<old>/scripts/install.sh | COLLIE_UPDATE_REPO=AltanS/collie COLLIE_TAG=v<old> sh
collie restart
```

To follow upstream releases again afterwards, keep `COLLIE_UPDATE_REPO=AltanS/collie` in `~/.config/collie/.env`.

## Options

Options go after `-s --` when the script comes through a pipe:

```sh
curl -fsSL https://dogr.dev/setup.sh | sh -s -- --tailscale --yes
```

| Option | Meaning |
| --- | --- |
| `--tailscale` | The phone reaches this computer through Tailscale. Answers the first question for you. |
| `--tailcat` | The phone reaches it through a tailcat tunnel. |
| `--iroh` | The phone reaches it through an iroh tunnel (dumbpipe). |
| `--relay-url URL` | iroh: use a relay server of your own (`https://`, or `http://` on this computer or the local network; a host name, no user name, no query or fragment) instead of n0's public relays. Implies `--iroh`. The phone must be given the same address; the Dogr app puts it into this command from its own field. Needs Rust's `cargo`, see [your own relay](#your-own-relay). |
| `--ssh` | The phone reaches it through this computer's SSH server. |
| `--ssh-port N` | ssh: the port of this computer's SSH server (default 22). The phone is told the same number. Implies `--ssh`. |
| `--ssh-key KEY` | ssh: the public key of the phone, only the base64 part of an `ssh-ed25519` line (68 characters beginning `AAAAC3NzaC1lZDI1NTE5AAAAI`). The script allows that key to open a connection to Collie's port, nothing else (see [the SSH route](#the-ssh-route)). Implies `--ssh`. Without it nothing is written to `~/.ssh`; use it when the phone signs in with a password. |
| `--derpmap-url https://relay.example.com/map.json` | tailcat: your own relay map (`https://`, a host name, no user name, and only letters, digits and `. _ ~ : / ? = & # + , -`). Used for the key and the service. Implies `--tailcat`. |
| `--region NAME` | tailcat: the relay region for a new key (an ID, code or name from `tailcat genkey --region=list`, or the host name of your own relay). Implies `--tailcat`. |
| `--proxy` | The phone reaches it through your own domain and a reverse proxy. |
| `--url https://collie.example.com` | The public address of that proxy: `https://`, a host name, an optional port, no path. Implies `--proxy`. Without it the script asks. Port 443 is dropped, any other port is kept (Collie compares the Host header with the port). |
| `--lan` | The phone reaches it over the local network, plain http. |
| `--host 192.168.1.20` | This computer's address on the local network. Implies `--lan`. Without it the script looks for one (private ranges only, not Tailscale, Docker or virtual machines) and asks when there are several; with no terminal to ask on it stops and lists them. |
| `--mux herdr` or `--mux herdr-core` | The terminal program Collie drives. Without it the script asks (and stops when there is no terminal to ask on). A program that is missing is installed after you agree to the plan. |
| `--collie 1.28.5-dogr.6` | Which Dogr build of Collie to install (a leading `v` is fine). The Dogr app puts the build it recommends at the end of the command it shows. It replaces the pinned tag (and `DOGR_COLLIE_TAG`) in the plan, in the address of Collie's installer and in the tag the installer is given. It names the build for a computer without Collie and the one an older upstream Collie or an older Dogr build is switched to (the old version stays beside it, and the way back is printed); a Dogr build that is the same or newer is left alone, so this never goes back. Without the option a Dogr build is never touched. Only the exact shape of a Dogr build is accepted (`X.Y.Z-dogr.N`), because the value goes into the address of an installer that is run. Leave it out when you run the script by hand. |
| `--from iosv0.2` | Read and dropped. Older builds of the app wrote it to say which app asked; it was never used, and their commands keep working. |
| `--yes`, `-y` | Do not ask before changing anything. Needed when there is no terminal. Does not agree to `http://` addresses; use `--http` for that. |
| `--http` | If your tailnet has no HTTPS certificates, switch Collie to `http://` addresses (`COLLIE_SERVE_MODE=http`) without asking. |
| `--no-push` | Do not make Collie's push keys (`collie push-keys`). Without keys Collie's push stays off and the phone gets no notifications; you can make them later by hand (see below). |
| `--dry-run` | Say what would happen, change nothing, stop. |
| `--help`, `-h` | Show the usage text. |

| Environment variable | Meaning |
| --- | --- |
| `DOGR_COLLIE_REPO` | The GitHub repository the Dogr build of Collie comes from. Default `mithyer/collie`. |
| `DOGR_COLLIE_TAG` | The Collie release to install. Default `v1.30.0-dogr.26`, the one this script was tested with (never "the newest"). The option `--collie` wins over it. |
| `DOGR_COLLIE_INSTALL_URL` | Where Collie's installer comes from. Default: `scripts/install.sh` of that repository at that tag (`https://raw.githubusercontent.com/<repo>/<tag>/scripts/install.sh`). |
| `DOGR_HERDR_INSTALL_URL`, `DOGR_HERDR_CORE_INSTALL_URL` | Where the installers of herdr and herdr-core come from. Defaults `https://herdr.dev/install.sh` and `https://releases.herdr.dev/core/install.sh`. |
| `DOGR_TAILCAT_VERSION`, `DOGR_TAILCAT_RELEASE_URL` | Linux: which tailcat release to download (default `0.7.0`) and where its files are (default `https://github.com/tailscale/tailcat/releases/download/v<version>`). On macOS Homebrew decides the version. |
| `DOGR_DUMBPIPE_GIT`, `DOGR_DUMBPIPE_REV` | `--iroh --relay-url`: the git repository and the commit that dumbpipe is built from (default `https://github.com/n0-computer/dumbpipe` at `e2181df077ff`). |
| `DOGR_DUMBPIPE_RELEASE_URL`, `DOGR_DUMBPIPE_SHA256` | `--iroh`: where dumbpipe's release files are (default `https://github.com/n0-computer/dumbpipe/releases/download/v0.40.1`) and the SHA-256 the downloaded file must have. Without the second, the digest the script carries for the default release is used; set it when you use another release file. |
| `DOGR_SSH_HOST_KEY` | `--ssh`: the public host key file whose fingerprint goes into the link, so the phone can recognise this computer. Default `/etc/ssh/ssh_host_ed25519_key.pub`. |
| `DOGR_PROGRESS` | `always`, `never` or `auto` (default). While the installers download, a line such as `collie-1.28.1-macos-arm64.tar.gz  12.3 / 47.1 MB  (26%)  0.3 MB/s` is drawn. `auto` draws it on a terminal only, so a log or a pipe stays clean; files under 1 MB (scripts, checksums) are never drawn. Nothing about the download changes: every call still reaches the real `curl` with its own options. |
| `DOGR_TTY` | Where answers are read from. Default `/dev/tty`. Tests point it at a file. |
| `DOGR_TRIES`, `DOGR_POLL_DELAY` | How often, and how many seconds apart, to check that Collie answers. Default 20 and 1. |

## Exit codes

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Done (or a dry run, or `--help`). | Scan the code. |
| 1 | Wrong use (two routes at once, a bad `--url`, `--host`, `--derpmap-url`, `--ssh-port`, `--ssh-key` or `--collie`), unsupported computer, or no terminal to ask on. | Read the message; add `--yes` (and the route and `--mux`) when there is no terminal. |
| 2 | Not used. It once meant "route not scripted"; the number stays free so the others keep their meaning. | |
| 3 | Something needs you first: herdr is installed but not running, Collie reports a missing piece (for example Tailscale not signed in, or HTTPS not enabled and `http://` not agreed to), no local-network address was found, a proxy address that does not answer yet, settings of another route left in the `.env`, a setting of yours could not be used, or Collie drives another terminal program or gives another address than the one asked for. | Do what the message says, then run the command again. For the proxy: set it up, then `collie pair`. |
| 4 | Collie did not start or does not answer, herdr-core could not be started, or (tailcat, iroh) the key could not be made, the service could not be started, it printed no address, or (iroh) the running service has another endpoint id than the saved key. | `collie logs`; for tailcat and iroh the message names the command, and `~/.local/state/dogr/tailcat.log` or `iroh.log` has the service's own words. |
| 5 | Collie, herdr, herdr-core, tailcat or dumbpipe could not be downloaded or installed: no Homebrew on a Mac, no tailcat or dumbpipe release for the processor, a checksum that does not match. | Read the installer's output above the message. |
| 6 | You answered no at the question. | Nothing was changed. |

## What changes on your computer

Only what Collie's own commands change:

| What | Where |
| --- | --- |
| Collie's program files (the Dogr build; an upstream Collie that was there gets the Dogr build beside it) | `~/.local/share/collie` (or `$COLLIE_DIR`), and a `collie` link in `~/.local/bin` |
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
| For `--ssh --ssh-key`: one line | `~/.ssh/authorized_keys` (the folder mode 700, the file mode 600), ending in the comment `dogr-phone` |
| For `--ssh`: the settings of that route | `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and `COLLIE_PUBLIC_URL=http://ssh.invalid/<ssh port>:<fingerprint>:<port>:<user>` in `~/.config/collie/.env`; a wide `COLLIE_HOST` goes back to `127.0.0.1`. |
| Two lines, unless the `.env` has them already or you gave `--no-push` | `COLLIE_VAPID_PUBLIC` and `COLLIE_VAPID_PRIVATE`, written by Collie's own `collie push-keys` into the `.env` Collie reads (mode 600; on an install that Herdr manages this is Herdr's config folder, not `~/.config/collie`). They are the key pair that switches Collie's push on. The private key stays on this computer. An existing pair is never replaced (Collie itself refuses, because that would silence every phone that already subscribed). A Collie that was already installed is restarted once so it reads them. |
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

For `--ssh`, delete the line that ends in `dogr-phone` from `~/.ssh/authorized_keys` (the phone can no longer connect), and nothing else was installed.

If the script made push keys, delete the lines that start with `COLLIE_VAPID_` (and the comment `Web Push (VAPID)` above them) from the `.env` Collie reads, then run `collie restart`. Phones that had subscribed stop receiving notifications; running `collie push-keys` again makes a new pair and each phone has to switch notifications on again.

If you chose `http://`, also delete the `COLLIE_SERVE_MODE=http` line (and the comment above it) from `~/.config/collie/.env`, then run `collie restart`.
For `--tailcat`, `--iroh`, `--ssh`, `--proxy` or `--lan`, delete the lines the plan listed (they sit under a `# Added by dogr setup.sh` comment): `COLLIE_SKIP_SERVE`,
`COLLIE_PUBLIC_HOSTS`, `COLLIE_ALLOWED_ORIGINS` (proxy and local network only), `COLLIE_PUBLIC_URL`, and for `--lan` `COLLIE_HOST` and `COLLIE_ALLOW_NON_LOOPBACK_BIND`.
Then run `collie restart` (or `collie uninstall` as above).

To forget a paired phone without removing Collie, run `collie devices list`, then `collie devices revoke <label>`. To stop Collie for now and keep everything, run
`collie stop`.

## The dogr.dev site

`https://dogr.dev` is a Cloudflare Worker with static files. It is not part of what `setup.sh` installs; it only gives the
script a short address and the project a home page. The home page is written once and built in twelve languages (the same
twelve as the app).

| File | What it is |
| --- | --- |
| `site/page.html` | The page template. `{{key}}` is replaced by a string of the language, `{{@key}}` by the same string as plain text (for attributes) |
| `site/i18n/strings.csv` | Every text of the page, one row per key, one column per language (`key,en,de,es,ko,ja,zh,zh-TW,ru,it,fr,pt,tr`, the order of the app's table). Edit this file, never the generated pages |
| `site/style.css`, `site/page.js`, `site/icon.svg`, `site/img/` | Styles, the copy buttons and the language menu, the icon and the screenshots |
| `site/ios/update-rules-<n>.json` | The rules the iPhone app reads to decide how strongly to suggest an update (see below). `<n>` is the format number |
| `site/whatsnew.html`, `site/whatsnew.js`, `site/whatsnew.mjs`, `site/whatsnew-<n>.json` | The "What's new" page (`/whatsnew`): the template (built once per language like the home page), the script that draws the list in the browser, the rules that script uses (splitting the notes, choosing a language), and the data file it draws from (see below). `<n>` is the format number |
| `tools/whatsnew.mjs` | Keeps that data file up to date from the App Store and publishes the page (see below) |
| `lang.js` | The twelve languages and the rules that pick one (cookie, then `Accept-Language`, then English; a country to a language). Used by the Worker, the build and the page |
| `app-store.js` | The App Store address `/get` leads to (`APP_STORE_URL`). It is not in `worker.js` because a Worker must export only its handler: the current Cloudflare runtime refuses other exports, which also broke `wrangler dev` |
| `build-site.mjs` | Builds `dist/` (git-ignored): one page per language at `/<code>/` and `/<code>/whatsnew/`, `sitemap.xml`, `robots.txt` and the files above. It refuses to build when a language lacks a key, has a key too many, an empty text, other markup than English or another number |
| `worker.js` | Answers `/setup.sh` (passes through the script on the `main` branch of this repository, kept for 60 seconds; anything that does not start with `#!/bin/sh` becomes an error status, so a broken answer never reaches `\| sh`), `/` and `/whatsnew` (send the visitor to the page in their language), `/get` (a temporary redirect to the app's page in the App Store, `APP_STORE_URL` of `app-store.js`; the download badges and the QR code of the home page point here, so the target can change without making the code again) and `/_geo` (a language suggested by the country of the request, nothing else) |
| `wrangler.jsonc` | Names the Worker `dogr-site`, runs `node build-site.mjs` before every deploy, serves `dist/`, sends only `/setup.sh`, `/`, `/get`, `/_geo`, `/whatsnew` and `/whatsnew/` to `worker.js`, and attaches the domain `dogr.dev` |

How a visitor gets a language: `/` looks at the `lang` cookie (set only when someone picks a language in the menu), then at the
browser's language list, then falls back to English; English is shown at `/` itself, any other language by a temporary
redirect to `/<code>/`. A page address such as `/de/` is never redirected, so a link always shows what it says (`/en/` is
the address that always means English). The language menu in the top corner does not list every language: it holds English, the
language of the page, and, once it is opened, the browser's language and a language guessed from the visitor's country (`/_geo`,
which is only a suggestion and never switches the page by itself). The other languages are still reachable by their address
(`/de/`, `/ja/`, ...) and are known to search engines. When the menu opens, `webrtc-ip` 5.0.1 (vendored from commit `220deb1beb57c21e3219faf63d9232d50f17a940`, Apache-2.0; license in `site/vendor/`) asks STUN servers at Bilibili, Cloudflare and Google for a public IP address (in parallel, so a network that cannot reach one can still try the others). These are best-effort public servers, not a guarantee of availability in mainland China. The page sends it in a POST body to `/_geo`; the Worker asks `ipwho.is` for its country and returns only the corresponding language. A successful lookup takes precedence even if that country has no matching language; if WebRTC or the lookup fails, GET `/_geo` falls back to the Cloudflare country. These services see the IP address, so the footer and privacy page disclose them. The site stores nothing in the browser except the language a visitor picks.

The script is read from GitHub on every request (through Cloudflare's cache), so a push to `main` needs no new deployment.
Only a change to `site/`, `lang.js`, `worker.js` or `wrangler.jsonc` has to be deployed, by hand (the build runs first):

```sh
npx wrangler@4 deploy
```

To look at it first: `node build-site.mjs`, then `npx wrangler@4 dev --local --port 8799`. The country suggestion needs the
real Cloudflare network (`/_geo` answers `null` locally).

The home page shows the App Store badge and a QR code at the right of the name and again in the download section. The badges
are Apple's own files, unchanged, one per language (`site/img/appstore/<code>.svg`, from Apple's marketing tools; do not redraw or
recolour them). The code is `site/img/qr-get.svg`, a static SVG of `https://dogr.dev/get` made on a Mac by
`swift tools/make-qr.swift make https://dogr.dev/get site/img/qr-get.svg`; `swift tools/make-qr.swift check <picture> <text>`
reads a picture of the code back (for example a rasterised copy) and fails when it does not say the text. The code never has to
change when the App Store address does, because it holds `/get`, not the store address.

The iPhone app's update reminder reads a small public file, `https://dogr.dev/ios/update-rules-1.json`, and only when the App
Store has a newer version than the one installed (at most once a day). It sends nothing from the phone: no account, no version, no
device identifier. The file says how loud each release is, and the app does the comparing:
```json
{ "schema": 1, "releases": { "0.3": "orange", "0.4": "green", "0.5": "red" }, "appBelow": [ { "version": "0.3", "level": "orange" } ] }
```
`releases` gives the level of each release (`green` is a note in Settings, `orange` a suggestion, `red` a strong one); an app that is
several releases behind gets the highest level among the releases it missed. `appBelow` raises the level for every app older than
the given version. A release that is not listed counts as `green`. The number in the file name is the format: a change that an old
app could not read goes into a new file (`update-rules-2.json`), and the old file stays and keeps being updated, so old apps keep
working. `node build-site.mjs` refuses a file that is not valid (bad version or level, a list out of order, a `schema` that
differs from the file name, any other file name in `site/ios/`).
The GitHub address of the script (`https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh`) keeps working, because earlier
versions of the app show it, and it stays the fallback. To take the site down, delete the Worker `dogr-site`
in the Cloudflare dashboard (Workers & Pages); nothing else depends on it.

### The "What's new" page

`https://dogr.dev/whatsnew` shows what each version of the app changed, newest first, in the visitor's language (chosen like the
home page: `/whatsnew` redirects to `/<code>/whatsnew/`, English is served at the address itself). The notes are the
App Store's own "What's New" texts, one per language. A language a version has no text in shows the English text, marked with the
language. The page itself is static; the browser draws the list from `/whatsnew-1.json`. Only the newest version is open: the earlier
ones are in the page but hidden until the button "Show earlier versions" under it is pressed (a link such as `/whatsnew#v0.3` to a
hidden one opens them first). With one version in the file there is no button:
```json
{ "schema": 1, "versions": [ { "version": "0.4", "notes": { "en": "Summary.\n\n• One\n• Two", "de": "…" } } ] }
```
`notes` is keyed by the site's language codes (`en`, `de`, `es`, `ko`, `ja`, `zh`, `zh-tw`, `ru`, `it`, `fr`, `pt`, `tr`); English is required.
There is no date: App Store Connect does not give the real release date. The number in the file name is the format, as with the
update rules. The top bar of the home page shows a pill with `v<newest version>` of this file and a word that says what it opens ("What's new", key
`pill.label`) and leads to the page; on a phone narrower than 480 px the language button of the home page shows only its globe so that
all three fit side by side. `node build-site.mjs`
refuses a file that is not valid (a version out of order or repeated, no English text, an unknown language, a text over 4000 characters).

To bring it up to date and publish it, run the script (it needs the App Store Connect key in `ASC_KEY_ID`, `ASC_ISSUER_ID` and
`ASC_PRIVATE_KEY_PATH`, or in `~/.config/dogr/testflight.json`, and the `asc` command-line tool):

```sh
node tools/whatsnew.mjs --dry-run    # only show what would be added
node tools/whatsnew.mjs              # add, check, ask, deploy, commit locally
```

It reads the released iOS versions of the app, keeps those newer than the newest version in the file (nothing newer: it says so and
stops), reads their notes in every language, and adds them. A version without an English text is skipped with a message. Then it
runs the site tests and a test build, asks, runs `npx wrangler@4 deploy`, and commits only the data file (`feat(site): add the release notes
of 0.5`). It never pushes. If a check, the question or the deploy fails, the old file is put back, so running it again redoes the
whole update. Other uncommitted changes in this repository stop a deploy (they would be published too) unless `--allow-dirty`.
Options: `--no-deploy` (write and check only; deploy by hand later), `--no-commit`, `--yes` (do not ask), `--skip-tests`,
`--app <id>` (default: `ASC_APP_ID`, else the id in `app-store.js`). The key is never printed or written anywhere.

## Tests

```sh
sh tests/run.sh
```

The tests run `setup.sh` against a stub `curl`, `collie`, `hc`, `herdr`, `ifconfig`, `ip`, `uname`, `brew`, `tailcat`, `dumbpipe`, `launchctl`, `systemctl`, `nc` and `ssh-keygen`, each case in its own empty home folder. They cover the
normal path, running twice, `--dry-run`, installing first, switching an upstream Collie to the Dogr build (done, dry run, a newer Collie, an unreadable version, a failed download or installer, an installer that changes nothing), updating an older Dogr build to the one `--collie` asks for (done, numbers compared as numbers, the same or a newer build, no option, an unreadable version, a failed installer, an installer that changes nothing, dry run), a failed download or installer, Collie naming a missing setup step,
no Tailscale address, Collie not answering, the Tailscale address not answering from this computer, a failed start, a QR
code that could not be drawn, a tailnet without HTTPS certificates (agreed, declined, `--http`, an existing `.env`, a setting
Collie does not pick up), the terminal program (named, asked for, installed, not running, a failing installer or start, an
`.env` that names the other one, Collie driving the wrong one), the reverse proxy route (addresses that are accepted and refused, the port, asked for or
given, settings added, replaced or already there, a wide bind from an earlier run, the proxy not answering, Collie not reading the settings), the local-network route
(which addresses are offered, one or several, `--host` and its checks, Linux's `ip`, another port, no address, the risk being named before the question),
the tailcat route (macOS with Homebrew and Linux with a downloaded release for three processors, a wrong or unlisted checksum, no Homebrew, a key that exists or fails to be made, a region or relay map, the service not starting or printing no address, an old log that must not be trusted, another port, settings already there or older, Collie not reading them; where the system has `plutil` it also checks that the launchd file is a valid property list),
the iroh route (macOS and Linux for two processors, a processor with no release, a wrong checksum, a failed download, a dumbpipe that is installed, too old or lacks `--custom-alpn`, a relay address that is refused or passed on to the service (and the build of a dumbpipe that has `--relay`, with and without `cargo`), saved secrets that are used again or replaced when malformed, file modes, a ticket that cannot be read, a service that prints no ticket, an old log that must not be trusted, a ticket of another key, a relay that cannot be reached, a service that does not start, another port, settings already there or older, Collie not reading them, and the questions and options that lead to it; the secrets are checked to appear in no output and not in the runner),
the SSH route (the line added, replaced or already there, other lines kept, a key that is refused, other ports, no host key, SSH not answering, the key never printed), the Tailscale route refusing leftovers, answering at the terminal, no terminal, wrong options, running through a pipe, a download that stops half way, and the progress line (drawn when asked, quiet without a terminal or with `DOGR_PROGRESS=never`, the size in megabytes, a server that gives no length, small files, a failing download, both orders of `-o` and the address). the push keys (made before the first start, an installed Collie restarted once, keys that are there already, Collie refusing, a failure that only warns, `--no-push`, a dry run). `shellcheck` runs too when it is installed.

The site has its own tests (the language rules, the string table and its checks, the build, and the Worker with a stand-in for the static files): `node --test tests/site.test.mjs`. The "What's new" page's rules and the update script (run with stand-ins for the App Store, git and Cloudflare) are tested in `tests/whatsnew.test.mjs`; run everything with `node --test tests/*.test.mjs`.

## What has and has not been checked

| Checked | How |
| --- | --- |
| The logic of every step and every exit code | `tests/run.sh`, with stubs |
| The shape of Collie's `start`, `status --json` and `pair` output the script reads | Read from Collie's source |
| That `COLLIE_SERVE_MODE=http` in `~/.config/collie/.env` turns the address from `https://name` into `http://name:8787` | Real `collie status --json` in an empty home folder |
| The script runs on macOS 15 (Intel) over ssh: `--help`, `--dry-run`, no terminal, unknown option, "no" at the route question, "no" at the confirmation. Each exits with the documented code and changes nothing | Run once on a spare Mac, 2026-11-10 |
| That the proxy and local-network settings make Collie report the address the phone should use (and, for `--lan`, the bind address as its local address) | Real `collie status --json` in an empty home folder, with the lines written to `~/.config/collie/.env` as the script writes them (also `COLLIE_PORT`, which moves every address to that port) |
| That Collie bound to a local-network address only (the settings above) answers on that address, not on loopback, reports it as both its local and phone address, accepts `POST /api/pair` with an `Origin` (and refuses without), and pairs with the Dogr app | A real Collie bridge in an empty home folder, then the app in the iPhone simulator against `http://<this Mac's address>:<port>` |
| That every API request except the health check and the pairing is refused with `device not paired` | A real bridge, eight routes tried without a token |
| `--lan --host ... --dry-run` on a Mac with several addresses (it lists them, and stops when there is no terminal to ask on) | Run on the author's Mac, changing nothing |
| That `collie push-keys` writes `COLLIE_VAPID_PUBLIC` and `COLLIE_VAPID_PRIVATE` (mode 600) into the `.env` and refuses the second time with "already configured" and exit 1, which is how the script reads it | Real `collie push-keys` (the installed `1.28.5-dogr.3`) with a scratch home folder, state folder and `HERDR_PLUGIN_CONFIG_DIR`, 2026-11-18 |
| That `COLLIE_MUX` in the `.env` wins over the environment, and an empty `.env` follows the environment | Real `collie status --json` in an empty home folder |
| `hc server start` is safe to repeat, and `herdr` has no way to start without a terminal | Real `hc` in an isolated session; `herdr --help` and its README |
| That the launchd file the script writes is accepted by the real launchd, starts the real `tailcat serve` (Homebrew's 0.7.0) with a saved key, that the service's log carries the address in the form the script reads (154 characters, the same as `tailcat genkey` printed), that launchd starts the service again after it is killed with the same address, and that `bootout` stops it | Run on the author's Mac with a throw-away label, key and port; all removed afterwards |
| That the Linux download steps work on the real release: the file is listed in `checksums.txt`, its sha-256 matches, and `tar -xzf <file> tailcat` yields a statically linked executable (for amd64; arm64 and armv7 are listed too) | The real v0.7.0 files, checked on a Mac (the executable was not run) |
| That a leftover `COLLIE_ALLOWED_ORIGINS` of the proxy route does not stop a phone from pairing over the tunnel | A real Collie bridge: pairing with an `Origin` of the phone's own address returned 200 with and without the setting |
| That a Collie behind `tailcat serve` pairs and answers through the tunnel with `COLLIE_SKIP_SERVE=1`, `COLLIE_PUBLIC_HOSTS=127.0.0.1:<port>` and a `COLLIE_PUBLIC_URL` carrying the address; that the link `collie pair` prints with it is 200 characters and fits a QR code | Real Collie and real tailcat (a 0.7.0 server with a saved key and a newer client), an iPhone simulator, and two real iPhones (Wi-Fi and mobile data) with a test app |
| The iroh mechanics with the real programs: a real dumbpipe 0.40.1 (`listen-tcp --custom-alpn`) in front of a small web server on one Mac, reached by a Swift program through the Dogr app's iroh library (iroh-ffi 1.2.0): connect by endpoint id alone, a request over HTTP keep-alive on one stream, a wrong name refused at the handshake with `peer doesn't support any known protocol`, and the endpoint id derived from the key with `openssl` equal to the one in the ticket | Run on the author's Mac in a throw-away folder; both ends were on one Mac, so it says nothing about mobile data or other countries |
| `--relay-url`: a dumbpipe built from the pinned commit (`e2181df077ff`) listens with `--relay http://127.0.0.1:3340` in front of a scripted Collie stand-in; the Dogr app (iPhone simulator, relay address in its Add form) pairs, shows the machine online and its spaces; with the relay stopped and the app reopened the machine is offline, and online again after the relay and this computer's endpoint came back | Run on the author's Mac with a throw-away `iroh-relay --dev` (http, local only), a scratch folder and no real Collie or service; both ends were on one Mac |
| The real installers of herdr and herdr-core, and a real `herdr status server` text when it is not running | Not yet (the tests use stubs; the "not running" wording was read from a real Herdr) |
| The progress line, drawn by the real `curl` against the real Collie release on GitHub (`2.0 / 47.1 MB  (4%)  0.3 MB/s`, then curl's own timeout message and exit code 28 passed through, no leftover files) | Run on the author's Mac with `DOGR_PROGRESS=always` and an 8-second limit. Not yet seen in a real terminal window with Collie's own installer. |
| The Dogr build installs: Collie's own installer, pinned to the real release `v1.30.0-dogr.26` of `mithyer/collie`, into an empty home folder; `collie version` says `1.30.0-dogr.26+...`, `collie doctor` names `github.com/mithyer/collie` as the update source, and `collie update --check` finds nothing newer | Run on the author's Mac, 2026-11-14 (`1.28.1-dogr.1`), 2026-11-15 (`1.28.1-dogr.3`), 2026-11-17 (`1.28.5-dogr.3`), 2026-11-19 (`1.28.5-dogr.6`), 2026-11-20 (`1.28.5-dogr.7`), 2026-11-21 (`1.29.1-dogr.11`, the release check into an empty home folder) and 2026-11-22 (`1.29.1-dogr.13`, the same check) and 2026-11-23 (`1.29.1-dogr.16` and `1.29.1-dogr.17`, the same check) and 2026-11-24 (`1.29.1-dogr.19`, `1.29.1-dogr.20`, `1.30.0-dogr.21`, `1.30.0-dogr.22` and `1.30.0-dogr.23`, the same check) and 2026-11-25 (`1.30.0-dogr.24` and `1.30.0-dogr.26`, the same check) |
| Switching a real upstream Collie to the Dogr build in place (the real installer beside the old version, the restart, the way back), the Dogr build on Linux, and a second Dogr tag offered as an update by `collie update` | Not yet. The tests use stubs; the installer's rule for a pin over an existing install was read from its source, and the update rule was run against Collie's own functions with made-up tags. |
| A real `collie start` with a real Tailscale, with or without HTTPS certificates | Not yet |
| A real `collie start` for `--proxy` or `--lan` (the service reading the `.env` lines), a real Caddy in front, a phone behind it | Not yet. The service reading the `.env` is only inferred from the `status` check above. |
| The Linux service file under a real `systemd --user`, `loginctl enable-linger`, and `brew install tailcat` run by the script on a Mac that had no tailcat | Not yet (the tests use stubs; the unit file follows systemd's documented format) |
| The four SHA-256 digests the script carries match the real dumbpipe 0.40.1 release files, and the archive holds the program as `./dumbpipe` | The four files downloaded from GitHub and hashed on a Mac, 2026-11-12 |
| The whole `--iroh` run (the real release download by the script, a real launchd or systemd service, a real Collie, a phone that pairs over mobile data) | Not yet. The pieces were checked one by one (rows above). |
| `--relay-url` with an `https://` relay that has a real certificate, a paid relay of n0's (authentication switched off), a phone and a computer on different networks meeting at a relay of yours, and the real `cargo install` run by the script (the tests use a stub; the build was done by hand once, about 1 minute 20 seconds with a warm cache) | Not yet |
| The `--ssh` script logic: the line written to `authorized_keys`, replaced, kept, the key refused and never printed, the link, the warnings | `tests/run.sh`, with stubs |
| That a real OpenSSH (macOS, a scratch `sshd` run by an ordinary user) accepts a line of this shape and allows a port forward to the one port named in `permitopen` only (the named port answered, another one was refused) | Tried on 2026-11-15 against a real `sshd` run by an ordinary user, with the exact line the script writes (`restrict,port-forwarding,permitopen="127.0.0.1:<port>",command="false"`): a command was refused, the named port answered, another port was refused; the phone app then paired and stayed online through it |
| The whole `--tailcat` run on one computer, from `curl ... | sh` to a phone that pairs over mobile data | Not yet. The pieces were checked one by one (rows above). |
| Collie after the computer's local-network address changes | Not checked; the script says to run it again |
| Windows | Not supported. Use Collie's own Windows guide. |

## Limits

- macOS and Linux only.
- `--ssh` does not turn SSH on, open a port, or secure the SSH server; it only adds the one restricted key line.
- The script cannot sign you in to Tailscale, enable HTTPS in the Tailscale admin console, or install Tailscale for you. It
  tells you which of these is missing, because Collie says so, and you run it again.
- Some computers cannot reach their own Tailscale name even though other devices can. The script then prints a warning and still
  shows the pairing code. (With `--proxy` it stops instead and says to run `collie pair` once the proxy is up.)
- `--proxy` does not set up the proxy, its certificate, or who may reach it. It prints a Caddy example and the guide to read.
- `--lan` ties Collie to one address. If the computer gets another one (a new network, a DHCP lease that changed), Collie cannot
  start until you run the script again. A fixed address for the computer avoids that.
- The pairing code lasts ten minutes and works once.
