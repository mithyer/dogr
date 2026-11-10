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
for tool in sh sed grep head tee cat mktemp rm sleep uname cp mkdir chmod; do
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
        cp "$STUB_INSTALLER" "$out"
        ;;
esac
EOF

# collie: records the call and prints what the real commands print (shapes taken from Collie's own source).
cat >"$STUBS/collie" <<'EOF'
#!/bin/sh
echo "collie $*" >>"$STUB_LOG"
case $1 in
    version) echo "collie 1.27.0" ;;
    start)
        [ "${STUB_START_RC:-0}" = 0 ] || { echo "start went wrong"; exit "$STUB_START_RC"; }
        echo "  ✓ Collie is running · v1.27.0"
        if [ -n "${STUB_SETUP:-}" ]; then
            echo "  setup: $STUB_SETUP"
            echo "    fix: do the thing it says"
        fi
        ;;
    status)
        printf '{"running":true,"version":"1.27.0","instance":"default","port":8787,"localUrl":"%s","phoneUrl":%s,"pairedDevices":0}\n' \
            "$STUB_LOCAL_URL" "$STUB_PHONE_JSON"
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
chmod +x "$STUBS/curl" "$STUBS/collie" "$STUBS/installer.sh"

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
#   ASK=text          what the person types when the script asks a question
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
        echo "export DOGR_TTY=$sandbox/tty"
        echo "export DOGR_TRIES=2"
        echo "export DOGR_POLL_DELAY=0"
    } >"$wrapper"
    installed=1
    ask=
    mode="file"
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case $1 in
            COLLIE_INSTALLED=0) installed=0 ;;
            ASK=*) ask=${1#ASK=} ;;
            PIPE=1) mode="pipe" ;;
            CUT=1) mode="cut" ;;
            *=*) printf 'export %s=%s\n' "${1%%=*}" "$(quote "${1#*=}")" >>"$wrapper" ;;
        esac
        shift
    done
    [ "${1:-}" = "--" ] && shift
    echo 'exec sh "$@"' >>"$wrapper"
    cp "$STUBS/curl" "$sandbox/path/curl"
    if [ "$installed" = 1 ]; then cp "$STUBS/collie" "$sandbox/path/collie"; fi
    # With no ASK there is no terminal at all: DOGR_TTY keeps pointing at a file that does not exist.
    if [ -n "$ask" ]; then printf '%s\n' "$ask" >"$sandbox/tty"; fi
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

# Asking: "no" to Tailscale says the route is not scripted and changes nothing.
run_case "not tailscale" ASK=n --
expect_rc 2
expect_out "Only the Tailscale route is scripted"
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

# It also works the way people run it: the whole script arrives through a pipe.
run_case "through a pipe" PIPE=1 -- --tailscale --yes
expect_rc 0
expect_called "collie pair"

# A script cut off half way runs nothing: main() is only called on the last line.
run_case "cut off download" CUT=1 -- --tailscale --yes
expect_not_called "collie"
expect_not_called "curl"

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
