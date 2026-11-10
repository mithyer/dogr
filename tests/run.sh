#!/bin/sh
# tests/run.sh - runs setup.sh against a stub `curl` and a stub `collie`.
#
# Nothing here touches the real computer: every case gets its own HOME and its own PATH that holds only the stubs and the
# few system tools setup.sh may use, so a Collie that is really installed cannot leak in.
#
# Run it:   sh tests/run.sh          (needs only a POSIX shell; shellcheck is optional and run when found)

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SETUP=$HERE/../setup.sh
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
CASE=

# ---- the tools setup.sh may use (and the stub installer needs), linked into one folder -----------------------------------------------------------------
BELT=$ROOT/belt
mkdir -p "$BELT"
for tool in sh sed grep head tail tr tee cat mktemp rm sleep uname cp mkdir chmod awk; do
    found=$(command -v "$tool") || {
        echo "this test needs '$tool' and did not find it"
        exit 1
    }
    ln -s "$found" "$BELT/$tool"
done

# ---- the stubs ----------------------------------------------------------------------------------------------------------
STUBS=$ROOT/stubs
mkdir -p "$STUBS"

# curl: records the call, serves the installer file, and answers /api/health as the case says (STUB_HEALTH_LOCAL and
# STUB_HEALTH_PHONE are "up" or anything else for "down").
cat >"$STUBS/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
out=
url=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift ;;
        --max-time) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
case $url in
    */api/health)
        echo "health $url" >>"$STUB_LOG"
        case $url in
            "$STUB_LOCAL_URL"*) [ "${STUB_HEALTH_LOCAL:-up}" = up ] || exit 22 ;;
            *) [ "${STUB_HEALTH_PHONE:-up}" = up ] || exit 22 ;;
        esac
        printf '{"ok":true,"version":"1.27.0","deposed":false}\n'
        ;;
    *)
        [ "${STUB_DOWNLOAD:-ok}" = ok ] || exit 22
        echo "download $url" >>"$STUB_LOG"
        case $url in
            *releases.herdr.dev/core/* | *example.test/core.sh) cp "$STUB_HC_INSTALLER" "$out" ;;
            *herdr.dev/install.sh*) cp "$STUB_HERDR_INSTALLER" "$out" ;;
            *) cp "$STUB_INSTALLER" "$out" ;;
        esac
        ;;
esac
EOF

# collie: records the call and prints what the real commands print (shapes taken from Collie's own source).
cat >"$STUBS/collie" <<'EOF'
#!/bin/sh
echo "collie $* [mux=${COLLIE_MUX:-none}]" >>"$STUB_LOG"
case $1 in
    version) echo "collie 1.27.0" ;;
    start | restart)
        [ "${STUB_START_RC:-0}" = 0 ] || { echo "start went wrong"; exit "$STUB_START_RC"; }
        echo "  ✓ Collie is running · v1.27.0"
        # Like the real Collie: a multiplexer named in the environment is written to the .env, unless the .env names one already.
        if [ -n "${COLLIE_MUX:-}" ] && ! grep -q '^COLLIE_MUX=' "$HOME/.config/collie/.env" 2>/dev/null; then
            mkdir -p "$HOME/.config/collie"
            # The real Collie keeps its .env private too (it holds settings that are not for others).
            (umask 077; echo "COLLIE_MUX=$COLLIE_MUX" >>"$HOME/.config/collie/.env")
        fi
        if [ -n "${STUB_SETUP:-}" ]; then
            echo "  setup: $STUB_SETUP"
            echo "    fix: do the thing it says"
        fi
        # A tailnet without HTTPS certificates: the finding goes away once the .env says http. With
        # STUB_IGNORE_ENV Collie still reports it on `start` but is quiet after `restart`, yet keeps
        # giving the https address (the setting was not really picked up).
        if [ "${STUB_NO_CERTS:-0}" = 1 ] && ! grep -q '^COLLIE_SERVE_MODE=http$' "$HOME/.config/collie/.env" 2>/dev/null \
            && ! { [ "$1" = restart ] && [ "${STUB_IGNORE_ENV:-0}" = 1 ]; }; then
            echo "  setup: HTTPS certificates are off for your tailnet"
            echo "    fix: turn on HTTPS in the admin console, or use COLLIE_SERVE_MODE=http"
        fi
        ;;
    status)
        phone=$STUB_PHONE_JSON
        if [ "${STUB_NO_CERTS:-0}" = 1 ] && [ "${STUB_IGNORE_ENV:-0}" != 1 ] && grep -q '^COLLIE_SERVE_MODE=http$' "$HOME/.config/collie/.env" 2>/dev/null; then
            phone='"http://mb17.headnet.example:8787"'
        fi
        # Behind the operator's own front door (COLLIE_SKIP_SERVE=1) the phone's address is COLLIE_PUBLIC_URL.
        if [ "${STUB_IGNORE_ENV:-0}" != 1 ] && grep -q '^COLLIE_SKIP_SERVE=1' "$HOME/.config/collie/.env" 2>/dev/null; then
            phone="\"$(sed -n 's/^COLLIE_PUBLIC_URL=//p' "$HOME/.config/collie/.env" | tail -n 1)\""
        fi
        # The .env wins over the environment, as in the real Collie; STUB_MUX_REPORT forces what it reports.
        mux=$(sed -n 's/^COLLIE_MUX=//p' "$HOME/.config/collie/.env" 2>/dev/null | tail -n 1)
        : "${mux:=${COLLIE_MUX:-herdr-core}}"
        printf '{"running":true,"version":"1.27.0","instance":"default","port":8787,"mux":"%s","localUrl":"%s","phoneUrl":%s,"pairedDevices":0}\n' \
            "${STUB_MUX_REPORT:-$mux}" "$STUB_LOCAL_URL" "$phone"
        ;;
    pair)
        echo "ABCD2345"
        echo ""
        echo "  single-use · expires 2026-11-10T11:00:00.000Z (10 minutes)"
        [ "${STUB_NO_QR:-0}" = 1 ] && echo "  No QR: the bridge URL is unknown, see the note above; the code above still works."
        ;;
esac
exit 0
EOF

# The installer Collie's real installer is replaced by: it puts the stub `collie` where the real one goes.
cat >"$STUBS/installer.sh" <<'EOF'
#!/bin/sh
cat >/dev/null
[ "${STUB_INSTALLER_FAIL:-0}" = 1 ] && { echo "installer broke"; exit 1; }
echo "installer ran tag=${COLLIE_TAG:-none}" >>"$STUB_LOG"
mkdir -p "$HOME/.local/bin"
cp "$STUB_REAL_COLLIE" "$HOME/.local/bin/collie"
chmod +x "$HOME/.local/bin/collie"
EOF
# hc (herdr-core): `hc server start` starts the core, and starting twice is fine, as in the real one.
cat >"$STUBS/hc" <<'EOF'
#!/bin/sh
echo "hc $*" >>"$STUB_LOG"
[ "${STUB_HC_START_RC:-0}" = 0 ] || { echo "could not start"; exit "$STUB_HC_START_RC"; }
echo '{"core":{"id":"x"},"pid":1,"version":"0.1.19"}'
EOF

# herdr: `herdr status server` says whether the server runs (STUB_HERDR_RUNNING=1), in the words of the real one.
cat >"$STUBS/herdr" <<'EOF'
#!/bin/sh
echo "herdr $*" >>"$STUB_LOG"
if [ "${STUB_HERDR_RUNNING:-0}" = 1 ]; then
    echo "status: running"
else
    echo "status: not running"
    echo "socket: /home/x/.config/herdr/herdr.sock"
fi
EOF

# ifconfig (macOS and older Linux): the computer's addresses. STUB_IFCONFIG_MODE: one (a home network address, the default),
# two (a second private address on another interface), none (nothing a phone could reach). Every mode also lists addresses
# that must never be offered: loopback, link-local, Tailscale and Docker.
cat >"$STUBS/ifconfig" <<'EOF'
#!/bin/sh
echo "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384"
echo "	inet 127.0.0.1 netmask 0xff000000"
echo "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
echo "	inet 169.254.57.68 netmask 0xffff0000 broadcast 169.254.255.255"
echo "	inet6 fe80::1c2b:3d4e:5f60:7182%en0 prefixlen 64 secured scopeid 0xb"
case ${STUB_IFCONFIG_MODE:-one} in
    one | two) echo "	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255" ;;
esac
echo "utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280"
echo "	inet 100.64.0.7 --> 100.64.0.7 netmask 0xffffffff"
echo "docker0: flags=4099<UP,BROADCAST,MULTICAST> mtu 1500"
echo "	inet 172.17.0.1 netmask 0xffff0000 broadcast 172.17.255.255"
case ${STUB_IFCONFIG_MODE:-one} in
    two)
        echo "en11: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
        echo "	inet 10.0.0.1 netmask 0xffffff00 broadcast 10.0.0.255"
        ;;
esac
EOF
# ip (Linux): the same idea in the words of `ip -o -4 addr show scope global`.
cat >"$STUBS/ip" <<'EOF'
#!/bin/sh
echo "2: eth0    inet 192.168.1.30/24 brd 192.168.1.255 scope global dynamic eth0\       valid_lft 86389sec"
echo "3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever"
EOF

# The installers of the two: each puts its stub where the real one goes.
cat >"$STUBS/hc-installer.sh" <<'EOF'
#!/bin/sh
cat >/dev/null
[ "${STUB_MUX_INSTALLER_FAIL:-0}" = 1 ] && { echo "installer broke"; exit 1; }
echo "hc installer ran" >>"$STUB_LOG"
mkdir -p "$HOME/.local/bin"
cp "$STUB_HC" "$HOME/.local/bin/hc"
chmod +x "$HOME/.local/bin/hc"
EOF
cat >"$STUBS/herdr-installer.sh" <<'EOF'
#!/bin/sh
cat >/dev/null
[ "${STUB_MUX_INSTALLER_FAIL:-0}" = 1 ] && { echo "installer broke"; exit 1; }
echo "herdr installer ran" >>"$STUB_LOG"
mkdir -p "$HOME/.local/bin"
cp "$STUB_HERDR" "$HOME/.local/bin/herdr"
chmod +x "$HOME/.local/bin/herdr"
EOF
chmod +x "$STUBS/curl" "$STUBS/collie" "$STUBS/installer.sh" "$STUBS/hc" "$STUBS/herdr" "$STUBS/hc-installer.sh" "$STUBS/herdr-installer.sh" "$STUBS/ifconfig" "$STUBS/ip"

# ---- the harness --------------------------------------------------------------------------------------------------------

# quote TEXT: TEXT as one single-quoted shell word, so a value with spaces or quotes survives being written to a file
quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

# run_case NAME [WORD ...] -- SETUP_ARGS...
# Runs setup.sh in a fresh sandbox (own HOME, own PATH, nothing from the real environment) and sets
#   OUT  everything it printed, followed by a line "rc=<exit code>"
#   RC   its exit code
#   LOG  the file where the stubs wrote down every call they got
# Each WORD before "--" is one of:
#   NAME=value        an environment variable for the run (the stubs read STUB_* and setup.sh reads DOGR_*)
#   COLLIE_INSTALLED=0  a computer that has no Collie yet
#   ASK=a,b,c         what the person types at each question, in order, one answer per comma (an empty answer is a bare Enter)
#   ENVFILE=text      a Collie .env file that is already there
#   LINUX=1           a computer that lists its addresses with `ip` and has no `ifconfig`
#   PIPE=1            the whole script arrives through a pipe, the way `curl ... | sh` runs it
#   CUT=1             like PIPE=1 but the download stops half way
run_case() {
    CASE=$1
    shift
    sandbox=$ROOT/case
    rm -rf "$sandbox"
    mkdir -p "$sandbox/home" "$sandbox/path"
    LOG=$sandbox/log
    : >"$LOG"
    wrapper=$sandbox/wrapper.sh
    {
        echo "export HOME=$sandbox/home"
        echo "export PATH=$sandbox/path:$BELT"
        echo "export STUB_LOG=$LOG"
        echo "export STUB_LOCAL_URL=http://127.0.0.1:8787"
        echo "export STUB_PHONE_JSON='\"https://mac.tail1234.ts.net\"'"
        echo "export STUB_INSTALLER=$STUBS/installer.sh"
        echo "export STUB_REAL_COLLIE=$STUBS/collie"
        echo "export STUB_HC_INSTALLER=$STUBS/hc-installer.sh"
        echo "export STUB_HERDR_INSTALLER=$STUBS/herdr-installer.sh"
        echo "export STUB_HC=$STUBS/hc"
        echo "export STUB_HERDR=$STUBS/herdr"
        echo "export DOGR_TTY=$sandbox/tty"
        echo "export DOGR_TRIES=2"
        echo "export DOGR_POLL_DELAY=0"
    } >"$wrapper"
    installed=1
    hc_installed=1
    herdr_installed=0
    muxask=0
    linux=0
    ask=
    envfile=
    mode="file"
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case $1 in
            COLLIE_INSTALLED=0) installed=0 ;;
            HC_INSTALLED=0) hc_installed=0 ;;
            HERDR_INSTALLED=1) herdr_installed=1 ;;
            MUXASK=1) muxask=1 ;;
            LINUX=1) linux=1 ;;
            ASK=*) ask=${1#ASK=} ;;
            ENVFILE=*) envfile=${1#ENVFILE=} ;;
            PIPE=1) mode="pipe" ;;
            CUT=1) mode="cut" ;;
            *=*) printf 'export %s=%s\n' "${1%%=*}" "$(quote "${1#*=}")" >>"$wrapper" ;;
        esac
        shift
    done
    [ "${1:-}" = "--" ] && shift
    # Every case names the terminal program, as the app's command does, unless the case is about the question itself (MUXASK=1)
    # or names one of its own.
    if [ "$muxask" != 1 ]; then
        case " $* " in *" --mux"*) ;; *) set -- --mux herdr-core "$@" ;; esac
    fi
    echo 'exec sh "$@"' >>"$wrapper"
    cp "$STUBS/curl" "$sandbox/path/curl"
    if [ "$installed" = 1 ]; then cp "$STUBS/collie" "$sandbox/path/collie"; fi
    if [ "$hc_installed" = 1 ]; then cp "$STUBS/hc" "$sandbox/path/hc"; fi
    if [ "$herdr_installed" = 1 ]; then cp "$STUBS/herdr" "$sandbox/path/herdr"; fi
    if [ "$linux" = 1 ]; then cp "$STUBS/ip" "$sandbox/path/ip"; else cp "$STUBS/ifconfig" "$sandbox/path/ifconfig"; fi
    # With no ASK there is no terminal at all: DOGR_TTY keeps pointing at a file that does not exist.
    if [ -n "$ask" ]; then printf '%s\n' "$ask" | tr ',' '\n' >"$sandbox/tty"; fi
    if [ -n "$envfile" ]; then
        mkdir -p "$sandbox/home/.config/collie"
        printf '%s\n' "$envfile" >"$sandbox/home/.config/collie/.env"
    fi
    case $mode in
        file) OUT=$(
            env -i /bin/sh "$wrapper" "$SETUP" "$@" 2>&1 </dev/null
            echo "rc=$?"
        ) ;;
        pipe) OUT=$(
            cat "$SETUP" | env -i /bin/sh "$wrapper" -s -- "$@" 2>&1
            echo "rc=$?"
        ) ;;
        cut) OUT=$(
            head -n $(($(grep -c '' "$SETUP") / 2)) "$SETUP" | env -i /bin/sh "$wrapper" -s -- "$@" 2>&1
            echo "rc=$?"
        ) ;;
    esac
    RC=$(printf '%s\n' "$OUT" | sed -n 's/^rc=//p' | tail -n 1)
}

ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    echo "FAIL [$CASE] $1"
    echo "---- output ----"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    echo "---- calls ----"
    sed 's/^/    /' "$LOG"
    echo "----------------"
}

# expect_rc N
expect_rc() { if [ "$RC" = "$1" ]; then ok; else bad "exit code was $RC, wanted $1"; fi; }
# expect_out TEXT / expect_no_out TEXT: the output has / lacks that text
expect_out() { if printf '%s\n' "$OUT" | grep -qF -- "$1"; then ok; else bad "output lacks: $1"; fi; }
expect_no_out() { if printf '%s\n' "$OUT" | grep -qF -- "$1"; then bad "output has: $1"; else ok; fi; }
# expect_called TEXT / expect_not_called TEXT: the stubs saw / never saw a call that has that text
expect_called() { if grep -qF -- "$1" "$LOG"; then ok; else bad "no call: $1"; fi; }
expect_not_called() { if grep -qF -- "$1" "$LOG"; then bad "unexpected call: $1"; else ok; fi; }
# expect_env TEXT / expect_no_env: Collie's .env in the sandbox has / lacks that text
expect_env() { if grep -qF -- "$1" "$sandbox/home/.config/collie/.env" 2>/dev/null; then ok; else bad ".env lacks: $1"; fi; }
expect_no_env() { if grep -qF -- "$1" "$sandbox/home/.config/collie/.env" 2>/dev/null; then bad ".env has: $1"; else ok; fi; }
# expect_env_line / expect_no_env_line: the .env has / lacks a whole line that is exactly TEXT
expect_env_line() { if grep -qxF -- "$1" "$sandbox/home/.config/collie/.env" 2>/dev/null; then ok; else bad ".env has no line: $1"; fi; }
expect_no_env_line() { if grep -qxF -- "$1" "$sandbox/home/.config/collie/.env" 2>/dev/null; then bad ".env has the line: $1"; else ok; fi; }
# expect_order A B: the first call with A comes before the first call with B
expect_order() {
    a=$(grep -nF -- "$1" "$LOG" | head -n 1 | cut -d: -f1)
    b=$(grep -nF -- "$2" "$LOG" | head -n 1 | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "'$1' (line ${a:-none}) is not before '$2' (line ${b:-none})"; fi
}

# ---- the cases ----------------------------------------------------------------------------------------------------------

# The usual road: Collie is installed, everything answers.
run_case "happy path" -- --tailscale --yes
expect_rc 0
expect_called "collie start"
expect_called "collie status --json"
expect_called "health http://127.0.0.1:8787/api/health"
expect_called "health https://mac.tail1234.ts.net/api/health"
expect_called "collie pair"
expect_order "collie start" "collie status --json"
expect_order "collie status --json" "health http://127.0.0.1:8787"
expect_order "health https://mac.tail1234.ts.net" "collie pair"
expect_not_called "download"
expect_out "ABCD2345"
expect_out "10 minutes"
expect_no_out "warning:"

# A second run does not install again and still ends the same way.
run_case "run twice" -- --tailscale --yes
expect_rc 0
expect_not_called "installer ran"

# --dry-run changes nothing: not even a call to start or pair.
run_case "dry run" -- --tailscale --dry-run
expect_rc 0
expect_out "This will:"
expect_out "Dry run: nothing was changed."
expect_not_called "collie start"
expect_not_called "collie pair"

# The same, on a computer that has no Collie: nothing is downloaded either.
run_case "dry run without collie" COLLIE_INSTALLED=0 -- --tailscale --dry-run
expect_rc 0
expect_out "Install Collie"
expect_not_called "download"

# Without Collie: the installer is fetched to a file, run, and the rest follows.
run_case "install first" COLLIE_INSTALLED=0 -- --tailscale --yes
expect_rc 0
expect_called "download https://colliepwa.dev/install.sh"
expect_called "installer ran"
expect_order "installer ran" "collie start"
expect_called "collie pair"

# The release can be pinned and the installer address replaced.
run_case "pinned tag and address" COLLIE_INSTALLED=0 DOGR_COLLIE_TAG=v1.27.0 DOGR_COLLIE_INSTALL_URL=https://example.test/i.sh -- --tailscale --yes
expect_rc 0
expect_called "download https://example.test/i.sh"
expect_called "installer ran tag=v1.27.0"

# A failing download stops before anything runs.
run_case "download fails" COLLIE_INSTALLED=0 STUB_DOWNLOAD=bad -- --tailscale --yes
expect_rc 5
expect_out "could not download"
expect_not_called "installer ran"
expect_not_called "collie start"

# A failing installer stops, and nothing starts.
run_case "installer fails" COLLIE_INSTALLED=0 STUB_INSTALLER_FAIL=1 -- --tailscale --yes
expect_rc 5
expect_out "installer failed"
expect_not_called "collie start"

# Collie names something that is missing: stop with exit 3 and never create a pairing code.
run_case "setup problems" STUB_SETUP="Tailscale is not signed in" -- --tailscale --yes
expect_rc 3
expect_out "setup: Tailscale is not signed in"
expect_out "fix: do the thing it says"
expect_out "run this command again"
expect_not_called "collie pair"

# Collie runs but cannot say its Tailscale address.
run_case "no phone address" STUB_PHONE_JSON=null -- --tailscale --yes
expect_rc 3
expect_out "Tailscale address"
expect_not_called "collie pair"

# Collie does not answer on this computer.
run_case "local health down" STUB_HEALTH_LOCAL=down -- --tailscale --yes
expect_rc 4
expect_out "collie logs"
expect_not_called "collie pair"

# Only the Tailscale address does not answer from here: a warning, and the pairing goes on.
run_case "front door unreachable from here" STUB_HEALTH_PHONE=down -- --tailscale --yes
expect_rc 0
expect_out "warning:"
expect_called "collie pair"

# `collie start` fails outright.
run_case "start fails" STUB_START_RC=3 -- --tailscale --yes
expect_rc 4
expect_out "'collie start' failed"
expect_not_called "collie pair"

# No QR code can be drawn: say so, keep the code on screen.
run_case "no qr" STUB_NO_QR=1 -- --tailscale --yes
expect_rc 0
expect_out "no QR code could be drawn"
expect_out "ABCD2345"

# Asking: answer yes to Tailscale, then yes to continuing.
run_case "ask both questions yes" ASK=y -- --yes
expect_rc 0
expect_called "collie pair"

# Asking: "no" to Tailscale leads to a second question; without an answer to it nothing happens.
run_case "not tailscale, no second answer" ASK=n --
expect_rc 1
expect_out "no answer"
expect_not_called "collie start"

# Declining at "Continue?" leaves everything as it was.
run_case "decline to continue" ASK=n -- --tailscale
expect_rc 6
expect_out "Nothing was changed."
expect_not_called "collie start"

# No terminal and no flag: refuse instead of guessing.
run_case "no terminal" -- --yes
expect_rc 1
expect_out "no terminal"
expect_not_called "collie start"

run_case "no terminal and no yes" -- --tailscale
expect_rc 1
expect_out "--yes"
expect_not_called "collie start"

# Wrong use.
run_case "unknown option" -- --nope
expect_rc 1
expect_out "unknown option: --nope"
expect_out "Usage:"

run_case "help" -- --help
expect_rc 0
expect_out "Usage: setup.sh"
expect_not_called "collie"

# ---- a tailnet without HTTPS certificates (Headscale) ----
# --http answers the question: the .env gets the line, Collie restarts, and the address shown is http://
run_case "no certificates, --http" STUB_NO_CERTS=1 -- --tailscale --http --yes
expect_rc 0
expect_out "no HTTPS certificates"
expect_env "COLLIE_SERVE_MODE=http"
expect_called "collie restart"
expect_called "health http://mb17.headnet.example:8787/api/health"
expect_order "collie start" "collie restart"
expect_order "collie restart" "collie status --json"
expect_order "collie restart" "collie pair"
expect_out "The address starts with http://"

# Asked at the terminal: Continue? yes, plain http? yes.
run_case "no certificates, agreed at the question" STUB_NO_CERTS=1 ASK=y,y -- --tailscale
expect_rc 0
expect_env "COLLIE_SERVE_MODE=http"
expect_called "collie pair"

# Asked at the terminal: Continue? yes, plain http? no. Nothing is written and nothing is paired.
run_case "no certificates, declined" STUB_NO_CERTS=1 ASK=y,n -- --tailscale
expect_rc 3
expect_out "Nothing was changed."
expect_no_env "COLLIE_SERVE_MODE"
expect_not_called "collie restart"
expect_not_called "collie pair"

# A bare Enter at that question means no (going down to http is never the default).
run_case "no certificates, bare Enter" STUB_NO_CERTS=1 ASK=y, -- --tailscale
expect_rc 3
expect_no_env "COLLIE_SERVE_MODE"
expect_not_called "collie pair"

# --yes alone is not enough to switch: it stops and names the option.
run_case "no certificates, --yes only" STUB_NO_CERTS=1 -- --tailscale --yes
expect_rc 3
expect_out "--http"
expect_no_env "COLLIE_SERVE_MODE"
expect_not_called "collie restart"
expect_not_called "collie pair"

# The .env is created private to the user.
run_case "no certificates, file mode" STUB_NO_CERTS=1 -- --tailscale --http --yes
if [ -n "$(find "$sandbox/home/.config/collie/.env" -perm 600)" ]; then ok; else bad ".env is not private (mode 600)"; fi

# An .env that already has other lines keeps them, and gets the new line after them.
run_case "no certificates, existing .env" STUB_NO_CERTS=1 ENVFILE=COLLIE_PORT=9999 -- --tailscale --http --yes
expect_rc 0
expect_env "COLLIE_PORT=9999"
expect_env "COLLIE_SERVE_MODE=http"

# A COLLIE_SERVE_MODE the person set already is not ours to change.
run_case "no certificates, serve mode already set" STUB_NO_CERTS=1 ENVFILE=COLLIE_SERVE_MODE=https -- --tailscale --http --yes
expect_rc 3
expect_out "already has a COLLIE_SERVE_MODE line"
expect_env "COLLIE_SERVE_MODE=https"
expect_not_called "collie restart"
expect_not_called "collie pair"

# Another problem next to the missing certificates: nothing is switched, the person fixes the other thing first.
run_case "no certificates and another problem" STUB_NO_CERTS=1 STUB_SETUP="Tailscale is not signed in" -- --tailscale --http --yes
expect_rc 3
expect_out "setup: Tailscale is not signed in"
expect_no_env "COLLIE_SERVE_MODE"
expect_not_called "collie restart"
expect_not_called "collie pair"

# Collie did not take the setting (it reads its settings elsewhere): say so instead of showing an https:// code.
run_case "setting not picked up" STUB_NO_CERTS=1 STUB_IGNORE_ENV=1 -- --tailscale --http --yes
expect_rc 3
expect_out "did not pick up COLLIE_SERVE_MODE=http"
expect_not_called "collie pair"

# --http on a tailnet that has certificates changes nothing.
run_case "--http with certificates" -- --tailscale --http --yes
expect_rc 0
expect_no_env "COLLIE_SERVE_MODE"
expect_not_called "collie restart"
expect_no_out "The address starts with http://"

# It also works the way people run it: the whole script arrives through a pipe.
run_case "through a pipe" PIPE=1 -- --tailscale --yes
expect_rc 0
expect_called "collie pair"

# A script cut off half way runs nothing: main() is only called on the last line.
run_case "cut off download" CUT=1 -- --tailscale --yes
expect_not_called "collie"
expect_not_called "curl"

# ---- the terminal program: herdr or herdr-core ------------------------------------------------------------------------------

# No --mux: the script asks, and says which of the two is installed. The answer decides; it is started, and Collie is told to
# drive it.
run_case "mux asked: herdr-core, the only one installed" MUXASK=1 ASK=2 -- --tailscale --yes
expect_out "(installed)"
expect_out "Which terminal program"
expect_rc 0
expect_called "hc server start"
expect_called "collie start [mux=herdr-core]"
expect_order "hc server start" "collie start"
expect_env_line "COLLIE_MUX=herdr-core"
expect_out "herdr-core"

# herdr is the answer and it runs: no start command is needed (herdr has none without a terminal), Collie drives it.
run_case "mux asked: herdr, the only one installed" MUXASK=1 ASK=1 HC_INSTALLED=0 HERDR_INSTALLED=1 STUB_HERDR_RUNNING=1 -- --tailscale --yes
expect_rc 0
expect_called "herdr status server"
expect_called "collie start [mux=herdr]"
expect_not_called "hc server start"
expect_env_line "COLLIE_MUX=herdr"

# --mux decides, also when the other one is installed too.
run_case "mux named: herdr while both are installed" HERDR_INSTALLED=1 STUB_HERDR_RUNNING=1 -- --tailscale --mux herdr --yes
expect_rc 0
expect_called "collie start [mux=herdr]"
expect_not_called "hc server start"
run_case "mux named: herdr-core while both are installed" HERDR_INSTALLED=1 -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_called "collie start [mux=herdr-core]"
expect_not_called "herdr status"
run_case "mux named with an equals sign" HERDR_INSTALLED=1 STUB_HERDR_RUNNING=1 -- --tailscale --mux=herdr --yes
expect_rc 0
expect_called "collie start [mux=herdr]"

# herdr is installed but nobody has opened it: the script cannot do that without a terminal, so it says what to do and stops
# before Collie starts. Running it again afterwards is safe.
run_case "herdr not running" HC_INSTALLED=0 HERDR_INSTALLED=1 -- --tailscale --mux herdr --yes
expect_rc 3
expect_out "not running"
expect_out "herdr"
expect_out "Ctrl+b q"
expect_not_called "collie start"
expect_not_called "collie pair"

# A computer that has neither: the one that was asked for is installed with its own installer, after the plan names the address.
run_case "install herdr-core" HC_INSTALLED=0 -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_called "download https://releases.herdr.dev/core/install.sh"
expect_called "hc installer ran"
expect_order "hc installer ran" "hc server start"
expect_order "hc server start" "collie start"
run_case "install herdr" HC_INSTALLED=0 STUB_HERDR_RUNNING=1 -- --tailscale --mux herdr --yes
expect_rc 0
expect_called "download https://herdr.dev/install.sh"
expect_called "herdr installer ran"
expect_order "herdr installer ran" "herdr status server"
expect_not_called "hc installer ran"
run_case "install herdr, then it must be opened" HC_INSTALLED=0 -- --tailscale --mux herdr --yes
expect_rc 3
expect_called "herdr installer ran"
expect_out "not running"
expect_not_called "collie start"

# The installer addresses can be replaced.
run_case "mux installer address" HC_INSTALLED=0 DOGR_HERDR_CORE_INSTALL_URL=https://example.test/core.sh -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_called "download https://example.test/core.sh"

# A failing download or installer stops before anything else is touched.
run_case "mux download fails" HC_INSTALLED=0 STUB_DOWNLOAD=bad COLLIE_INSTALLED=1 -- --tailscale --mux herdr-core --yes
expect_rc 5
expect_out "could not download"
expect_not_called "collie start"
run_case "mux installer fails" HC_INSTALLED=0 STUB_MUX_INSTALLER_FAIL=1 -- --tailscale --mux herdr-core --yes
expect_rc 5
expect_out "installer failed"
expect_not_called "collie start"

# The core refuses to start.
run_case "hc server start fails" STUB_HC_START_RC=1 -- --tailscale --mux herdr-core --yes
expect_rc 4
expect_out "could not start"
expect_not_called "collie start"

# The plan names what would be installed and where it comes from; a dry run downloads nothing.
run_case "plan names the mux installer" HC_INSTALLED=0 -- --tailscale --mux herdr-core --dry-run
expect_rc 0
expect_out "Install herdr-core"
expect_out "https://releases.herdr.dev/core/install.sh"
expect_not_called "download"
run_case "plan with the mux already there" -- --tailscale --mux herdr-core --dry-run
expect_rc 0
expect_out "herdr-core is already installed"
expect_not_called "hc server start"

# Nothing says which one: the script asks, whatever is installed, and never guesses without a terminal.
run_case "ask: no terminal, one installed" MUXASK=1 -- --tailscale --yes
expect_rc 1
expect_out "--mux"
expect_not_called "collie start"
run_case "ask: no terminal, both installed" MUXASK=1 HERDR_INSTALLED=1 -- --tailscale --yes
expect_rc 1
expect_out "--mux"
expect_not_called "collie start"
run_case "ask: neither installed, no terminal" MUXASK=1 HC_INSTALLED=0 -- --tailscale --yes
expect_rc 1
expect_out "--mux"
run_case "ask: nothing installed is not marked" MUXASK=1 HC_INSTALLED=0 ASK=2 -- --tailscale --yes
expect_no_out "(installed)"
run_case "ask: second answer" MUXASK=1 HERDR_INSTALLED=1 ASK=2 -- --tailscale --yes
expect_rc 0
expect_called "collie start [mux=herdr-core]"
run_case "ask: first answer" MUXASK=1 HERDR_INSTALLED=1 STUB_HERDR_RUNNING=1 ASK=1 -- --tailscale --yes
expect_rc 0
expect_called "collie start [mux=herdr]"
run_case "ask: by name" MUXASK=1 HERDR_INSTALLED=1 ASK=herdr-core -- --tailscale --yes
expect_rc 0
expect_called "collie start [mux=herdr-core]"
run_case "ask: nonsense" MUXASK=1 HERDR_INSTALLED=1 ASK=maybe -- --tailscale --yes
expect_rc 1
expect_not_called "collie start"
run_case "ask: the route question comes first" MUXASK=1 ASK=y,2 -- --yes
expect_rc 0
expect_called "collie start [mux=herdr-core]"

# A wrong --mux value is refused, with the usage.
run_case "mux unknown value" -- --tailscale --mux tmux --yes
expect_rc 1
expect_out "herdr-core"
run_case "mux without a value" -- --tailscale --mux
expect_rc 1

# Collie's .env already names another program: say so in the plan, and replace that line where it stands (Collie keeps the
# .env as its own record, and a second COLLIE_MUX line would silently lose to the first).
run_case "env names the other mux" ENVFILE="COLLIE_MUX=herdr" -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_env_line "COLLIE_MUX=herdr-core"
expect_no_env_line "COLLIE_MUX=herdr"
expect_called "collie restart"
expect_order "collie start" "collie restart"
expect_out "COLLIE_MUX"
run_case "env names the other mux, other lines stay" ENVFILE="# mine
COLLIE_PORT=8790
COLLIE_MUX=herdr
COLLIE_X=1" -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_env_line "# mine"
expect_env_line "COLLIE_PORT=8790"
expect_env_line "COLLIE_MUX=herdr-core"
expect_env_line "COLLIE_X=1"
run_case "env names the other mux, quoted" ENVFILE='COLLIE_MUX="herdr"' -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_env_line "COLLIE_MUX=herdr-core"
run_case "env names the other mux, exported" ENVFILE="export COLLIE_MUX=herdr" -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_env_line "COLLIE_MUX=herdr-core"
expect_no_env "export COLLIE_MUX"
run_case "env names the same mux" ENVFILE="COLLIE_MUX=herdr-core" -- --tailscale --mux herdr-core --yes
expect_rc 0
expect_env_line "COLLIE_MUX=herdr-core"
expect_not_called "collie restart"
run_case "env names the other mux, dry run" ENVFILE="COLLIE_MUX=herdr" -- --tailscale --mux herdr-core --dry-run
expect_rc 0
expect_out "from herdr to herdr-core"
expect_env_line "COLLIE_MUX=herdr"
run_case "env names the other mux, declined" ENVFILE="COLLIE_MUX=herdr" ASK=n -- --tailscale --mux herdr-core
expect_rc 6
expect_env_line "COLLIE_MUX=herdr"
expect_not_called "collie start"

# Collie ends up driving something else than what was asked for (a setting from somewhere the script cannot see): stop,
# before a phone is paired with the wrong thing.
run_case "collie reports another mux" STUB_MUX_REPORT=herdr -- --tailscale --mux herdr-core --yes
expect_rc 3
expect_out "herdr"
expect_out "not herdr-core"
expect_not_called "collie pair"

# ==== the reverse proxy route: --proxy --url https://... ====================================================================

# The usual road. The settings land in Collie's .env, Collie starts, the address Collie reports is the one given, and the
# proxy is described, not set up.
run_case "proxy: happy path" -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_env_line "COLLIE_SKIP_SERVE=1"
expect_env_line "COLLIE_PUBLIC_HOSTS=collie.example.com"
expect_env_line "COLLIE_ALLOWED_ORIGINS=https://collie.example.com"
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"
expect_not_called "tailscale"
expect_called "collie start"
expect_called "health http://127.0.0.1:8787/api/health"
expect_called "health https://collie.example.com/api/health"
expect_order "health https://collie.example.com" "collie pair"
expect_out "reverse_proxy 127.0.0.1:8787"
expect_out "ABCD2345"
expect_out "https://"
expect_no_out "tailnet"
if [ "$(find "$sandbox/home/.config/collie/.env" -perm 600 2>/dev/null)" ]; then ok; else bad ".env is not private to the user"; fi

# --url alone means the proxy route.
run_case "proxy: --url alone" -- --url https://collie.example.com --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"

# A slash at the end is dropped, and the port 443 is the default one so it is not part of the host.
run_case "proxy: trailing slash" -- --proxy --url https://collie.example.com/ --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"
run_case "proxy: port 443" -- --proxy --url https://collie.example.com:443 --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_HOSTS=collie.example.com"
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"

# Another port stays: Collie compares the Host header as it arrives, port included.
run_case "proxy: own port" -- --proxy --url https://collie.example.com:8443 --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_HOSTS=collie.example.com:8443"
expect_env_line "COLLIE_ALLOWED_ORIGINS=https://collie.example.com:8443"
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com:8443"

# Addresses that cannot be right stop the script before anything changes.
run_case "proxy: plain http" -- --proxy --url http://collie.example.com --yes
expect_rc 1
expect_out "https://"
expect_not_called "collie start"
expect_no_env "COLLIE_SKIP_SERVE"
run_case "proxy: a path" -- --proxy --url https://collie.example.com/collie --yes
expect_rc 1
expect_out "path"
expect_not_called "collie start"
run_case "proxy: a user name" -- --proxy --url https://me@collie.example.com --yes
expect_rc 1
expect_not_called "collie start"
run_case "proxy: odd characters" -- --proxy --url 'https://collie.example.com;rm' --yes
expect_rc 1
expect_not_called "collie start"
run_case "proxy: no host" -- --proxy --url https:// --yes
expect_rc 1
expect_not_called "collie start"
run_case "proxy: --url without a value" -- --proxy --url
expect_rc 1
expect_out "--url needs a value"
run_case "proxy: no address and nobody to ask" -- --proxy --yes
expect_rc 1
expect_out "--url"
expect_not_called "collie start"

# Without --url the script asks for the address (and then for "Continue?").
run_case "proxy: asks for the address" ASK=https://collie.example.com,y -- --proxy
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"
expect_out "public address"

# The first question leads here too: not Tailscale, then the reverse proxy (1), then the address, then "Continue?".
run_case "proxy: through the route questions" ASK=n,1,https://collie.example.com,y --
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"
run_case "proxy: a second answer that is no choice" ASK=n,7 --
expect_rc 1
expect_not_called "collie start"

# One way at a time.
run_case "two routes" -- --tailscale --proxy --url https://collie.example.com --yes
expect_rc 1
expect_out "one way"
run_case "--url with the local network" -- --lan --url https://collie.example.com --yes
expect_rc 1
expect_out "one way"

# --dry-run says what would be written and writes nothing.
run_case "proxy: dry run" -- --proxy --url https://collie.example.com --dry-run
expect_rc 0
expect_out "COLLIE_PUBLIC_URL=https://collie.example.com"
expect_out "Dry run: nothing was changed."
expect_no_env "COLLIE_SKIP_SERVE"
expect_not_called "collie start"

# A setting that is there with another value is replaced where it stands; the other lines stay; Collie is restarted.
run_case "proxy: old address replaced" ENVFILE="OTHER=1
COLLIE_PUBLIC_URL=https://old.example.com" -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=https://collie.example.com"
expect_no_env "old.example.com"
expect_env_line "OTHER=1"
expect_out "change  COLLIE_PUBLIC_URL from https://old.example.com to https://collie.example.com"
expect_called "collie restart"
expect_order "collie start" "collie restart"

# A Collie that was set up for the local network binds to that address; behind a proxy it must be back on loopback.
run_case "proxy: wide bind from an earlier run" ENVFILE="COLLIE_HOST=192.168.1.20" -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_env_line "COLLIE_HOST=127.0.0.1"
run_case "proxy: loopback bind is left" ENVFILE="COLLIE_HOST=127.0.0.1" -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_env_line "COLLIE_HOST=127.0.0.1"

# Everything is in place already: nothing is written, nothing restarts.
run_case "proxy: already set up" ENVFILE="COLLIE_SKIP_SERVE=1
COLLIE_PUBLIC_HOSTS=collie.example.com
COLLIE_ALLOWED_ORIGINS=https://collie.example.com
COLLIE_PUBLIC_URL=https://collie.example.com" -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_not_called "collie restart"
expect_no_out "      add "
expect_no_out "      change "
expect_out "already"

# A new install has nothing to restart.
run_case "proxy: fresh install" COLLIE_INSTALLED=0 -- --proxy --url https://collie.example.com --yes
expect_rc 0
expect_not_called "collie restart"

# The address does not answer from here: the proxy is described, no code is made, and the way on is said.
run_case "proxy: front door does not answer" STUB_HEALTH_PHONE=down -- --proxy --url https://collie.example.com --yes
expect_rc 3
expect_out "https://collie.example.com"
expect_out "does not answer"
expect_out "reverse_proxy 127.0.0.1:8787"
expect_out "collie pair"
expect_not_called "collie pair"

# Collie itself does not answer: stop.
run_case "proxy: collie down" STUB_HEALTH_LOCAL=down -- --proxy --url https://collie.example.com --yes
expect_rc 4
expect_not_called "collie pair"

# Collie did not read the settings: it still gives another address.
run_case "proxy: settings not picked up" STUB_IGNORE_ENV=1 -- --proxy --url https://collie.example.com --yes
expect_rc 3
expect_out "did not pick up"
expect_not_called "collie pair"

# ==== the local network route: --lan [--host ADDRESS] ==========================================================================

# One address that a phone could reach: it is used without asking.
run_case "lan: happy path" STUB_LOCAL_URL=http://192.168.1.20:8787 -- --lan --yes
expect_rc 0
expect_env_line "COLLIE_HOST=192.168.1.20"
expect_env_line "COLLIE_ALLOW_NON_LOOPBACK_BIND=1"
expect_env_line "COLLIE_SKIP_SERVE=1"
expect_env_line "COLLIE_PUBLIC_HOSTS=192.168.1.20:8787"
expect_env_line "COLLIE_ALLOWED_ORIGINS=http://192.168.1.20:8787"
expect_env_line "COLLIE_PUBLIC_URL=http://192.168.1.20:8787"
expect_called "health http://192.168.1.20:8787/api/health"
expect_called "collie pair"
expect_order "health http://192.168.1.20:8787" "collie pair"
expect_not_called "tailscale"
expect_out "192.168.1.20"
expect_out "not encrypted"
expect_out "same network"
expect_out "ABCD2345"
if [ "$(find "$sandbox/home/.config/collie/.env" -perm 600 2>/dev/null)" ]; then ok; else bad ".env is not private to the user"; fi

# The plan says plainly what this opens up, before the one question.
run_case "lan: the plan names the risk" STUB_LOCAL_URL=http://192.168.1.20:8787 ASK=n -- --lan
expect_rc 6
expect_out "Anyone on your local network"
expect_out "plain http"
expect_not_called "collie start"
expect_no_env "COLLIE_HOST"

# Loopback, link-local, Tailscale and Docker addresses are never offered.
run_case "lan: only reachable addresses are offered" STUB_LOCAL_URL=http://192.168.1.20:8787 -- --lan --dry-run
expect_rc 0
expect_no_out "127.0.0.1:"
expect_no_out "169.254"
expect_no_out "100.64"
expect_no_out "172.17"

# Two addresses and nobody to ask: say how to choose.
run_case "lan: two addresses, no terminal" STUB_IFCONFIG_MODE=two -- --lan --yes
expect_rc 1
expect_out "--host"
expect_out "192.168.1.20"
expect_out "10.0.0.1"
expect_not_called "collie start"

# Two addresses and someone to ask: the second one (also with --yes: a choice is not a confirmation).
run_case "lan: choose the second" STUB_IFCONFIG_MODE=two STUB_LOCAL_URL=http://10.0.0.1:8787 ASK=2 -- --lan --yes
expect_rc 0
expect_env_line "COLLIE_HOST=10.0.0.1"
expect_env_line "COLLIE_PUBLIC_URL=http://10.0.0.1:8787"
run_case "lan: an answer that is no choice" STUB_IFCONFIG_MODE=two ASK=9 -- --lan --yes
expect_rc 1
expect_not_called "collie start"

# --host names the address and nothing is asked.
run_case "lan: --host" STUB_IFCONFIG_MODE=two STUB_LOCAL_URL=http://10.0.0.1:8787 -- --lan --host 10.0.0.1 --yes
expect_rc 0
expect_env_line "COLLIE_HOST=10.0.0.1"
run_case "lan: --host alone" STUB_LOCAL_URL=http://10.0.0.9:8787 -- --host 10.0.0.9 --yes
expect_rc 0
expect_env_line "COLLIE_HOST=10.0.0.9"
run_case "lan: --host=" STUB_LOCAL_URL=http://10.0.0.9:8787 -- --lan --host=10.0.0.9 --yes
expect_rc 0
expect_env_line "COLLIE_HOST=10.0.0.9"
run_case "lan: --host with the proxy" -- --proxy --url https://collie.example.com --host 10.0.0.9 --yes
expect_rc 1
expect_out "one way"

# An address that is none.
run_case "lan: --host too short" -- --lan --host 192.168.1 --yes
expect_rc 1
expect_not_called "collie start"
run_case "lan: --host out of range" -- --lan --host 192.168.1.300 --yes
expect_rc 1
run_case "lan: --host with a port" -- --lan --host 192.168.1.20:8787 --yes
expect_rc 1
run_case "lan: --host a name" -- --lan --host my-mac.local --yes
expect_rc 1
run_case "lan: --host without a value" -- --lan --host
expect_rc 1
expect_out "--host needs a value"

# Nothing a phone could reach.
run_case "lan: no address" STUB_IFCONFIG_MODE=none -- --lan --yes
expect_rc 3
expect_out "local-network address"
expect_out "--host"
expect_not_called "collie start"

# Collie's own port, when the .env sets one, goes into every address.
run_case "lan: another port" ENVFILE="COLLIE_PORT=9000" STUB_LOCAL_URL=http://192.168.1.20:9000 -- --lan --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_HOSTS=192.168.1.20:9000"
expect_env_line "COLLIE_PUBLIC_URL=http://192.168.1.20:9000"

# A Linux computer lists its addresses with `ip`.
run_case "lan: linux" LINUX=1 STUB_LOCAL_URL=http://192.168.1.30:8787 -- --lan --yes
expect_rc 0
expect_env_line "COLLIE_HOST=192.168.1.30"

# Asked by the route questions: not Tailscale, then the local network (2).
run_case "lan: through the route questions" STUB_LOCAL_URL=http://192.168.1.20:8787 ASK=n,2,y --
expect_rc 0
expect_env_line "COLLIE_HOST=192.168.1.20"

# --dry-run writes nothing.
run_case "lan: dry run" STUB_LOCAL_URL=http://192.168.1.20:8787 -- --lan --dry-run
expect_rc 0
expect_out "COLLIE_HOST=192.168.1.20"
expect_out "Dry run: nothing was changed."
expect_no_env "COLLIE_HOST"
expect_not_called "collie start"

# Settings from an earlier proxy run are replaced where they stand.
run_case "lan: after a proxy run" STUB_LOCAL_URL=http://192.168.1.20:8787 ENVFILE="COLLIE_SKIP_SERVE=1
COLLIE_PUBLIC_HOSTS=collie.example.com
COLLIE_ALLOWED_ORIGINS=https://collie.example.com
COLLIE_PUBLIC_URL=https://collie.example.com" -- --lan --yes
expect_rc 0
expect_env_line "COLLIE_PUBLIC_URL=http://192.168.1.20:8787"
expect_env_line "COLLIE_PUBLIC_HOSTS=192.168.1.20:8787"
expect_no_env "collie.example.com"
expect_called "collie restart"

# Collie does not answer on that address: stop.
run_case "lan: collie down" STUB_LOCAL_URL=http://192.168.1.20:8787 STUB_HEALTH_LOCAL=down -- --lan --yes
expect_rc 4
expect_not_called "collie pair"

# Collie did not read the settings.
run_case "lan: settings not picked up" STUB_LOCAL_URL=http://192.168.1.20:8787 STUB_IGNORE_ENV=1 -- --lan --yes
expect_rc 3
expect_out "did not pick up"
expect_not_called "collie pair"

# ==== the Tailscale route refuses what an earlier proxy or local network run left behind ======================================

run_case "tailscale after the proxy" ENVFILE="COLLIE_SKIP_SERVE=1" -- --tailscale --yes
expect_rc 3
expect_out "COLLIE_SKIP_SERVE"
expect_out "$sandbox/home/.config/collie/.env"
expect_not_called "collie start"
run_case "tailscale after the local network" ENVFILE="COLLIE_HOST=192.168.1.20" -- --tailscale --yes
expect_rc 3
expect_out "COLLIE_HOST"
expect_not_called "collie start"
run_case "tailscale with a loopback host" ENVFILE="COLLIE_HOST=127.0.0.1" -- --tailscale --yes
expect_rc 0

# ---- shellcheck, when it is there -----------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    CASE="shellcheck"
    OUT=$(shellcheck -s sh "$SETUP" "$HERE/run.sh" 2>&1)
    LOG=/dev/null
    if [ -z "$OUT" ]; then ok; else bad "shellcheck has findings"; fi
else
    echo "(shellcheck not found: skipped)"
fi

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
