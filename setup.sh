#!/bin/sh
# dogr setup.sh - put Collie on this computer and pair your phone with it.
#
# Route: Tailscale. It calls the commands of the programs it sets up and checks the result:
#   1. install Collie, only if it is not installed yet (Collie's own installer);
#   2. make sure the terminal program Collie drives is there and running: herdr or herdr-core (--mux picks one). A missing
#      one is installed with its own installer; herdr-core is started with `hc server start`; herdr has to be opened by you;
#   3. `collie start`: runs Collie in the background and publishes it on your tailnet;
#   4. check that Collie answers on this computer and on its Tailscale address, and drives the program you picked;
#   5. `collie pair`, last of all, so the one-time code has all of its ten minutes left.
# Two lines of Collie's own .env may change, each one only in the way the plan says before you agree: COLLIE_MUX, when it
# names the other terminal program than the one you picked (replaced where it stands), and, on a tailnet without HTTPS
# certificates (Headscale, for one), COLLIE_SERVE_MODE=http (added with your agreement or --http), so Collie is published
# over plain http inside the tailnet.
#
# Run it:        curl -fsSL https://raw.githubusercontent.com/mithyer/dogr/main/setup.sh | sh
# Options go after `-s --`:   ... | sh -s -- --tailscale --yes
#
# Safe to run again: a step that is already done is skipped, and nothing is installed twice.
#
# Exit codes: 0 done | 1 wrong use or unsupported computer | 2 route not scripted yet | 3 Collie needs setup
#             4 Collie did not start or does not answer | 5 Collie could not be installed | 6 stopped by you
#
# Environment (all optional):
#   DOGR_COLLIE_TAG           install this Collie release (for example v1.27.0) instead of the newest
#   DOGR_COLLIE_INSTALL_URL   where Collie's installer comes from (default https://colliepwa.dev/install.sh)
#   DOGR_HERDR_INSTALL_URL    where herdr's installer comes from (default https://herdr.dev/install.sh)
#   DOGR_HERDR_CORE_INSTALL_URL   where herdr-core's installer comes from (default https://releases.herdr.dev/core/install.sh)
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
    ROUTE=
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

    usage() {
        cat <<'EOF'
Usage: setup.sh [--tailscale] [--mux herdr|herdr-core] [--http] [--yes] [--dry-run] [--help]

Puts Collie on this computer, publishes it on your Tailscale network, and shows a QR code that pairs your phone.

  --tailscale   You reach this computer through Tailscale (the only route available so far). Without it, the script asks.
  --mux NAME    The terminal program Collie drives: herdr (the terminal app) or herdr-core (a background service). One
                that is missing is installed with its own installer. Without this option the script uses the one that is
                installed, and asks when both or neither are. If Collie's .env names the other one, the plan says so and
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
        {
            printf '%s\n' "Which terminal program should Collie drive?"
            printf '%s\n' "  1) herdr       the terminal app: you open it in a terminal and your agents run inside it"
            printf '%s\n' "  2) herdr-core  a background service: no terminal app to open"
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

    # env_mux: the value of the last COLLIE_MUX line in Collie's .env (an optional leading "export", quotes and a trailing
    # comment are dropped), or nothing
    env_mux() {
        [ -f "$ENV_FILE" ] || return 0
        sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}COLLIE_MUX=//p' "$ENV_FILE" | tail -n 1 |
            sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
    }

    # set_env_mux: put COLLIE_MUX=$MUX where the COLLIE_MUX lines of Collie's .env stand now. Collie keeps that file as its
    # own record and reads it before the environment, so a second line further down would lose to the first. The file is
    # written through cat, so its owner and mode stay.
    set_env_mux() {
        tmp=$WORK/env.new
        sed 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}COLLIE_MUX=.*$/COLLIE_MUX='"$MUX"'/' "$ENV_FILE" >"$tmp" || return 1
        cat "$tmp" >"$ENV_FILE"
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
            --tailscale) ROUTE=tailscale ;;
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

    # The first question: which way does the phone reach this computer? Tailscale is the only way scripted so far.
    if [ -z "$ROUTE" ]; then
        have_tty || die 1 "there is no terminal to ask on. Run again with --tailscale (and --yes) to answer for you."
        if ask_yes_no "Do you reach this computer from your phone through Tailscale?"; then
            ROUTE=tailscale
        else
            say "Only the Tailscale route is scripted so far. Your own domain with a reverse proxy, or the local network"
            say "without encryption, are set up by hand for now: see Collie's deployment guide (docs/deployment.md)."
            exit 2
        fi
    fi

    # Which terminal program does Collie drive? The one named, else the only one that is installed, else ask.
    have_herdr=0
    have_hc=0
    if find_herdr; then have_herdr=1; fi
    if find_hc; then have_hc=1; fi
    if [ -z "$MUX" ]; then
        if [ "$have_herdr" = 1 ] && [ "$have_hc" = 0 ]; then
            MUX=herdr
            say "Found herdr on this computer, so Collie will drive it (use --mux herdr-core to pick the other)."
        elif [ "$have_hc" = 1 ] && [ "$have_herdr" = 0 ]; then
            MUX=herdr-core
            say "Found herdr-core on this computer, so Collie will drive it (use --mux herdr to pick the other)."
        else
            have_tty || die 1 "there is no terminal to ask which terminal program Collie should drive. Run again with --mux herdr or --mux herdr-core."
            ask_mux
        fi
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
    plan "Start Collie in the background (launchd on macOS, systemd --user on Linux), driving $MUX."
    plan "Publish it on your tailnet with 'tailscale serve' (HTTPS, port 443 -> 127.0.0.1:8787)."
    plan "Create a one-time pairing code and show it as a QR code."
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
        curl -fsSL "$INSTALL_URL" -o "$script" || die 5 "could not download Collie's installer from $INSTALL_URL"
        # The installer must not read our standard input: when this script itself comes through a pipe, it would eat it.
        if [ -n "${DOGR_COLLIE_TAG:-}" ]; then
            COLLIE_TAG=$DOGR_COLLIE_TAG sh "$script" </dev/null || die 5 "Collie's installer failed. Its output is above."
        else
            sh "$script" </dev/null || die 5 "Collie's installer failed. Its output is above."
        fi
        find_collie || die 5 "Collie was installed but the 'collie' command was not found. Add ~/.local/bin to your PATH and run this again."
    fi

    # Step 2: the terminal program Collie drives: install it when it is missing, then make sure it runs.
    if [ "$have_mux" != 1 ]; then
        say ""
        say "==> Installing $MUX"
        script=$WORK/mux-install.sh
        curl -fsSL "$MUX_URL" -o "$script" || die 5 "could not download the $MUX installer from $MUX_URL"
        sh "$script" </dev/null || die 5 "the $MUX installer failed. Its output is above."
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
        set_env_mux || die 3 "could not change $ENV_FILE"
        say "  $ENV_FILE: COLLIE_MUX changed from $ENV_MUX to $MUX"
    fi
    COLLIE_MUX=$MUX
    export COLLIE_MUX

    # Step 3: start Collie. It prints lines starting with "setup:" for what is missing; it never stops on them itself.
    say ""
    say "==> Starting Collie"
    log=$WORK/start.log
    rcfile=$WORK/start.rc
    run_collie start
    # A running Collie may have started before the setting changed, so it is restarted to read it.
    if [ "$ENV_CHANGED" = 1 ]; then
        say ""
        say "==> Restarting Collie so it drives $MUX"
        run_collie restart
    fi
    # One finding has a way out that this script can take: a tailnet without HTTPS certificates. Any other finding, or this one
    # together with another, is for the person to fix first.
    if [ "$(grep -c '^ *setup:' "$log")" = 1 ] && grep -q 'HTTPS certificates are off for your tailnet' "$log"; then
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
    say "On your phone: open Herdogr, tap +, then 'Scan QR code' and point the camera at the code above."
    say "No camera? Paste the link above into the Address field, or type the address and the code."
    say "The code works once and for ${minutes:-a few} minutes. For a new one, run: collie pair"
    if [ "$SWITCHED" = 1 ]; then
        say "The address starts with http://. Tailscale encrypts the traffic between your devices; the address is just not HTTPS."
    fi
    exit 0
}

main "$@"
