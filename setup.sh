#!/bin/sh
# dogr setup.sh - put Collie on this computer and pair your phone with it.
#
# Route: Tailscale. The script never edits a file of yours. It calls Collie's own commands and checks the result:
#   1. install Collie, only if it is not installed yet (Collie's own installer);
#   2. `collie start`: runs Collie in the background and publishes it on your tailnet;
#   3. check that Collie answers on this computer and on its Tailscale address;
#   4. `collie pair`, last of all, so the one-time code has all of its ten minutes left.
# A tailnet without HTTPS certificates (Headscale, for one) is handled too: with your agreement (or --http) the script adds
# one line, COLLIE_SERVE_MODE=http, to Collie's own .env, so Collie is published over plain http inside the tailnet.
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
Usage: setup.sh [--tailscale] [--http] [--yes] [--dry-run] [--help]

Puts Collie on this computer, publishes it on your Tailscale network, and shows a QR code that pairs your phone.

  --tailscale   You reach this computer through Tailscale (the only route available so far). Without it, the script asks.
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

    # ask_yes_no QUESTION [DEFAULT]: ask on the terminal. DEFAULT is "y" (the default) or "n": what a bare Enter means.
    # Returns 0 for yes, 1 for no. No answer at all (the terminal closed, or Ctrl-D) counts as "no": nothing is changed on a guess.
    ask_yes_no() {
        have_tty || return 1
        # Open the terminal once: each question then reads the next line, also when the "terminal" is a file in a test.
        if [ "$TTY_OPEN" != 1 ]; then
            exec 3<"$TTY"
            TTY_OPEN=1
        fi
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

    # Say what is about to happen, then ask once.
    if find_collie; then
        installed=$(collie version 2>/dev/null </dev/null | head -n 1)
        install_line="Collie is already installed (${installed:-version unknown}); it is left as it is."
    else
        install_line="Install Collie into ${COLLIE_DIR:-~/.local/share/collie} with Collie's own installer (${INSTALL_URL})."
    fi
    say "This will:"
    say "  1. $install_line"
    say "  2. Start Collie in the background (launchd on macOS, systemd --user on Linux)."
    say "  3. Publish it on your tailnet with 'tailscale serve' (HTTPS, port 443 -> 127.0.0.1:8787)."
    say "  4. Create a one-time pairing code and show it as a QR code."
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

    # Step 2: start it. Collie prints lines starting with "setup:" for what is missing; it never stops on them itself.
    say ""
    say "==> Starting Collie"
    log=$WORK/start.log
    rcfile=$WORK/start.rc
    run_collie start
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

    # Step 3: check that it answers, on this computer and on the Tailscale address the phone will use.
    say ""
    say "==> Checking that Collie answers"
    status=$(collie status --json 2>/dev/null </dev/null | head -n 1)
    local_url=$(json_string "$status" localUrl)
    phone_url=$(json_string "$status" phoneUrl)
    : "${local_url:=http://127.0.0.1:8787}"
    retry health_ok "$local_url" || die 4 "Collie does not answer at $local_url. Run 'collie logs' to see why."
    say "  on this computer: $local_url answers"
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

    # Step 4: the pairing code comes last, so its ten minutes start when the phone is ready to use it.
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
