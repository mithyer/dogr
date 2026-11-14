#!/bin/sh
# dogr setup.sh - put Collie on this computer and pair your phone with it.
#
# Five ways for the phone to reach this computer (--tailscale, --tailcat, --iroh, --proxy, --lan; without one the script asks). It calls the
# commands of the programs it sets up and checks the result:
#   1. install Collie, only if it is not installed yet (Collie's own installer);
#   2. make sure the terminal program Collie drives is there and running: herdr or herdr-core (--mux picks one). A missing
#      one is installed with its own installer; herdr-core is started with `hc server start`; herdr has to be opened by you;
#   3. `collie start`: runs Collie in the background. Over Tailscale it also publishes Collie on your tailnet; behind your
#      own reverse proxy (--proxy --url https://...), on the local network (--lan) or through tailcat (--tailcat) Collie
#      publishes nothing itself. For tailcat this script first installs tailcat, makes a saved key (so the address stays
#      the same) and runs `tailcat serve` as a background service of your own user (launchd or systemd --user). Through iroh
#      (--iroh) it is the same idea with dumbpipe: a saved secret key and a secret name, and `dumbpipe listen-tcp` as the service;
#   4. check that Collie answers where the phone will look for it, and drives the program you picked;
#   5. `collie pair`, last of all, so the one-time code has all of its ten minutes left.
# Lines of Collie's own .env may change, each only in the way the plan says before you agree: COLLIE_MUX, when it names the
# other terminal program than the one you picked; on a tailnet without HTTPS certificates (Headscale, for one)
# COLLIE_SERVE_MODE=http (with your agreement or --http); and for --proxy and --lan the settings that route needs
# (COLLIE_SKIP_SERVE, COLLIE_PUBLIC_URL and friends). A line that is there is replaced where it stands, a missing one is added.
# The tailcat and iroh routes also write a service file and a log (see the README for where, and how to undo it).
#
# Run it:        curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh
# Options go after `-s --`:   ... | sh -s -- --tailscale --yes
#
# Safe to run again: a step that is already done is skipped, and nothing is installed twice.
#
# Exit codes: 0 done | 1 wrong use or unsupported computer | 2 (not used) | 3 Collie or the way to it needs setup
#             4 Collie did not start or does not answer | 5 something could not be installed | 6 stopped by you
#
# Environment (all optional):
#   DOGR_COLLIE_TAG           install this Collie release (for example v1.27.0) instead of the newest
#   DOGR_COLLIE_INSTALL_URL   where Collie's installer comes from (default https://colliepwa.dev/install.sh)
#   DOGR_HERDR_INSTALL_URL    where herdr's installer comes from (default https://herdr.dev/install.sh)
#   DOGR_HERDR_CORE_INSTALL_URL   where herdr-core's installer comes from (default https://releases.herdr.dev/core/install.sh)
#   DOGR_TAILCAT_VERSION      the tailcat release to download on Linux (default 0.7.0); macOS takes what Homebrew has
#   DOGR_TAILCAT_RELEASE_URL  where those release files are (default https://github.com/tailscale/tailcat/releases/download/v<version>)
#   DOGR_DUMBPIPE_RELEASE_URL where dumbpipe's release files are (default https://github.com/n0-computer/dumbpipe/releases/download/v<version>)
#   DOGR_DUMBPIPE_SHA256      the SHA-256 the dumbpipe file must have, for a mirror whose file is not the pinned release's
#   DOGR_PROGRESS             always | never | auto (default): draw "12.3 / 45.6 MB" while the installers download (auto = on a terminal only)
#   DOGR_TTY                  where answers are read from (default /dev/tty); a test points it at a file
#   DOGR_TRIES, DOGR_POLL_DELAY   how often and how far apart to check that Collie answers (default 20 and 1 second)

# Everything lives in main(), which runs on the very last line: a download that stops half way then runs nothing at all.
main() {
    set -u

    # ---- settings -------------------------------------------------------------------------------------------------
    INSTALL_URL=${DOGR_COLLIE_INSTALL_URL:-https://colliepwa.dev/install.sh}
    TTY=${DOGR_TTY:-/dev/tty}
    TRIES=${DOGR_TRIES:-20}
    DELAY=${DOGR_POLL_DELAY:-1}
    # how the phone reaches this computer: tailscale, tailcat, iroh, proxy or lan; empty until an option or the questions say
    ROUTE=
    # the https:// address of the reverse proxy (--url), and the address of this computer on the local network (--host)
    PROXY_URL=
    LAN_HOST=
    # the address the phone will use, and the host part the Host header carries, for the proxy and local network routes
    PUBLIC_URL=
    PUBLIC_HOST=
    # tailcat: the relay map address (--derpmap-url), the relay region asked for (--region), the release to download, the name
    # of the saved key, the first part of the link the phone is given, the address of the service (read from its log), the
    # log, and the tailcat program
    DERP_URL=
    TC_REGION=
    TC_VERSION=${DOGR_TAILCAT_VERSION:-0.7.0}
    TC_RELEASE_URL=${DOGR_TAILCAT_RELEASE_URL:-https://github.com/tailscale/tailcat/releases/download/v$TC_VERSION}
    TC_KEY=herdogr
    TC_BASE=
    TC_ADDRESS=
    TC_LOG=$HOME/.local/state/dogr/tailcat.log
    TC_BIN=
    # iroh: the dumbpipe release this script installs (pinned, with its checksums in iroh_release), where its files are, the
    # file and checksum for this computer, the first part of the link the phone is given, the folder of the saved secrets, the
    # endpoint id and the secret name (ALPN) that make up the address, the service log and the dumbpipe program. IR_RELAY is the
    # relay server asked for with --relay-url (empty: n0's public relays). Only a dumbpipe that has the --relay option can use it, and
    # no release has that option yet, so one is built from this pinned commit of the dumbpipe repository (IR_GIT, IR_REV) into
    # IR_DIR/bin when a relay is asked for; the build needs Rust's cargo.
    IR_RELAY=
    IR_GIT=${DOGR_DUMBPIPE_GIT:-https://github.com/n0-computer/dumbpipe}
    IR_REV=${DOGR_DUMBPIPE_REV:-e2181df077ff}
    IR_VERSION=0.40.1
    IR_RELEASE_URL=${DOGR_DUMBPIPE_RELEASE_URL:-https://github.com/n0-computer/dumbpipe/releases/download/v$IR_VERSION}
    IR_FILE=
    IR_SUM=
    IR_BASE=
    IR_DIR=$HOME/.config/dogr/iroh
    IR_ENDPOINT=
    IR_ALPN=
    IR_TICKET=
    IR_LOG=$HOME/.local/state/dogr/iroh.log
    IR_BIN=
    # the port Collie listens on (COLLIE_PORT of the .env, else Collie's default)
    PORT=8787
    # the settings this route needs in Collie's .env, as KEY=VALUE words separated by spaces (no value has a space in it)
    WANT=
    # 1 when this run adds or changes such a line, and 1 once the comment that says who added them has been written
    ENV_TOUCHED=0
    ENV_NOTED=0
    # 1 when Collie was installed before this run, so it may already run with the old settings
    WAS_INSTALLED=0
    # the terminal program Collie drives: herdr or herdr-core; empty until --mux, the one that is installed, or an answer
    MUX=
    # the command that runs herdr-core: hc, or herdr-core when only that name exists
    HC=hc
    # what Collie's .env says COLLIE_MUX is, and 1 when that has to change to the program picked here
    ENV_MUX=
    ENV_CHANGED=0
    # the numbered lines of the plan
    PLAN_N=0
    ASSUME_YES=0
    DRY_RUN=0
    # 1 when plain http inside the tailnet was asked for on the command line (--http) or agreed to at the question
    HTTP_OK=0
    # 1 once this run has added COLLIE_SERVE_MODE=http to Collie's .env
    SWITCHED=0
    # 1 once the terminal is open on file descriptor 3, so every answer comes from the next line of it
    TTY_OPEN=0
    # the file Collie reads its settings from (a standalone install; see the README for installs that Herdr manages)
    ENV_FILE=$HOME/.config/collie/.env
    WORK=
    # the real curl, and whether the progress wrapper in front of it is written (see make_curl_wrapper)
    REAL_CURL=
    WRAP_OK=0

    # ---- small helpers --------------------------------------------------------------------------------------------
    say() { printf '%s\n' "$*"; }
    warn() { printf 'warning: %s\n' "$*" >&2; }
    # die CODE MESSAGE...: print the message and stop with that exit code
    die() {
        code=$1
        shift
        printf 'error: %s\n' "$*" >&2
        exit "$code"
    }
    # shellcheck disable=SC2329  # called by the EXIT trap, which shellcheck cannot see
    cleanup() {
        if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
    }

    # ---- download progress ----------------------------------------------------------------------------------------
    # The installers download with a silent curl, so a slow connection looks like a hang. While they run, a small `curl` stands in
    # front of the real one (PATH points at it; the real one is named in DOGR_REAL_CURL). It hands every call to the real curl
    # unchanged and, when the call saves a file and the output is a terminal, draws "12.3 / 45.6 MB (27%)" from the size of the
    # file and the Content-Length that curl dumps with -D. Nothing is drawn into a log or a pipe, DOGR_PROGRESS=always forces it,
    # DOGR_PROGRESS=never switches it off, and a file under 1 MB is not worth a line (a script, a checksum).
    # make_curl_wrapper: write the wrapper into $WORK/bin. Progress is a nicety: when it cannot be set up the downloads stay quiet.
    make_curl_wrapper() {
        REAL_CURL=$(command -v curl) || return 1
        mkdir -p "$WORK/bin" || return 1
        cat >"$WORK/bin/curl" <<'WRAPPER' || return 1
#!/bin/sh
# Written by dogr's setup.sh for the time its installers run. Every call goes to the real curl unchanged; a download that saves
# a file on a terminal also gets a line "12.3 / 45.6 MB (27%)" while the file comes in.
real=${DOGR_REAL_CURL:-}
if [ -z "$real" ] || [ ! -x "$real" ]; then
    echo "dogr: the curl wrapper does not know the real curl." >&2
    exit 127
fi
mode=${DOGR_PROGRESS:-auto}
if [ "$mode" = never ] || { [ "$mode" != always ] && [ ! -t 2 ]; }; then
    exec "$real" "$@"
fi
# What is saved where: the word after -o, and the address that is fetched (either may come first).
out=
url=
next=
for arg in "$@"; do
    if [ -n "$next" ]; then
        out=$arg
        next=
        continue
    fi
    case $arg in
        -o | --output) next=1 ;;
        http://* | https://*) url=$arg ;;
    esac
done
case $out in
    "" | - | /dev/null) exec "$real" "$@" ;;
esac
[ -n "$url" ] || exec "$real" "$@"
hdr=${DOGR_WORK:-${TMPDIR:-/tmp}}/dl.$$.hdr
name=${out##*/}
start=$(date +%s 2>/dev/null || echo 0)
# The download runs in the background; this shell watches the file grow. The headers go to $hdr (-D) so the total is known
# without a second request.
"$real" -D "$hdr" "$@" <&0 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -f "$hdr"; exit 130' INT TERM
# size: bytes saved so far. total: the last Content-Length curl has seen (a redirect says 0 first), 0 when it is not told.
size() {
    cur=$(wc -c <"$out" 2>/dev/null) || cur=0
    cur=${cur##* }
    total=$(sed -n 's/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]: *\([0-9][0-9]*\).*/\1/p' "$hdr" 2>/dev/null | tail -n 1)
    : "${cur:=0}" "${total:=0}"
}
# draw: one line that replaces the one before; megabytes are millions of bytes, as Finder counts them.
draw() {
    now=$(date +%s 2>/dev/null || echo 0)
    awk -v c="$cur" -v t="$total" -v n="$name" -v s="$((now - start))" 'BEGIN {
        line = sprintf("  %s  %.1f", n, c / 1000000)
        if (t > 0) {
            p = c * 100 / t
            if (p > 100) p = 100
            line = line sprintf(" / %.1f MB  (%d%%)", t / 1000000, p)
        } else line = line " MB"
        if (s >= 2 && c > 0) line = line sprintf("  %.1f MB/s", c / s / 1000000)
        printf "\r%s\033[K", line
    }' >&2
}
while kill -0 "$pid" 2>/dev/null; do
    size
    if [ "$total" -ge 1000000 ] || [ "$cur" -ge 1000000 ]; then draw; fi
    sleep 0.2 2>/dev/null || sleep 1
done
wait "$pid"
rc=$?
# The last line stays on the screen, with what really came in.
size
if [ "$total" -ge 1000000 ] || [ "$cur" -ge 1000000 ]; then
    draw
    printf '\n' >&2
fi
rm -f "$hdr"
exit "$rc"
WRAPPER
        chmod +x "$WORK/bin/curl" || return 1
        WRAP_OK=1
    }
    # fetch URL FILE: save a file; the progress line is drawn when it is big.
    fetch() {
        if [ "$WRAP_OK" = 1 ]; then
            DOGR_REAL_CURL=$REAL_CURL DOGR_WORK=$WORK "$WORK/bin/curl" -fsSL "$1" -o "$2"
        else
            curl -fsSL "$1" -o "$2"
        fi
    }
    # run_installer SCRIPT [COLLIE_TAG]: run a downloaded installer with the progress curl in front of the real one. It must not
    # read our standard input: when this script itself comes through a pipe, it would eat it.
    run_installer() {
        # `env` sets the variables for the installer alone, so nothing leaks into the rest of this script.
        if [ "$WRAP_OK" = 1 ]; then
            if [ -n "${2:-}" ]; then
                env DOGR_REAL_CURL="$REAL_CURL" DOGR_WORK="$WORK" PATH="$WORK/bin:$PATH" COLLIE_TAG="$2" sh "$1" </dev/null
            else
                env DOGR_REAL_CURL="$REAL_CURL" DOGR_WORK="$WORK" PATH="$WORK/bin:$PATH" sh "$1" </dev/null
            fi
        elif [ -n "${2:-}" ]; then
            env COLLIE_TAG="$2" sh "$1" </dev/null
        else
            sh "$1" </dev/null
        fi
    }

    usage() {
        cat <<'EOF'
Usage: setup.sh [--tailscale | --tailcat [--derpmap-url URL] [--region NAME] | --iroh [--relay-url URL] | --proxy --url URL | --lan [--host ADDRESS]]
                [--mux herdr|herdr-core] [--http] [--yes] [--dry-run] [--help]

Puts Collie on this computer, sets it up for the way your phone reaches it, and shows a QR code that pairs your phone.
Without --tailscale, --tailcat, --iroh, --proxy or --lan the script asks which way you use.

  --tailscale   Your phone reaches this computer through Tailscale: Collie is published on your tailnet.
  --tailcat     Your phone reaches this computer through tailcat: an end-to-end encrypted tunnel with no account and no
                server of yours. The script installs tailcat, makes a saved key (its address then stays the same), runs
                'tailcat serve' as a background service of your own user, and puts the secret tailcat address into the QR code.
  --derpmap-url URL  tailcat: the https address of your own relay map instead of tailcat's default one. The phone needs the
                same address. Implies --tailcat.
  --region NAME  tailcat: the relay region for a new key (a name from 'tailcat genkey --region=list', or your own relay's
                host name). Without it the nearest one is picked once. Implies --tailcat.
  --iroh        Your phone reaches this computer through iroh: an end-to-end encrypted tunnel with no account and no server
                of yours, over n0's public relay servers (free, meant for development and testing, no promise of uptime) until
                the two find a direct path. The script installs dumbpipe, makes a saved secret key and a secret name (so the
                address then stays the same), runs 'dumbpipe listen-tcp' as a background service of your own user, and puts
                the secret iroh address into the QR code.
  --relay-url URL  iroh: the address of a relay server of your own (the open-source 'iroh-relay', or a paid one with its
                authentication switched off) instead of n0's public relays. https, or http on this computer or the local network.
                The phone needs the same address. No dumbpipe release has this option yet, so the script builds one from
                a pinned commit (needs Rust's cargo; a few minutes). Implies --iroh.
  --proxy       Your phone reaches this computer through your own domain, with a reverse proxy you run in front of Collie.
                Needs --url (or the script asks for it). The script sets Collie up behind the proxy; it does not set up
                the proxy, its certificate or who may reach it.
  --url URL     The https address of the reverse proxy, for example https://collie.example.com (no path). Implies --proxy.
  --lan         Your phone reaches this computer over the local network, with plain http and no encryption. Collie then
                answers to everything on that network. Use it at home only.
  --host ADDRESS  The address of this computer on the local network, for example 192.168.1.20. Implies --lan. Without it
                the script looks for one, and asks when there are several.
  --mux NAME    The terminal program Collie drives: herdr (the terminal app) or herdr-core (a background service). One
                that is missing is installed with its own installer. Without this option the script asks which one, and
                stops when there is no terminal to ask on. If Collie's .env names the other one, the plan says so and
                that line is replaced.
  --http        If your tailnet has no HTTPS certificates (Headscale, for one), publish Collie over plain http inside the
                tailnet instead. Tailscale still encrypts the traffic between your devices. This adds the line
                COLLIE_SERVE_MODE=http to Collie's .env. Without this option the script asks first, and with --yes
                and no terminal it stops instead of switching by itself.
  --yes, -y     Do not ask before changing anything.
  --dry-run     Show what would happen, change nothing, and stop.
  --help, -h    Show this text.
EOF
    }

    # set_route NAME: the way the phone reaches this computer. Only one at a time: a second, different one stops the script.
    set_route() {
        if [ -n "$ROUTE" ] && [ "$ROUTE" != "$1" ]; then
            usage >&2
            die 1 "choose one way for the phone to reach this computer: --tailscale, --tailcat, --iroh, --proxy or --lan (one way at a time)."
        fi
        ROUTE=$1
    }

    # have_tty: true when there is somewhere to read an answer from
    have_tty() { ( exec <"$TTY" ) 2>/dev/null; }

    # open_tty: open the terminal once on file descriptor 3, so each question reads the next line, also when the "terminal"
    # is a file in a test. Returns 1 when there is no terminal.
    open_tty() {
        have_tty || return 1
        if [ "$TTY_OPEN" != 1 ]; then
            exec 3<"$TTY"
            TTY_OPEN=1
        fi
    }

    # ask_yes_no QUESTION [DEFAULT]: ask on the terminal. DEFAULT is "y" (the default) or "n": what a bare Enter means.
    # Returns 0 for yes, 1 for no. No answer at all (the terminal closed, or Ctrl-D) counts as "no": nothing is changed on a guess.
    ask_yes_no() {
        open_tty || return 1
        if [ "${2:-y}" = n ]; then printf '%s [y/N] ' "$1" >&2; else printf '%s [Y/n] ' "$1" >&2; fi
        answer=
        IFS= read -r answer <&3 || return 1
        case $answer in
            '') [ "${2:-y}" = y ] ;;
            [Yy]*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # confirm QUESTION: like ask_yes_no, but --yes answers for you
    confirm() {
        if [ "$ASSUME_YES" = 1 ]; then return 0; fi
        have_tty || die 1 "there is no terminal to ask on. Run again with --yes to go ahead without asking."
        ask_yes_no "$1"
    }

    # retry COMMAND...: run it until it succeeds, at most $TRIES times, $DELAY seconds apart
    retry() {
        n=0
        while [ "$n" -lt "$TRIES" ]; do
            if "$@"; then return 0; fi
            n=$((n + 1))
            if [ "$n" -lt "$TRIES" ]; then sleep "$DELAY"; fi
        done
        return 1
    }

    # health_ok BASE_URL: true when Collie's health route answers "ok" there. It needs no token.
    # shellcheck disable=SC2329  # called through retry
    health_ok() {
        curl -fsS --max-time 5 "$1/api/health" 2>/dev/null </dev/null | grep -q '"ok":true'
    }

    # json_string JSON KEY: the text value of a flat key in one line of JSON, or nothing (also for null).
    json_string() {
        printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
    }

    # find_collie: put Collie on PATH when it is installed but its folder is not on PATH yet. Returns 1 when not installed.
    find_collie() {
        if command -v collie >/dev/null 2>&1; then return 0; fi
        for dir in "$HOME/.local/bin" "${COLLIE_DIR:-$HOME/.local/share/collie}/current/bin"; do
            if [ -x "$dir/collie" ]; then
                PATH="$dir:$PATH"
                export PATH
                return 0
            fi
        done
        return 1
    }

    # find_herdr: true when herdr (the terminal app) is installed; puts its folder on PATH when only ~/.local/bin has it.
    find_herdr() {
        if command -v herdr >/dev/null 2>&1; then return 0; fi
        if [ -x "$HOME/.local/bin/herdr" ]; then
            PATH="$HOME/.local/bin:$PATH"
            export PATH
            return 0
        fi
        return 1
    }

    # find_hc: true when herdr-core is installed. Sets HC to the command that runs it: hc, or herdr-core (the same program
    # under its other name; the installer only makes hc when no other hc is there).
    find_hc() {
        for name in hc herdr-core; do
            if command -v "$name" >/dev/null 2>&1; then
                HC=$name
                return 0
            fi
            if [ -x "$HOME/.local/bin/$name" ]; then
                PATH="$HOME/.local/bin:$PATH"
                export PATH
                HC=$name
                return 0
            fi
        done
        return 1
    }

    # find_mux: find_herdr or find_hc, for the program picked in $MUX
    find_mux() {
        if [ "$MUX" = herdr ]; then find_herdr; else find_hc; fi
    }

    # ask_mux: ask which terminal program Collie should drive and set MUX. Stops (exit 1) on an answer that is none of them.
    ask_mux() {
        open_tty || die 1 "there is no terminal to ask on. Run again with --mux herdr or --mux herdr-core."
        # Say which of the two is installed already, so the answer is an informed one.
        mark_herdr=
        mark_hc=
        if [ "$have_herdr" = 1 ]; then mark_herdr="  (installed)"; fi
        if [ "$have_hc" = 1 ]; then mark_hc="  (installed)"; fi
        {
            printf '%s\n' "Which terminal program should Collie drive?"
            printf '%s\n' "  1) herdr       the terminal app: you open it in a terminal and your agents run inside it$mark_herdr"
            printf '%s\n' "  2) herdr-core  a background service: no terminal app to open$mark_hc"
            printf '%s' "Enter 1 or 2: "
        } >&2
        answer=
        IFS= read -r answer <&3 || die 1 "no answer. Run again with --mux herdr or --mux herdr-core."
        case $answer in
            1 | herdr) MUX=herdr ;;
            2 | herdr-core) MUX=herdr-core ;;
            *) die 1 "'$answer' is not 1 or 2. Run again with --mux herdr or --mux herdr-core." ;;
        esac
    }

    # env_get KEY: the value of the last KEY line in Collie's .env (an optional leading "export", quotes and a trailing
    # comment are dropped), or nothing
    env_get() {
        [ -f "$ENV_FILE" ] || return 0
        sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}'"$1"'=//p' "$ENV_FILE" | tail -n 1 |
            sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
    }

    # env_mux: the terminal program Collie's .env names, or nothing
    env_mux() { env_get COLLIE_MUX; }

    # env_set KEY VALUE: make Collie's .env say KEY=VALUE. A KEY line that is there is replaced where it stands: Collie keeps
    # that file as its own record and reads it before the environment, so a second line further down would lose to the first.
    # A missing one is added at the end, under one comment that says who added it. The file is written through cat, so its
    # owner and mode stay; a new file is private to the user, as it may hold settings that are not for others. VALUE has
    # only the characters that the checks of each route let through, so it is safe inside the sed command.
    env_set() {
        if [ -f "$ENV_FILE" ] && grep -q "^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=" "$ENV_FILE"; then
            tmp=$WORK/env.new
            sed 's|^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}'"$1"'=.*$|'"$1=$2"'|' "$ENV_FILE" >"$tmp" || return 1
            cat "$tmp" >"$ENV_FILE"
            return
        fi
        mkdir -p "${ENV_FILE%/*}" || return 1
        if [ "$ENV_NOTED" != 1 ]; then
            (
                umask 077
                printf '\n# Added by dogr setup.sh (%s).\n' "$ROUTE" >>"$ENV_FILE"
            ) || return 1
            ENV_NOTED=1
        fi
        (
            umask 077
            printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
        )
    }

    # want KEY VALUE: this route needs KEY=VALUE in Collie's .env
    want() { WANT="$WANT $1=$2"; }

    # plan_settings: the plan line for the settings of this route, with one line for each that is not in the .env yet
    # (add) or has another value there (change). Sets ENV_TOUCHED to 1 when there is any.
    plan_settings() {
        lines=
        for pair in $WANT; do
            key=${pair%%=*}
            value=${pair#*=}
            cur=$(env_get "$key")
            if [ -z "$cur" ]; then
                lines="$lines      add     $key=$value
"
                ENV_TOUCHED=1
            elif [ "$cur" != "$value" ]; then
                lines="$lines      change  $key from $cur to $value
"
                ENV_TOUCHED=1
            fi
        done
        if [ "$ENV_TOUCHED" = 1 ]; then
            plan "Put these settings into $ENV_FILE (Collie reads that file before your environment):"
            printf '%s' "$lines"
        else
            plan "The settings this needs are in $ENV_FILE already."
        fi
    }

    # apply_settings: write what plan_settings listed
    apply_settings() {
        for pair in $WANT; do
            key=${pair%%=*}
            value=${pair#*=}
            [ "$(env_get "$key")" = "$value" ] && continue
            env_set "$key" "$value" || die 3 "could not write $ENV_FILE"
            # The tailcat and iroh addresses are secrets, so the line is shown without them.
            shown=$value
            if [ "$ROUTE" = tailcat ] && [ "$key" = COLLIE_PUBLIC_URL ]; then shown="$TC_BASE/<your tailcat address>"; fi
            if [ "$ROUTE" = iroh ] && [ "$key" = COLLIE_PUBLIC_URL ]; then shown="$IR_BASE/<your iroh address>"; fi
            say "  $ENV_FILE: $key=$shown"
        done
    }

    # ask_line PROMPT: ask for a line of text on the terminal and put it, trimmed, in ANSWER. Returns 1 when there is no answer.
    ask_line() {
        open_tty || return 1
        printf '%s' "$1" >&2
        ANSWER=
        IFS= read -r ANSWER <&3 || return 1
        ANSWER=$(printf '%s' "$ANSWER" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    }

    # ask_other_route: the answer to the first question was "no": ask which of the other ways it is.
    ask_other_route() {
        {
            printf '%s\n' "How does your phone reach this computer, then?"
            printf '%s\n' "  1) through tailcat: an encrypted tunnel with no account, no server and no open port"
            printf '%s\n' "  2) through your own domain, with a reverse proxy you run in front of Collie (HTTPS)"
            printf '%s\n' "  3) over the local network, with plain http and no encryption"
            printf '%s\n' "  4) through iroh: also an encrypted tunnel with no account, no server and no open port (n0's free public relays)"
            printf '%s' "Enter 1, 2, 3 or 4: "
        } >&2
        answer=
        IFS= read -r answer <&3 || die 1 "no answer. Run again with --tailcat, --iroh, --proxy or --lan."
        case $answer in
            1 | tailcat) ROUTE=tailcat ;;
            2 | proxy) ROUTE=proxy ;;
            3 | lan) ROUTE=lan ;;
            4 | iroh) ROUTE=iroh ;;
            *) die 1 "'$answer' is not 1, 2, 3 or 4. Run again with --tailcat, --iroh, --proxy or --lan." ;;
        esac
    }

    # check_leftovers: the Tailscale route needs Collie to publish itself. Settings that an earlier proxy or local network run
    # left in the .env would stop that, so the script stops and names them. Nothing is deleted on a guess.
    check_leftovers() {
        left=
        if [ "$(env_get COLLIE_SKIP_SERVE)" = 1 ]; then left="$left COLLIE_SKIP_SERVE"; fi
        case $(env_get COLLIE_HOST) in
            '' | 127.0.0.1 | localhost | ::1) ;;
            *) left="$left COLLIE_HOST" ;;
        esac
        [ -n "$left" ] || return 0
        say "$ENV_FILE has settings of another way to reach this computer, which keep Collie from publishing itself on Tailscale:$left"
        say "Delete these lines from that file (an earlier --proxy or --lan run added them): COLLIE_SKIP_SERVE, COLLIE_HOST,"
        say "COLLIE_ALLOW_NON_LOOPBACK_BIND, COLLIE_PUBLIC_HOSTS, COLLIE_ALLOWED_ORIGINS, COLLIE_PUBLIC_URL. Then run this command again."
        exit 3
    }

    # resolve_proxy: the public address of the reverse proxy, from --url or asked for, checked, and the settings it needs
    resolve_proxy() {
        if [ -z "$PROXY_URL" ]; then
            have_tty || die 1 "there is no terminal to ask for the public address. Run again with --url https://... (for example --url https://collie.example.com)."
            ask_line "The public address your phone will use, for example https://collie.example.com: " || die 1 "no answer. Run again with --url https://..."
            PROXY_URL=$ANSWER
        fi
        case $PROXY_URL in
            https://*) ;;
            *) die 1 "the address must start with https:// (your reverse proxy ends the encryption in front of Collie): $PROXY_URL" ;;
        esac
        rest=${PROXY_URL#https://}
        rest=${rest%/}
        case $rest in
            '') die 1 "the address has no host name: $PROXY_URL" ;;
            */*) die 1 "the address must not have a path, Collie does not live in a sub-folder: $PROXY_URL" ;;
            *@*) die 1 "the address must not have a user name in it: $PROXY_URL" ;;
            [!A-Za-z0-9]* | *[!A-Za-z0-9.:_-]*) die 1 "that is not a host name with an optional port: $PROXY_URL" ;;
        esac
        # Port 443 is the one https uses without saying so, and the Host header then carries no port.
        case $rest in *:443) rest=${rest%:443} ;; esac
        PUBLIC_HOST=$rest
        PUBLIC_URL=https://$rest
        want COLLIE_SKIP_SERVE 1
        want COLLIE_PUBLIC_HOSTS "$PUBLIC_HOST"
        want COLLIE_ALLOWED_ORIGINS "$PUBLIC_URL"
        want COLLIE_PUBLIC_URL "$PUBLIC_URL"
        # Behind a proxy Collie answers on loopback. A wide bind left by an earlier --lan run has to go back.
        case $(env_get COLLIE_HOST) in
            '' | 127.0.0.1 | localhost | ::1) ;;
            *) want COLLIE_HOST 127.0.0.1 ;;
        esac
    }

    # valid_ipv4 TEXT: true for four numbers up to 255 separated by dots
    valid_ipv4() {
        case $1 in
            '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
        esac
        oldifs=$IFS
        IFS=.
        # shellcheck disable=SC2086  # splitting at the dots is the point; the text has only digits and dots
        set -- $1
        IFS=$oldifs
        [ $# = 4 ] || return 1
        for octet in "$@"; do
            [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
        done
    }

    # lan_addresses: one "interface address" line for each address of this computer that a phone on the same network can
    # reach: private IPv4 ranges only, and not those of Tailscale, Docker, virtual machines and the like.
    lan_addresses() {
        if command -v ip >/dev/null 2>&1; then
            ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print $2, a[1] }'
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig 2>/dev/null | awk '/^[A-Za-z0-9_.-]+:/ { i = $1; sub(":", "", i) } $1 == "inet" { print i, $2 }'
        fi | awk '
            $1 ~ /^(lo|utun|tailscale|ts|docker|veth|br-|virbr|vmnet|vboxnet|bridge|zt|wg|tun|tap|llw|awdl)/ { next }
            $2 ~ /^10\./ || $2 ~ /^192\.168\./ || $2 ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ { print }'
    }

    # resolve_lan: this computer's address on the local network, from --host, or found (and asked for when there are several),
    # and the settings that route needs
    resolve_lan() {
        if [ -n "$LAN_HOST" ]; then
            valid_ipv4 "$LAN_HOST" || die 1 "--host needs an address like 192.168.1.20 (four numbers, no name, no port): $LAN_HOST"
        else
            found=$(lan_addresses)
            count=$(printf '%s\n' "$found" | grep -c .)
            if [ "$count" = 0 ]; then
                die 3 "no local-network address was found on this computer. Connect to your Wi-Fi or network, or give the address with --host ADDRESS."
            elif [ "$count" = 1 ]; then
                LAN_HOST=${found##* }
                say "This computer's address on the local network: $LAN_HOST (${found%% *})"
            else
                say "This computer has more than one address on a local network:"
                n=0
                printf '%s\n' "$found" | while read -r iface addr; do
                    n=$((n + 1))
                    say "  $n) $addr  ($iface)"
                done
                if ! open_tty; then
                    die 1 "there is no terminal to choose one on. Run again with --host ADDRESS, naming the one your phone can reach."
                fi
                printf '%s' "Which one can your phone reach? Enter its number: " >&2
                answer=
                IFS= read -r answer <&3 || die 1 "no answer. Run again with --host ADDRESS."
                case $answer in
                    '' | *[!0-9]*) die 1 "'$answer' is not one of the numbers above. Run again with --host ADDRESS." ;;
                esac
                if [ "$answer" -lt 1 ] || [ "$answer" -gt "$count" ]; then
                    die 1 "'$answer' is not one of the numbers above. Run again with --host ADDRESS."
                fi
                LAN_HOST=$(printf '%s\n' "$found" | sed -n "${answer}p" | sed 's/^[^ ]* //')
            fi
        fi
        PUBLIC_HOST=$LAN_HOST:$PORT
        PUBLIC_URL=http://$PUBLIC_HOST
        want COLLIE_HOST "$LAN_HOST"
        want COLLIE_ALLOW_NON_LOOPBACK_BIND 1
        want COLLIE_SKIP_SERVE 1
        want COLLIE_PUBLIC_HOSTS "$PUBLIC_HOST"
        want COLLIE_ALLOWED_ORIGINS "$PUBLIC_URL"
        want COLLIE_PUBLIC_URL "$PUBLIC_URL"
    }

    # find_tailcat: true when tailcat is installed; puts ~/.local/bin on PATH when only that folder has it. There is no search
    # of other folders: Homebrew's folder is on PATH for whoever has Homebrew.
    find_tailcat() {
        if command -v tailcat >/dev/null 2>&1; then return 0; fi
        if [ -x "$HOME/.local/bin/tailcat" ]; then
            PATH="$HOME/.local/bin:$PATH"
            export PATH
            return 0
        fi
        return 1
    }

    # tailcat_has_key: true when the saved key named $TC_KEY exists (needs tailcat)
    tailcat_has_key() {
        tailcat genkey --list 2>/dev/null </dev/null | grep -qx "$TC_KEY"
    }

    # resolve_tailcat: check --derpmap-url, and the settings this route needs. COLLIE_PUBLIC_URL has to carry the tailcat address,
    # which only exists once the service runs, so that one line is added later (setup_tailcat).
    resolve_tailcat() {
        if [ -n "$DERP_URL" ]; then
            case $DERP_URL in
                https://*) ;;
                *) die 1 "the relay map address must start with https://: $DERP_URL" ;;
            esac
            case ${DERP_URL#https://} in
                '' | [!A-Za-z0-9]*) die 1 "that is not a relay map address (it needs a host name): $DERP_URL" ;;
                *@*) die 1 "the relay map address must not have a user name in it: $DERP_URL" ;;
                *[!A-Za-z0-9._~:/?=\&#+,-]*) die 1 "the relay map address has characters this script does not pass on to a service file: $DERP_URL" ;;
            esac
        fi
        # The phone's own Host header names its end of the tunnel, 127.0.0.1 with a port of its own, whatever the port here is.
        TC_BASE=http://tailcat.invalid
        if [ "$PORT" != 8787 ]; then TC_BASE=$TC_BASE:$PORT; fi
        want COLLIE_SKIP_SERVE 1
        want COLLIE_PUBLIC_HOSTS "127.0.0.1:$PORT"
        case $(env_get COLLIE_HOST) in
            '' | 127.0.0.1 | localhost | ::1) ;;
            *) want COLLIE_HOST 127.0.0.1 ;;
        esac
    }

    # tailcat_arch: the processor name the release files use, in TC_ARCH. Stops (exit 5) when there is no release for this one,
    # which the plan already says, before anything is changed.
    tailcat_arch() {
        case $(uname -m) in
            x86_64 | amd64) TC_ARCH=amd64 ;;
            aarch64 | arm64) TC_ARCH=arm64 ;;
            armv7l | armv7) TC_ARCH=armv7 ;;
            *) die 5 "there is no tailcat release for this processor ($(uname -m))." ;;
        esac
    }

    # plan_tailcat: the plan lines for installing tailcat, the key and the service
    plan_tailcat() {
        if find_tailcat; then
            plan "tailcat is already installed ($(tailcat version 2>/dev/null </dev/null | head -n 1)); it is left as it is."
        elif [ "$(uname -s)" = Darwin ]; then
            plan "Install tailcat with Homebrew ('brew install tailcat'). Homebrew is the only way on a Mac: the releases have no Mac file."
        else
            tailcat_arch
            plan "Install tailcat $TC_VERSION: download $TC_RELEASE_URL/tailcat_${TC_VERSION}_linux_$TC_ARCH.tar.gz, check it against the release's checksums.txt, and put the program into ~/.local/bin."
        fi
        if find_tailcat && tailcat_has_key; then
            plan "Use the saved tailcat key named '$TC_KEY': its address is the same as last time."
        else
            plan "Make a saved tailcat key named '$TC_KEY' (it is kept, so the tailcat address stays the same after a restart)."
        fi
        if [ "$(uname -s)" = Darwin ]; then
            plan "Run 'tailcat serve' for port $PORT as a background service of your own user (launchd: ~/Library/LaunchAgents/dev.dogr.tailcat.plist, log ~/.local/state/dogr/tailcat.log). It starts again at every login."
        else
            plan "Run 'tailcat serve' for port $PORT as a background service of your own user (systemd --user: ~/.config/systemd/user/dogr-tailcat.service, log ~/.local/state/dogr/tailcat.log)."
        fi
    }

    # install_tailcat: put tailcat on this computer. macOS: Homebrew. Linux: the release file, checked against the release's checksum file.
    install_tailcat() {
        say ""
        say "==> Installing tailcat"
        if [ "$(uname -s)" = Darwin ]; then
            command -v brew >/dev/null 2>&1 || die 5 "tailcat has no download for macOS, and Homebrew was not found. Install Homebrew (https://brew.sh) and run this command again, or install tailcat yourself and run it again."
            brew install tailcat </dev/null || die 5 "'brew install tailcat' failed. Its output is above."
        else
            tailcat_arch
            tc_file=tailcat_${TC_VERSION}_linux_$TC_ARCH.tar.gz
            fetch "$TC_RELEASE_URL/$tc_file" "$WORK/$tc_file" || die 5 "could not download $TC_RELEASE_URL/$tc_file"
            fetch "$TC_RELEASE_URL/checksums.txt" "$WORK/checksums.txt" || die 5 "could not download $TC_RELEASE_URL/checksums.txt"
            tc_want=$(awk -v f="$tc_file" '$2 == f { print $1 }' "$WORK/checksums.txt" | head -n 1)
            [ -n "$tc_want" ] || die 5 "the checksum file does not list $tc_file, so the download cannot be checked."
            tc_got=$(sha256_of "$WORK/$tc_file")
            [ -n "$tc_got" ] || die 5 "neither sha256sum nor shasum was found, so the download cannot be checked."
            [ "$tc_got" = "$tc_want" ] || die 5 "the checksum of $tc_file does not match the release's checksums.txt. Nothing was installed."
            mkdir -p "$WORK/tailcat-files" "$HOME/.local/bin" || die 5 "could not make $HOME/.local/bin"
            tar -xzf "$WORK/$tc_file" -C "$WORK/tailcat-files" tailcat || die 5 "could not unpack $tc_file"
            cp "$WORK/tailcat-files/tailcat" "$HOME/.local/bin/tailcat" || die 5 "could not copy tailcat into $HOME/.local/bin"
            chmod +x "$HOME/.local/bin/tailcat"
        fi
        find_tailcat || die 5 "tailcat was installed but its command was not found. Add ~/.local/bin to your PATH and run this command again."
        say "  $(tailcat version 2>/dev/null </dev/null | head -n 1)"
    }

    # make_tailcat_key: make the saved key unless it is there. The region is baked into the key, and so into the address, which
    # keeps the address the same. Picking the nearest region sometimes fails, so it is tried three times.
    make_tailcat_key() {
        if tailcat_has_key; then
            say "  using the saved key '$TC_KEY'"
            if [ -n "$TC_REGION" ] || [ -n "$DERP_URL" ]; then
                say "  The key exists already, so its relay region is kept. To change it: tailcat genkey --delete --key=$TC_KEY, then run this again."
            fi
            return 0
        fi
        set -- genkey "--key=$TC_KEY"
        if [ -n "$DERP_URL" ]; then set -- "$@" "--derpmap-url=$DERP_URL"; fi
        if [ -n "$TC_REGION" ]; then
            set -- "$@" "--region=$TC_REGION"
            tailcat "$@" </dev/null >/dev/null 2>"$WORK/genkey.err" || {
                cat "$WORK/genkey.err" >&2
                die 4 "could not make the tailcat key. See 'tailcat genkey --region=list' for names that work with --region."
            }
        else
            set -- "$@" --fixed-region
            tc_try=0
            while :; do
                tc_try=$((tc_try + 1))
                if tailcat "$@" </dev/null >/dev/null 2>"$WORK/genkey.err"; then break; fi
                if [ "$tc_try" -ge 3 ]; then
                    cat "$WORK/genkey.err" >&2
                    die 4 "could not pick a relay region for the tailcat key. Run this command again with --region NAME (see 'tailcat genkey --region=list')."
                fi
                sleep "$DELAY"
            done
        fi
        say "  made the saved key '$TC_KEY'"
    }

    # read_tailcat_address: the address of the running service, from the last "tc..." word its log prints. The character before it
    # must not be an address character, or the match could start in the middle of the address.
    # shellcheck disable=SC2329  # called through retry
    read_tailcat_address() {
        TC_ADDRESS=$(sed -n 's/.*[^A-Za-z0-9_-]\(tc[A-Za-z0-9_-]\{100,\}\).*/\1/p' "$TC_LOG" 2>/dev/null | tail -n 1)
        [ -n "$TC_ADDRESS" ]
    }

    # start_tailcat_service: write the service file for this system and (re)start the service with a fresh log, so an address
    # from an earlier run is never taken for the new one.
    start_tailcat_service() {
        TC_BIN=$(command -v tailcat)
        (
            umask 077
            mkdir -p "${TC_LOG%/*}" && : >"$TC_LOG"
        ) || die 4 "could not make the log ($TC_LOG)."
        if [ "$(uname -s)" = Darwin ]; then
            tc_plist=$HOME/Library/LaunchAgents/dev.dogr.tailcat.plist
            mkdir -p "${tc_plist%/*}" || die 4 "could not make ${tc_plist%/*}"
            # The values go into XML, so & and < are written the XML way.
            tc_xml_log=$(printf '%s' "$TC_LOG" | sed 's/&/\&amp;/g; s/</\&lt;/g')
            tc_xml_bin=$(printf '%s' "$TC_BIN" | sed 's/&/\&amp;/g; s/</\&lt;/g')
            {
                printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
                printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                printf '%s\n' '<plist version="1.0">' '<dict>'
                printf '%s\n' '  <key>Label</key><string>dev.dogr.tailcat</string>' '  <key>ProgramArguments</key>' '  <array>'
                printf '    <string>%s</string>\n' "$tc_xml_bin" serve "--key=$TC_KEY"
                if [ -n "$DERP_URL" ]; then printf '    <string>%s</string>\n' "--derpmap-url=$(printf '%s' "$DERP_URL" | sed 's/&/\&amp;/g')"; fi
                printf '    <string>%s</string>\n' "$PORT"
                printf '%s\n' '  </array>' '  <key>RunAtLoad</key><true/>' '  <key>KeepAlive</key><true/>'
                printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$tc_xml_log"
                printf '  <key>StandardOutPath</key><string>%s</string>\n' "$tc_xml_log"
                printf '%s\n' '  <key>ProcessType</key><string>Background</string>' '</dict>' '</plist>'
            } >"$tc_plist" || die 4 "could not write $tc_plist"
            tc_uid=$(id -u)
            # An older run's service is stopped first so the new file is the one that counts. That fails when none runs, which is fine.
            launchctl bootout "gui/$tc_uid/dev.dogr.tailcat" >/dev/null 2>&1 </dev/null || :
            retry launchctl bootstrap "gui/$tc_uid" "$tc_plist" </dev/null || die 4 "'launchctl bootstrap' could not start the tailcat service ($tc_plist). Is this a login session of your own user?"
        else
            tc_unit=$HOME/.config/systemd/user/dogr-tailcat.service
            mkdir -p "${tc_unit%/*}" || die 4 "could not make ${tc_unit%/*}"
            {
                printf '%s\n' '[Unit]' 'Description=tailcat tunnel for Collie (dogr setup.sh)' '' '[Service]'
                tc_exec="\"$TC_BIN\" serve --key=$TC_KEY"
                if [ -n "$DERP_URL" ]; then tc_exec="$tc_exec --derpmap-url=$DERP_URL"; fi
                printf 'ExecStart=%s %s\n' "$tc_exec" "$PORT"
                printf '%s\n' 'Restart=always' 'RestartSec=5'
                printf 'StandardError=append:%s\n' "$TC_LOG"
                printf 'StandardOutput=append:%s\n' "$TC_LOG"
                printf '%s\n' '' '[Install]' 'WantedBy=default.target'
            } >"$tc_unit" || die 4 "could not write $tc_unit"
            systemctl --user daemon-reload </dev/null || die 4 "'systemctl --user daemon-reload' failed. Is there a systemd user session (are you logged in on this computer)?"
            systemctl --user enable dogr-tailcat.service </dev/null || die 4 "'systemctl --user enable' failed for the tailcat service ($tc_unit)."
            systemctl --user restart dogr-tailcat.service </dev/null || die 4 "'systemctl --user restart' could not start the tailcat service ($tc_unit). 'journalctl --user -u dogr-tailcat' says why."
        fi
    }

    # setup_tailcat: install tailcat, make the key, run the service, read the address it prints, and add COLLIE_PUBLIC_URL with
    # it to the settings that apply_settings writes next.
    setup_tailcat() {
        if ! find_tailcat; then install_tailcat; fi
        say ""
        say "==> Making sure the tailcat key and service are there"
        make_tailcat_key
        start_tailcat_service
        retry read_tailcat_address || die 4 "the tailcat service runs but printed no address. $TC_LOG should have a line with it; 'tailcat' errors end up there."
        say "  the service runs; its address is secret and is not shown here (it is in the QR code below)"
        PUBLIC_URL=$TC_BASE/$TC_ADDRESS
        want COLLIE_PUBLIC_URL "$PUBLIC_URL"
        if [ "$(env_get COLLIE_PUBLIC_URL)" != "$PUBLIC_URL" ]; then ENV_TOUCHED=1; fi
    }

    # sha256_of FILE: the SHA-256 of a file as 64 hex characters; nothing when the computer has neither sha256sum nor shasum
    sha256_of() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{ print $1 }'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" | awk '{ print $1 }'
        fi
    }

    # sq TEXT: TEXT as one single-quoted shell word, for a line of the runner script that is written to a file
    sq() {
        printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    }

    # random_hex N: N random bytes as 2N hex characters
    random_hex() {
        head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
    }

    # iroh_id_of TICKET: the endpoint id (64 hex characters) inside a dumbpipe ticket, which is the word "endpoint" and then
    # base32 letters. The first byte of the decoded ticket is 0 and the next 32 bytes are the id; anything else is a ticket this
    # does not understand, and nothing is printed. Plain awk, because the computers this runs on may have no base32 tool, and
    # the openssl of a Mac (LibreSSL) cannot derive the id from the key.
    iroh_id_of() {
        printf '%s\n' "$1" | awk '
            {
                t = tolower($0)
                sub(/^endpoint/, "", t)
                letters = "abcdefghijklmnopqrstuvwxyz234567"
                bits = ""
                for (i = 1; i <= 53 && i <= length(t); i++) {
                    v = index(letters, substr(t, i, 1)) - 1
                    if (v < 0) exit
                    for (b = 4; b >= 0; b--) bits = bits (int(v / 2 ^ b) % 2)
                }
                if (length(bits) < 264 || substr(bits, 1, 8) != "00000000") exit
                hex = ""
                for (k = 9; k < 265; k += 4) {
                    n = 0
                    for (j = 0; j < 4; j++) n = n * 2 + substr(bits, k + j, 1)
                    hex = hex substr("0123456789abcdef", n + 1, 1)
                }
                print hex
            }'
    }

    # dumbpipe_ok PROGRAM: true when that dumbpipe suits the phone: 0.40.1 or newer (older ones speak an older iroh that the
    # phone's library cannot talk to) and with --custom-alpn, which the secret name needs
    dumbpipe_ok() {
        ir_v=$("$1" --version 2>/dev/null </dev/null | head -n 1 | sed -n 's/^dumbpipe \([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p')
        [ -n "$ir_v" ] || return 1
        printf '%s\n' "$ir_v" | awk '{ exit !($1 > 0 || $2 > 40 || ($2 == 40 && $3 >= 1)) }' || return 1
        "$1" listen-tcp --help 2>&1 </dev/null | grep -q -e '--custom-alpn'
    }

    # dumbpipe_relay_ok PROGRAM: true when that dumbpipe also has the --relay option (a relay server of your own)
    dumbpipe_relay_ok() {
        "$1" listen-tcp --help 2>&1 </dev/null | grep -q -e '--relay <'
    }

    # find_dumbpipe: true when a usable dumbpipe is installed; its path is then in IR_BIN. One that is too old is passed over,
    # and the script installs its own into ~/.local/bin and uses that by its full path.
    find_dumbpipe() {
        for ir_try in "$(command -v dumbpipe 2>/dev/null)" "$HOME/.local/bin/dumbpipe" "$IR_DIR/bin/dumbpipe"; do
            if [ -n "$ir_try" ] && [ -x "$ir_try" ] && dumbpipe_ok "$ir_try"; then
                # With a relay asked for, one without the --relay option does not do; the one built here has it.
                if [ -n "$IR_RELAY" ] && ! dumbpipe_relay_ok "$ir_try"; then continue; fi
                IR_BIN=$ir_try
                return 0
            fi
        done
        return 1
    }

    # check_iroh_relay: stop (exit 1) unless IR_RELAY is a relay address this script can pass on. https, or http for this computer
    # and the local network, where a certificate is rarely to be had; no user name, no query, and only characters that are safe to
    # put into the small script the service runs. The phone needs the same address (the app's command carries it).
    check_iroh_relay() {
        [ -n "$IR_RELAY" ] || return 0
        case $IR_RELAY in
            https://*) ir_rest=${IR_RELAY#https://} ;;
            http://*)
                ir_rest=${IR_RELAY#http://}
                case ${ir_rest%%[:/]*} in
                    localhost | 127.* | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | *.local | ::1) ;;
                    *) die 1 "plain http is allowed for a relay on this computer or the local network only; use https://: $IR_RELAY" ;;
                esac
                ;;
            *) die 1 "the relay address must start with https://: $IR_RELAY" ;;
        esac
        case $ir_rest in
            '' | [!A-Za-z0-9]*) die 1 "that is not a relay address (it needs a host name): $IR_RELAY" ;;
            *@*) die 1 "the relay address must not have a user name in it: $IR_RELAY" ;;
            *[?#]*) die 1 "the relay address must not have a query or a fragment: $IR_RELAY" ;;
            *[!A-Za-z0-9._~:/+-]*) die 1 "the relay address has characters this script does not pass on to a service file: $IR_RELAY" ;;
        esac
    }

    # resolve_iroh: the settings this route needs. COLLIE_PUBLIC_URL has to carry the iroh address, which needs the saved key, so
    # that one line is added later (setup_iroh). The phone reaches Collie at 127.0.0.1 on a port of its own, like with tailcat.
    resolve_iroh() {
        check_iroh_relay
        IR_BASE=http://iroh.invalid
        want COLLIE_SKIP_SERVE 1
        want COLLIE_PUBLIC_HOSTS "127.0.0.1:$PORT"
        case $(env_get COLLIE_HOST) in
            '' | 127.0.0.1 | localhost | ::1) ;;
            *) want COLLIE_HOST 127.0.0.1 ;;
        esac
    }

    # iroh_release: the dumbpipe release file this computer takes (IR_FILE) and the SHA-256 it must have (IR_SUM). The sums are
    # the digests GitHub shows for the files of release v0.40.1; the release has no checksum file of its own. Stops (exit 5)
    # when there is no release for this computer, which the plan already says, before anything is changed.
    iroh_release() {
        case $(uname -s) in
            Darwin) ir_os=darwin ;;
            *) ir_os=linux ;;
        esac
        case $(uname -m) in
            x86_64 | amd64) ir_arch=x86_64 ;;
            aarch64 | arm64) ir_arch=aarch64 ;;
            *) die 5 "there is no dumbpipe release for this processor ($(uname -m))." ;;
        esac
        IR_FILE=dumbpipe-v$IR_VERSION-$ir_os-$ir_arch.tar.gz
        case $ir_os-$ir_arch in
            darwin-aarch64) IR_SUM=e6bd3c9a98ba22e8233ae1f8ba5e2dceb4cbf132dc4d4332589295b702902a27 ;;
            darwin-x86_64) IR_SUM=eaa35e228528cbf5fc2a8a07646570f49af6ab1acd35c8f539f150a0cb5d4b0e ;;
            linux-aarch64) IR_SUM=1529c49598ac15d9413bf7f29a09c04cf2f5dc3af1b9080a1b50855a77846c47 ;;
            linux-x86_64) IR_SUM=66aee1e249890ee63678dfc8f18ce3671e691673c83bbd72bf9a54c4d32da85c ;;
        esac
        if [ -n "${DOGR_DUMBPIPE_SHA256:-}" ]; then IR_SUM=$DOGR_DUMBPIPE_SHA256; fi
    }

    # iroh_keys_saved: true when the saved secret key and the secret name are both there and well formed
    iroh_keys_saved() {
        grep -qx '[0-9a-f]\{64\}' "$IR_DIR/secret" 2>/dev/null && grep -qx '[0-9a-f]\{32\}' "$IR_DIR/alpn" 2>/dev/null
    }

    # plan_iroh: the plan lines for installing dumbpipe, the saved keys and the service
    plan_iroh() {
        if find_dumbpipe; then
            plan "dumbpipe is already installed ($("$IR_BIN" --version 2>/dev/null </dev/null | head -n 1)); it is left as it is."
        elif [ -n "$IR_RELAY" ]; then
            plan "Build a dumbpipe that can use your own relay server: 'cargo install' of $IR_GIT at commit $IR_REV into ~/.config/dogr/iroh/bin (needs Rust's cargo; takes a few minutes). The released dumbpipe has no such option yet."
        else
            iroh_release
            plan "Install dumbpipe $IR_VERSION: download $IR_RELEASE_URL/$IR_FILE, check it against the SHA-256 this script carries, and put the program into ~/.local/bin."
        fi
        if [ -n "$IR_RELAY" ]; then
            plan "Make dumbpipe use the relay server $IR_RELAY instead of n0's public relays (your phone must be given the same address)."
        fi
        if iroh_keys_saved; then
            plan "Use the secret key and the secret name saved in ~/.config/dogr/iroh: the iroh address is the same as last time."
        else
            plan "Make a secret key and a secret name in ~/.config/dogr/iroh (private to you; they are kept, so the iroh address stays the same after a restart)."
        fi
        if [ "$(uname -s)" = Darwin ]; then
            plan "Run 'dumbpipe listen-tcp' for port $PORT as a background service of your own user (launchd: ~/Library/LaunchAgents/dev.dogr.iroh.plist, log ~/.local/state/dogr/iroh.log). It starts again at every login."
        else
            plan "Run 'dumbpipe listen-tcp' for port $PORT as a background service of your own user (systemd --user: ~/.config/systemd/user/dogr-iroh.service, log ~/.local/state/dogr/iroh.log)."
        fi
    }

    # install_dumbpipe: download the pinned release, check its SHA-256, and put the program into ~/.local/bin
    install_dumbpipe() {
        say ""
        say "==> Installing dumbpipe"
        iroh_release
        fetch "$IR_RELEASE_URL/$IR_FILE" "$WORK/$IR_FILE" || die 5 "could not download $IR_RELEASE_URL/$IR_FILE"
        ir_got=$(sha256_of "$WORK/$IR_FILE")
        [ -n "$ir_got" ] || die 5 "neither sha256sum nor shasum was found, so the download cannot be checked."
        [ "$ir_got" = "$IR_SUM" ] || die 5 "the checksum of $IR_FILE is not the one this script carries for dumbpipe $IR_VERSION. Nothing was installed."
        mkdir -p "$WORK/dumbpipe-files" "$HOME/.local/bin" || die 5 "could not make $HOME/.local/bin"
        # The whole archive is unpacked: its one file is stored as ./dumbpipe, a name that tar does not match against "dumbpipe".
        tar -xzf "$WORK/$IR_FILE" -C "$WORK/dumbpipe-files" || die 5 "could not unpack $IR_FILE"
        [ -f "$WORK/dumbpipe-files/dumbpipe" ] || die 5 "$IR_FILE has no dumbpipe program in it."
        cp "$WORK/dumbpipe-files/dumbpipe" "$HOME/.local/bin/dumbpipe" || die 5 "could not copy dumbpipe into $HOME/.local/bin"
        chmod +x "$HOME/.local/bin/dumbpipe"
        dumbpipe_ok "$HOME/.local/bin/dumbpipe" || die 5 "dumbpipe was installed but does not run here. Run '$HOME/.local/bin/dumbpipe --version' to see why."
        IR_BIN=$HOME/.local/bin/dumbpipe
        say "  $("$IR_BIN" --version 2>/dev/null </dev/null | head -n 1)"
    }

    # build_dumbpipe_relay: build a dumbpipe with the --relay option from the pinned commit into IR_DIR/bin (apart from any dumbpipe
    # the person has, which stays as it is). Stops (exit 5) when cargo is missing or the build fails.
    build_dumbpipe_relay() {
        say ""
        say "==> Building dumbpipe with relay support (a few minutes the first time)"
        command -v cargo >/dev/null 2>&1 || die 5 "building dumbpipe needs Rust's cargo, which was not found. Install Rust (https://rustup.rs) and run this command again, or leave out --relay-url to use n0's public relays."
        (
            umask 077
            mkdir -p "$IR_DIR"
        ) || die 4 "could not make $IR_DIR"
        cargo install --git "$IR_GIT" --rev "$IR_REV" --locked --force --root "$IR_DIR" dumbpipe </dev/null || die 5 "could not build dumbpipe from $IR_GIT at $IR_REV. Nothing else was changed."
        [ -x "$IR_DIR/bin/dumbpipe" ] || die 5 "the build gave no $IR_DIR/bin/dumbpipe."
        if ! dumbpipe_ok "$IR_DIR/bin/dumbpipe" || ! dumbpipe_relay_ok "$IR_DIR/bin/dumbpipe"; then
            die 5 "the dumbpipe that was built does not have the options this needs. Run '$IR_DIR/bin/dumbpipe listen-tcp --help' to see."
        fi
        IR_BIN=$IR_DIR/bin/dumbpipe
        say "  $("$IR_BIN" --version 2>/dev/null </dev/null | head -n 1)"
    }

    # make_iroh_keys: save the secret key and the secret name unless they are there. The key decides the endpoint id and the
    # name is what only your phone is told, so keeping both keeps the address the same. Each file is private to the user.
    make_iroh_keys() {
        (
            umask 077
            mkdir -p "$IR_DIR"
        ) || die 4 "could not make $IR_DIR"
        chmod 700 "$IR_DIR" 2>/dev/null || :
        for ir_pair in secret:32 alpn:16; do
            ir_name=${ir_pair%%:*}
            ir_bytes=${ir_pair##*:}
            if [ -f "$IR_DIR/$ir_name" ] && grep -qx "[0-9a-f]\{$((ir_bytes * 2))\}" "$IR_DIR/$ir_name" 2>/dev/null; then
                say "  using the saved $ir_name in $IR_DIR"
                continue
            fi
            ir_value=$(random_hex "$ir_bytes")
            [ "${#ir_value}" = $((ir_bytes * 2)) ] || die 4 "could not make random bytes for the iroh $ir_name (head, od or /dev/urandom is missing)."
            (
                umask 077
                printf '%s\n' "$ir_value" >"$IR_DIR/$ir_name"
            ) || die 4 "could not write $IR_DIR/$ir_name"
            say "  made the $ir_name in $IR_DIR"
        done
        IR_ALPN=$(head -n 1 "$IR_DIR/alpn")
        # The endpoint id is the public half of the key. dumbpipe can tell it without any network, as a ticket for the key.
        ir_ticket=$(IROH_SECRET=$(head -n 1 "$IR_DIR/secret") "$IR_BIN" generate-ticket 2>/dev/null </dev/null | head -n 1)
        IR_ENDPOINT=$(iroh_id_of "$ir_ticket")
        [ "${#IR_ENDPOINT}" = 64 ] || die 4 "'dumbpipe generate-ticket' gave a ticket this script cannot read, so the endpoint id is unknown."
    }

    # write_iroh_runner: the small script the service runs. dumbpipe takes its secret key from the environment; reading the key
    # here keeps it out of the launchd or systemd file. The secret name has to be on the command line (dumbpipe has no other way
    # to take it), so another user of this computer can see it in `ps`; the README says so.
    write_iroh_runner() {
        IR_RUN=$IR_DIR/run.sh
        (
            umask 077
            {
                printf '%s\n' '#!/bin/sh' '# Written by dogr setup.sh. Starts dumbpipe with the saved secret key and the secret name.'
                # shellcheck disable=SC2016  # the $(...) is meant to be written, not expanded here
                printf 'IROH_SECRET=$(head -n 1 %s) || exit 1\n' "$(sq "$IR_DIR/secret")"
                printf '%s\n' 'export IROH_SECRET'
                # With a relay of your own the option comes before the secret name; without one the line is the same as ever.
                ir_relay_opt=
                if [ -n "$IR_RELAY" ]; then ir_relay_opt=" --relay $(sq "$IR_RELAY")"; fi
                # shellcheck disable=SC2016
                printf 'exec %s listen-tcp --host 127.0.0.1:%s%s --custom-alpn "utf8:$(head -n 1 %s)"\n' "$(sq "$IR_BIN")" "$PORT" "$ir_relay_opt" "$(sq "$IR_DIR/alpn")"
            } >"$IR_RUN"
        ) || die 4 "could not write $IR_RUN"
        chmod 700 "$IR_RUN" || die 4 "could not make $IR_RUN runnable"
    }

    # read_iroh_ticket: the ticket the service prints in its log once it listens, in IR_TICKET
    # shellcheck disable=SC2329  # called through retry
    read_iroh_ticket() {
        IR_TICKET=$(sed -n 's/.*dumbpipe connect-tcp \(endpoint[a-z2-7]\{40,\}\).*/\1/p' "$IR_LOG" 2>/dev/null | head -n 1)
        [ -n "$IR_TICKET" ]
    }

    # start_iroh_service: write the service file for this system and (re)start the service with a fresh log, so a ticket from an
    # earlier run is never taken for the new one.
    start_iroh_service() {
        (
            umask 077
            mkdir -p "${IR_LOG%/*}" && : >"$IR_LOG"
        ) || die 4 "could not make the log ($IR_LOG)."
        if [ "$(uname -s)" = Darwin ]; then
            ir_plist=$HOME/Library/LaunchAgents/dev.dogr.iroh.plist
            mkdir -p "${ir_plist%/*}" || die 4 "could not make ${ir_plist%/*}"
            # The values go into XML, so & and < are written the XML way.
            ir_xml_log=$(printf '%s' "$IR_LOG" | sed 's/&/\&amp;/g; s/</\&lt;/g')
            ir_xml_run=$(printf '%s' "$IR_RUN" | sed 's/&/\&amp;/g; s/</\&lt;/g')
            {
                printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
                printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                printf '%s\n' '<plist version="1.0">' '<dict>'
                printf '%s\n' '  <key>Label</key><string>dev.dogr.iroh</string>' '  <key>ProgramArguments</key>' '  <array>'
                printf '    <string>%s</string>\n' "$ir_xml_run"
                printf '%s\n' '  </array>' '  <key>RunAtLoad</key><true/>' '  <key>KeepAlive</key><true/>'
                printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$ir_xml_log"
                printf '  <key>StandardOutPath</key><string>%s</string>\n' "$ir_xml_log"
                printf '%s\n' '  <key>ProcessType</key><string>Background</string>' '</dict>' '</plist>'
            } >"$ir_plist" || die 4 "could not write $ir_plist"
            ir_uid=$(id -u)
            # An older run's service is stopped first so the new file is the one that counts. That fails when none runs, which is fine.
            launchctl bootout "gui/$ir_uid/dev.dogr.iroh" >/dev/null 2>&1 </dev/null || :
            retry launchctl bootstrap "gui/$ir_uid" "$ir_plist" </dev/null || die 4 "'launchctl bootstrap' could not start the iroh service ($ir_plist). Is this a login session of your own user?"
        else
            ir_unit=$HOME/.config/systemd/user/dogr-iroh.service
            mkdir -p "${ir_unit%/*}" || die 4 "could not make ${ir_unit%/*}"
            {
                printf '%s\n' '[Unit]' 'Description=iroh tunnel for Collie (dogr setup.sh)' '' '[Service]'
                printf 'ExecStart="%s"\n' "$IR_RUN"
                printf '%s\n' 'Restart=always' 'RestartSec=5'
                printf 'StandardError=append:%s\n' "$IR_LOG"
                printf 'StandardOutput=append:%s\n' "$IR_LOG"
                printf '%s\n' '' '[Install]' 'WantedBy=default.target'
            } >"$ir_unit" || die 4 "could not write $ir_unit"
            systemctl --user daemon-reload </dev/null || die 4 "'systemctl --user daemon-reload' failed. Is there a systemd user session (are you logged in on this computer)?"
            systemctl --user enable dogr-iroh.service </dev/null || die 4 "'systemctl --user enable' failed for the iroh service ($ir_unit)."
            systemctl --user restart dogr-iroh.service </dev/null || die 4 "'systemctl --user restart' could not start the iroh service ($ir_unit). 'journalctl --user -u dogr-iroh' says why."
        fi
    }

    # setup_iroh: install dumbpipe, save the keys, run the service, check that it runs with the endpoint id the keys give, and
    # add COLLIE_PUBLIC_URL with the address to the settings that apply_settings writes next.
    setup_iroh() {
        if ! find_dumbpipe; then
            if [ -n "$IR_RELAY" ]; then build_dumbpipe_relay; else install_dumbpipe; fi
        fi
        say ""
        say "==> Making sure the iroh keys and service are there"
        make_iroh_keys
        write_iroh_runner
        start_iroh_service
        retry read_iroh_ticket || die 4 "the iroh service runs but printed no ticket. $IR_LOG should have a line with it; dumbpipe's errors end up there."
        # The ticket of the running service starts with its endpoint id. If it is not the one the saved key gives, another
        # dumbpipe holds the port or the name, and the address would lead to the wrong place.
        [ "$(iroh_id_of "$IR_TICKET")" = "$IR_ENDPOINT" ] || die 4 "the running service has another endpoint id than the saved key gives. Is an older dumbpipe still running? ($IR_LOG)"
        if grep -q 'Failed to connect to the home relay' "$IR_LOG" 2>/dev/null; then
            if [ -n "$IR_RELAY" ]; then
                warn "dumbpipe could not reach your relay server ($IR_RELAY). Your phone cannot connect until this computer can; check that the relay runs and can be reached from here, then run this command again."
            else
                warn "dumbpipe could not reach its relay server (n0's public relays). Your phone cannot connect until this computer can; check its internet connection and run this command again."
            fi
        fi
        say "  the service runs; its address is secret and is not shown here (it is in the QR code below)"
        PUBLIC_URL=$IR_BASE/ir$IR_ENDPOINT$IR_ALPN
        want COLLIE_PUBLIC_URL "$PUBLIC_URL"
        if [ "$(env_get COLLIE_PUBLIC_URL)" != "$PUBLIC_URL" ]; then ENV_TOUCHED=1; fi
    }

    # plan TEXT...: one numbered line of the plan
    plan() {
        PLAN_N=$((PLAN_N + 1))
        say "  $PLAN_N. $*"
    }

    # run_collie VERB: run `collie VERB` ("start" or "restart") with its output on screen and in $log; stop if it fails.
    run_collie() {
        { collie "$1" </dev/null 2>&1; echo $? >"$rcfile"; } | tee "$log"
        collie_rc=$(cat "$rcfile" 2>/dev/null || echo 1)
        if [ "$collie_rc" != 0 ]; then
            die 4 "'collie $1' failed (exit $collie_rc). Its output is above; 'collie logs' has more."
        fi
    }

    # switch_to_http: the tailnet has no HTTPS certificates. With the user's agreement (or --http), add one line to Collie's
    # .env so Collie publishes over plain http inside the tailnet. Stops the script (exit 3) when the user does not agree,
    # or when the .env already has a COLLIE_SERVE_MODE line that is not ours to change.
    switch_to_http() {
        say ""
        say "Your tailnet has no HTTPS certificates (that is normal for Headscale)."
        say "Collie can be published over plain http inside the tailnet instead. Tailscale still encrypts everything between"
        say "your devices; only the address starts with http:// and Collie's web app cannot be added to a home screen."
        say "This adds one line, COLLIE_SERVE_MODE=http, to $ENV_FILE."
        if [ "$HTTP_OK" != 1 ]; then
            # Going from https to http is a step down, so it is never taken silently: --yes alone is not enough.
            if [ "$ASSUME_YES" = 1 ] || ! have_tty; then
                say "To do that, run this command again with --http."
                exit 3
            fi
            ask_yes_no "Publish over plain http inside the tailnet?" n || {
                say "Nothing was changed. Turn on HTTPS certificates for your tailnet, or run this command again with --http."
                exit 3
            }
            HTTP_OK=1
        fi
        if [ -f "$ENV_FILE" ] && grep -q '^[[:space:]]*COLLIE_SERVE_MODE=' "$ENV_FILE"; then
            say "$ENV_FILE already has a COLLIE_SERVE_MODE line, so it is left alone."
            say "Set it to COLLIE_SERVE_MODE=http there, then run this command again."
            exit 3
        fi
        mkdir -p "${ENV_FILE%/*}" || die 3 "could not create ${ENV_FILE%/*}"
        # The file may hold secrets of Collie's, so a file made here is private to the user (an existing one keeps its mode).
        (
            umask 077
            printf '\n# Added by dogr setup.sh: this tailnet has no HTTPS certificates, so Collie is published over plain http.\nCOLLIE_SERVE_MODE=http\n' >>"$ENV_FILE"
        ) || die 3 "could not write $ENV_FILE"
        SWITCHED=1
    }

    # ---- steps ----------------------------------------------------------------------------------------------------

    # Read the command line.
    while [ $# -gt 0 ]; do
        case $1 in
            --tailscale) set_route tailscale ;;
            --tailcat) set_route tailcat ;;
            --iroh) set_route iroh ;;
            --derpmap-url)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--derpmap-url needs a value: the https address of your relay map"
                fi
                set_route tailcat
                DERP_URL=$2
                shift
                ;;
            --derpmap-url=*)
                set_route tailcat
                DERP_URL=${1#--derpmap-url=}
                ;;
            --relay-url)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--relay-url needs a value: the address of your iroh relay server"
                fi
                set_route iroh
                IR_RELAY=$2
                shift
                ;;
            --relay-url=*)
                set_route iroh
                IR_RELAY=${1#--relay-url=}
                ;;
            --region)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--region needs a value: a relay region (see tailcat genkey --region=list) or the host name of your own relay"
                fi
                set_route tailcat
                TC_REGION=$2
                shift
                ;;
            --region=*)
                set_route tailcat
                TC_REGION=${1#--region=}
                ;;
            --proxy) set_route proxy ;;
            --lan) set_route lan ;;
            --url)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--url needs a value: the https address of your reverse proxy"
                fi
                set_route proxy
                PROXY_URL=$2
                shift
                ;;
            --url=*)
                set_route proxy
                PROXY_URL=${1#--url=}
                ;;
            --host)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--host needs a value: the address of this computer on the local network"
                fi
                set_route lan
                LAN_HOST=$2
                shift
                ;;
            --host=*)
                set_route lan
                LAN_HOST=${1#--host=}
                ;;
            --mux)
                if [ $# -lt 2 ]; then
                    usage >&2
                    die 1 "--mux needs a value: herdr or herdr-core"
                fi
                MUX=$2
                shift
                ;;
            --mux=*) MUX=${1#--mux=} ;;
            --http) HTTP_OK=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die 1 "unknown option: $1"
                ;;
        esac
        shift
    done

    case $MUX in
        '' | herdr | herdr-core) ;;
        *)
            usage >&2
            die 1 "unknown --mux value: $MUX (use herdr or herdr-core)"
            ;;
    esac

    # Only macOS and Linux: Collie's Windows support is experimental and has its own guide.
    case $(uname -s 2>/dev/null) in
        Darwin | Linux) ;;
        *) die 1 "this script supports macOS and Linux only. On Windows, follow Collie's own Windows guide." ;;
    esac
    command -v curl >/dev/null 2>&1 || die 1 "curl is needed and was not found."

    WORK=$(mktemp -d 2>/dev/null) || die 1 "could not make a temporary folder."
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    make_curl_wrapper || WRAP_OK=0

    # The first question: which way does the phone reach this computer? Tailscale first; "no" leads to the other two.
    if [ -z "$ROUTE" ]; then
        have_tty || die 1 "there is no terminal to ask on. Run again with --tailscale, --tailcat, --iroh, --proxy or --lan (and --yes) to answer for you."
        if ask_yes_no "Do you reach this computer from your phone through Tailscale?"; then
            ROUTE=tailscale
        else
            ask_other_route
        fi
    fi

    # What the chosen route needs to know, and the settings it puts into Collie's .env.
    PORT=$(env_get COLLIE_PORT)
    case $PORT in
        '' | *[!0-9]*) PORT=8787 ;;
    esac
    case $ROUTE in
        tailscale) check_leftovers ;;
        tailcat) resolve_tailcat ;;
        iroh) resolve_iroh ;;
        proxy) resolve_proxy ;;
        lan) resolve_lan ;;
    esac

    # Which terminal program does Collie drive? The one named with --mux, else ask (the question marks what is installed).
    have_herdr=0
    have_hc=0
    if find_herdr; then have_herdr=1; fi
    if find_hc; then have_hc=1; fi
    if [ -z "$MUX" ]; then
        have_tty || die 1 "there is no terminal to ask which terminal program Collie should drive. Run again with --mux herdr or --mux herdr-core."
        ask_mux
    fi
    if [ "$MUX" = herdr ]; then
        MUX_URL=${DOGR_HERDR_INSTALL_URL:-https://herdr.dev/install.sh}
        have_mux=$have_herdr
    else
        MUX_URL=${DOGR_HERDR_CORE_INSTALL_URL:-https://releases.herdr.dev/core/install.sh}
        have_mux=$have_hc
    fi
    ENV_MUX=$(env_mux)
    if [ -n "$ENV_MUX" ] && [ "$ENV_MUX" != "$MUX" ]; then ENV_CHANGED=1; fi

    # Say what is about to happen, then ask once.
    if find_collie; then
        WAS_INSTALLED=1
        installed=$(collie version 2>/dev/null </dev/null | head -n 1)
        install_line="Collie is already installed (${installed:-version unknown}); it is left as it is."
    else
        install_line="Install Collie into ${COLLIE_DIR:-~/.local/share/collie} with Collie's own installer (${INSTALL_URL})."
    fi
    say "This will:"
    plan "$install_line"
    if [ "$have_mux" = 1 ]; then
        plan "$MUX is already installed; it is left as it is."
    else
        plan "Install $MUX with its own installer ($MUX_URL)."
    fi
    if [ "$MUX" = herdr-core ]; then
        plan "Start herdr-core in the background ('hc server start'; nothing happens if it already runs)."
    else
        plan "Check that herdr is running. Only you can open it, so if it is not, the script stops and says how."
    fi
    if [ "$ENV_CHANGED" = 1 ]; then
        plan "Change COLLIE_MUX in $ENV_FILE from $ENV_MUX to $MUX (Collie reads that file before your environment), then restart Collie."
    fi
    if [ "$ROUTE" = tailcat ]; then plan_tailcat; fi
    if [ "$ROUTE" = iroh ]; then plan_iroh; fi
    if [ "$ROUTE" != tailscale ]; then plan_settings; fi
    case $ROUTE in
        tailscale)
            plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX."
            plan "Publish it on your tailnet with 'tailscale serve' (HTTPS, port 443 -> 127.0.0.1:8787)."
            ;;
        tailcat)
            plan "Also set COLLIE_PUBLIC_URL to $TC_BASE/<your tailcat address> once the service has printed the address (that is what the QR code carries)."
            plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX. It answers on 127.0.0.1 only; the tunnel carries the phone to it."
            ;;
        iroh)
            plan "Also set COLLIE_PUBLIC_URL to $IR_BASE/<your iroh address> once the service runs (that is what the QR code carries)."
            plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX. It answers on 127.0.0.1 only; the tunnel carries the phone to it."
            ;;
        proxy)
            plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX. It answers on 127.0.0.1 only; your reverse proxy is what the phone reaches."
            plan "Check that Collie answers here and at $PUBLIC_URL, and show an example of the proxy setup. The proxy, its certificate and who may reach it are yours to set up."
            ;;
        lan)
            plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX, answering on $PUBLIC_HOST."
            plan "Check that Collie answers at $PUBLIC_URL."
            ;;
    esac
    plan "Create a one-time pairing code and show it as a QR code."
    if [ "$ROUTE" = tailcat ]; then
        say ""
        say "Please note: the tailcat address is a secret. Whoever has it can reach Collie's door. Pairing still needs the one-time"
        say "code, and every other request needs the key that pairing hands out. The address ends up in the QR code, in Collie's"
        say "settings file ($ENV_FILE, private to you) and in the output of 'collie status'. Do not share a screenshot of any of them."
        say ""
    fi
    if [ "$ROUTE" = iroh ]; then
        say ""
        say "Please note: the iroh address is a secret. Whoever has it can reach Collie's door. Pairing still needs the one-time"
        say "code, and every other request needs the key that pairing hands out. The address ends up in the QR code, in Collie's"
        say "settings file ($ENV_FILE, private to you) and in the output of 'collie status'. Do not share a screenshot of any of them."
        say "Its second half is a secret name that dumbpipe takes on its command line, so other users of this computer can see it"
        say "with 'ps'. The saved files are in $IR_DIR, private to you."
        if [ -n "$IR_RELAY" ]; then
            say "The tunnel goes through your relay server ($IR_RELAY) until your phone and this computer find a direct path. The"
            say "phone must be given the same relay address (the app's command for this computer carries it). The traffic is end-to-end"
            say "encrypted, so the relay cannot read it. To go back to n0's public relays, run this script again without --relay-url."
        else
            say "The tunnel goes through n0's public iroh relay servers until your phone and this computer find a direct path. They are"
            say "free; n0 says they are for development and testing and promises no speed or uptime. The traffic is end-to-end encrypted."
        fi
        say ""
    fi
    if [ "$ROUTE" = lan ]; then
        say ""
        say "Please note: this is plain http, so the traffic is not encrypted. Anyone on your local network can reach Collie."
        say "Pairing still needs the one-time code, and every API request other than the health check and the pairing needs the"
        say "key that pairing hands out. Use it at home, not on a shared or public network."
        say ""
    fi
    say "Nothing else on this computer is changed. How to undo it is in the README."
    if [ "$DRY_RUN" = 1 ]; then
        say "Dry run: nothing was changed."
        exit 0
    fi
    confirm "Continue?" || {
        say "Stopped. Nothing was changed."
        exit 6
    }

    # Step 1: install Collie when it is missing.
    if ! find_collie; then
        say ""
        say "==> Installing Collie"
        # Download first, run second: with a pipe, a failed download would hand the shell an empty script and look like success.
        script=$WORK/collie-install.sh
        fetch "$INSTALL_URL" "$script" || die 5 "could not download Collie's installer from $INSTALL_URL"
        run_installer "$script" "${DOGR_COLLIE_TAG:-}" || die 5 "Collie's installer failed. Its output is above."
        find_collie || die 5 "Collie was installed but the 'collie' command was not found. Add ~/.local/bin to your PATH and run this again."
    fi

    # Step 2: the terminal program Collie drives: install it when it is missing, then make sure it runs.
    if [ "$have_mux" != 1 ]; then
        say ""
        say "==> Installing $MUX"
        script=$WORK/mux-install.sh
        fetch "$MUX_URL" "$script" || die 5 "could not download the $MUX installer from $MUX_URL"
        run_installer "$script" || die 5 "the $MUX installer failed. Its output is above."
        find_mux || die 5 "$MUX was installed but its command was not found. Add ~/.local/bin to your PATH and run this command again."
    fi
    say ""
    say "==> Making sure $MUX runs"
    if [ "$MUX" = herdr-core ]; then
        # Starting twice is fine: the command reports the core that already runs.
        out=$("$HC" server start </dev/null 2>&1) || {
            say "$out"
            die 4 "could not start herdr-core ('$HC server start' failed). Its output is above."
        }
        say "  herdr-core runs"
    else
        if out=$(herdr status server </dev/null 2>&1); then rc=0; else rc=$?; fi
        case $out in
            *"not running"*)
                say "herdr is installed, but it is not running. Collie reads your terminals through it."
                say "Open a terminal and run:   herdr"
                say "Then press Ctrl+b q to leave it: the server keeps running. Run this command again after that;"
                say "it is safe to repeat."
                exit 3
                ;;
        esac
        if [ "$rc" != 0 ]; then
            say "$out"
            die 4 "could not ask herdr whether it runs ('herdr status server' failed). Its output is above."
        fi
        say "  herdr runs"
    fi
    # The program Collie drives is a setting of Collie's. The .env is read before the environment, so a line that names the
    # other program is replaced where it stands; otherwise the environment tells Collie, and Collie writes it to the .env.
    if [ "$ENV_CHANGED" = 1 ]; then
        env_set COLLIE_MUX "$MUX" || die 3 "could not change $ENV_FILE"
        say "  $ENV_FILE: COLLIE_MUX changed from $ENV_MUX to $MUX"
    fi
    COLLIE_MUX=$MUX
    export COLLIE_MUX
    if [ "$ROUTE" = tailcat ]; then setup_tailcat; fi
    if [ "$ROUTE" = iroh ]; then setup_iroh; fi
    if [ "$ROUTE" != tailscale ]; then apply_settings; fi

    # Step 3: start Collie. It prints lines starting with "setup:" for what is missing; it never stops on them itself.
    say ""
    say "==> Starting Collie"
    log=$WORK/start.log
    rcfile=$WORK/start.rc
    run_collie start
    # A running Collie may have started before a setting changed, so it is restarted to read it. A Collie that this run
    # installed was never running, so its first start has read everything.
    if [ "$ENV_CHANGED" = 1 ] || { [ "$ENV_TOUCHED" = 1 ] && [ "$WAS_INSTALLED" = 1 ]; }; then
        say ""
        say "==> Restarting Collie so it reads the changed settings"
        run_collie restart
    fi
    # One finding has a way out that this script can take: a tailnet without HTTPS certificates. Any other finding, or this one
    # together with another, is for the person to fix first.
    if [ "$ROUTE" = tailscale ] && [ "$(grep -c '^ *setup:' "$log")" = 1 ] && grep -q 'HTTPS certificates are off for your tailnet' "$log"; then
        switch_to_http
        say ""
        say "==> Restarting Collie"
        run_collie restart
    fi
    if grep -q '^ *setup:' "$log"; then
        say ""
        say "Collie is running here, but your phone cannot reach it yet."
        say "Do what the 'fix:' lines above say, then run this command again. It is safe to repeat."
        exit 3
    fi

    # Step 4: check that it answers, on this computer and on the Tailscale address the phone will use.
    say ""
    say "==> Checking that Collie answers"
    status=$(collie status --json 2>/dev/null </dev/null | head -n 1)
    local_url=$(json_string "$status" localUrl)
    phone_url=$(json_string "$status" phoneUrl)
    got_mux=$(json_string "$status" mux)
    : "${local_url:=http://127.0.0.1:8787}"
    retry health_ok "$local_url" || die 4 "Collie does not answer at $local_url. Run 'collie logs' to see why."
    say "  on this computer: $local_url answers"
    if [ -n "$got_mux" ] && [ "$got_mux" != "$MUX" ]; then
        say ""
        say "Collie is driving $got_mux, not $MUX. A setting of COLLIE_MUX=$got_mux sits somewhere this script cannot see (a shell"
        say "profile or a service file). Remove it, run 'collie restart', then run this command again."
        exit 3
    fi
    case $ROUTE in
        tailscale)
            if [ -z "$phone_url" ]; then
                say ""
                say "Collie could not read this computer's Tailscale address, so a phone has nothing to connect to."
                say "Run 'collie doctor' and fix what it names, then run this command again."
                exit 3
            fi
            if [ "$SWITCHED" = 1 ]; then
                case $phone_url in
                    http://*) ;;
                    *)
                        say ""
                        say "Collie still gives an https:// address, so it did not pick up COLLIE_SERVE_MODE=http."
                        say "It may read its settings from another folder (for example when Herdr manages it). Put that line in the .env"
                        say "that Collie really uses, run 'collie restart', then run this command again."
                        exit 3
                        ;;
                esac
            fi
            if retry health_ok "$phone_url"; then
                say "  on Tailscale:     $phone_url answers"
            else
                # Not fatal: some computers cannot reach their own Tailscale name, although other devices can.
                warn "$phone_url did not answer from this computer. If your phone cannot connect either, run 'collie doctor'."
            fi
            ;;
        proxy | lan | tailcat | iroh)
            # Collie must give the address that was asked for: if it does not, it did not read the settings.
            if [ "$phone_url" != "$PUBLIC_URL" ]; then
                say ""
                say "Collie says its address is ${phone_url:-unknown}, not $PUBLIC_URL, so it did not pick up the settings in $ENV_FILE."
                say "It may read its settings from another folder (for example when Herdr manages it). Put the lines there,"
                say "run 'collie restart', then run this command again."
                exit 3
            fi
            if [ "$ROUTE" = proxy ]; then
                say ""
                say "==> Your reverse proxy"
                say "Collie answers on 127.0.0.1:$PORT only. Your proxy has to take $PUBLIC_URL and pass it on to Collie, with the"
                say "Host header unchanged. For Caddy that is:"
                say ""
                say "    $PUBLIC_HOST {"
                say "        reverse_proxy 127.0.0.1:$PORT {"
                say "            header_up Host {host}"
                say "        }"
                say "    }"
                say ""
                say "This script does not set up the proxy, its certificate or who may reach it. Collie's deployment guide"
                say "(docs/deployment.md, 'Variant C') lists what a proxy in front of Collie should do."
                if retry health_ok "$phone_url"; then
                    say "  through the proxy: $phone_url answers"
                else
                    say ""
                    say "Collie runs, but $PUBLIC_URL does not answer from this computer yet."
                    say "Set up the proxy as shown above (a sign-in page in front of /api/health makes this check fail too), then run:"
                    say "    collie pair"
                    say "That shows the pairing code and QR code for your phone. If this computer cannot reach its own public address"
                    say "but your phone can, run it now."
                    exit 3
                fi
            elif [ "$ROUTE" = tailcat ]; then
                # The tunnel ends at the phone, so there is no address here to ask. The service log is the evidence.
                say "  through tailcat: the service runs and Collie gives the address it printed (log: $TC_LOG)"
            elif [ "$ROUTE" = iroh ]; then
                say "  through iroh: the service runs and Collie gives the address of its endpoint (log: $IR_LOG)"
            else
                say "  on the local network: $phone_url answers"
            fi
            ;;
    esac

    # Step 5: the pairing code comes last, so its ten minutes start when the phone is ready to use it.
    say ""
    say "==> Pairing your phone"
    pair_log=$WORK/pair.log
    collie pair </dev/null 2>&1 | tee "$pair_log"
    if grep -q 'No QR' "$pair_log"; then
        warn "no QR code could be drawn. Type the address and the code into the app instead."
    fi
    minutes=$(sed -n 's/.*(\([0-9][0-9]*\) minutes).*/\1/p' "$pair_log" | head -n 1)
    say ""
    say "On your phone: open Dogr, tap +, then 'Scan QR code' and point the camera at the code above."
    say "No camera? Paste the link above into the Address field, or type the address and the code."
    say "The code works once and for ${minutes:-a few} minutes. For a new one, run: collie pair"
    if [ "$SWITCHED" = 1 ]; then
        say "The address starts with http://. Tailscale encrypts the traffic between your devices; the address is just not HTTPS."
    fi
    if [ "$ROUTE" = tailcat ]; then
        say "The first connection can take several seconds while the tunnel is built. The tailcat service keeps running and"
        say "starts again after a restart; the address stays the same as long as the key '$TC_KEY' exists. If a pairing code"
        say "runs out, run: collie pair"
        if [ "$(uname -s)" != Darwin ]; then
            say "To keep the service running when you are logged out (a server), run once: loginctl enable-linger \$USER"
        fi
    fi
    if [ "$ROUTE" = iroh ]; then
        say "The first connection can take several seconds while the tunnel is built. The dumbpipe service keeps running and"
        say "starts again after a restart; the address stays the same as long as the files in $IR_DIR exist. If a pairing code"
        say "runs out, run: collie pair"
        if [ "$(uname -s)" != Darwin ]; then
            say "To keep the service running when you are logged out (a server), run once: loginctl enable-linger \$USER"
        fi
    fi
    if [ "$ROUTE" = lan ]; then
        say "The address starts with http:// and is not encrypted. Your phone must be on the same network as this computer."
        say "If this computer gets a new address, Collie can no longer start: run this command again."
    fi
    exit 0
}

main "$@"
