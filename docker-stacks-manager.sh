#!/usr/bin/env bash
#
# Docker Stack Manager - Interactive TUI for Docker Compose stacks
# Runs on Linux, macOS and Windows under WSL2, in bash 4+ or zsh. macOS's own
# bash 3.2 is too old, so there the script runs itself under zsh, which macOS
# has built in. On Windows itself, use the PowerShell edition:
# docker-stacks-manager.ps1
#
# Requirements:
#   - bash 4.0+ or zsh 5.1+
#   - docker and docker compose
#   - Standard POSIX utilities: awk, sed, grep, cut, tr, wc, find, sort
#   - Optional: bc (for traffic stats - will use awk fallback if missing)
#

# Pick the shell. zsh runs the script in its ksh mode, plus the options that
# make it behave like bash where the script relies on it. Code that differs
# between the shells is in the helpers below (read_char, keys_of, lower, ...).
if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -R ksh
    setopt BASH_REMATCH BSD_ECHO TYPESET_SILENT POSIX_TRAPS NO_NOMATCH PIPE_FAIL
    DSM_SHELL=zsh
elif [ -n "${BASH_VERSION:-}" ] && { [ "${BASH_VERSINFO[0]}" -lt 4 ] || [ "${DSM_SHELL:-}" = zsh ]; }; then
    # bash 3.2 (macOS) lacks associative arrays: hand over to zsh
    if command -v zsh >/dev/null 2>&1; then
        exec zsh "$0" "$@"
    fi
    echo "Error: this script needs bash 4.0 or higher, or zsh"
    echo "Current version: $BASH_VERSION"
    exit 1
else
    DSM_SHELL=bash
fi
set -o pipefail
DSM_SELF="$0"
NL=$'\n'   # zsh does not expand $'\n' inside ${var:+...}

VERSION="1.2.1"
DSM_REPO="datstma/docker-stacks-manager"

# Base directory holding the stacks: -d/--dir, else $DSM_DIR, else the
# current working directory
BASE_DIR="${DSM_DIR:-$(pwd)}"

# ============================================================================
# Shell compatibility (bash 4+ and zsh)
# ============================================================================

# Read characters without echo into variable $1: read_char VAR [COUNT]
# [TIMEOUT]. Returns 0, 142 on timeout, or 1 at the end of input.
read_char() {
    local _start=$SECONDS _rc _c="" _tty=""
    if [ "$DSM_SHELL" = zsh ]; then
        # zsh's read -k on stdin leaves the terminal line-buffered and echoing:
        # switch to key-at-a-time input (the TUI keeps it on, see key_mode)
        if [ "$KEY_MODE" != 1 ] && [ -t 0 ]; then
            _tty=$(stty -g 2>/dev/null)
            stty -icanon -echo min 1 time 0 2>/dev/null
        fi
        if [ -n "${3:-}" ]; then read -r -k "${2:-1}" -u 0 -t "$3" _c; else read -r -k "${2:-1}" -u 0 _c; fi
        _rc=$?
        [ -n "$_tty" ] && stty "$_tty" 2>/dev/null
        # Enter: bash gives an empty string, zsh the newline itself
        case $_c in "$NL"|$'\r') _c="" ;; esac
        printf -v "$1" '%s' "$_c"
        # zsh returns 1 both on timeout and at the end of input
        if [ $_rc -ne 0 ] && [ -n "${3:-}" ]; then
            case $3 in 0*) return 142 ;; esac
            [ $((SECONDS - _start)) -ge 1 ] && return 142
            return 1
        fi
        return $_rc
    fi
    if [ -n "${3:-}" ]; then read -rsn "${2:-1}" -t "$3" "$1"; else read -rsn "${2:-1}" "$1"; fi
    _rc=$?
    [ $_rc -gt 128 ] && return 142
    return $_rc
}

# zsh only: key_mode on|off switches the terminal between key-at-a-time
# input without echo (TUI menus) and normal line input (prompts)
KEY_MODE=0
KEY_MODE_SAVED=""
key_mode() {
    [ "$DSM_SHELL" = zsh ] && [ -t 0 ] || return 0
    if [ "$1" = on ]; then
        [ -z "$KEY_MODE_SAVED" ] && KEY_MODE_SAVED=$(stty -g 2>/dev/null)
        stty -icanon -echo min 1 time 0 2>/dev/null
        KEY_MODE=1
    elif [ -n "$KEY_MODE_SAVED" ]; then
        stty "$KEY_MODE_SAVED" 2>/dev/null
        KEY_MODE=0
    fi
}

# Split $3 on the characters in $2 into the array named $1
read_array() {
    if [ "$DSM_SHELL" = zsh ]; then
        IFS=$2 read -rA "$1" <<< "$3"
    else
        IFS=$2 read -ra "$1" <<< "$3"
    fi
}

# Keys of the associative array named $1, in the array KEYS
keys_of() {
    if [ "$DSM_SHELL" = zsh ]; then
        eval 'KEYS=("${(@k)'"$1"'[@]}")'
    else
        eval 'KEYS=("${!'"$1"'[@]}")'
    fi
}

# $1 in lowercase, in REPLY
lower() {
    if [ "$DSM_SHELL" = zsh ]; then
        eval 'REPLY=${(L)1}'
    else
        eval 'REPLY=${1,,}'
    fi
}

# ============================================================================
# Compatibility checks and fallbacks
# ============================================================================

# Check for required commands
check_requirements() {
    local missing=()

    # Required commands
    for cmd in docker awk sed grep cut tr wc find sort; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for the docker compose v2 plugin (standalone docker-compose v1 is not supported)
    if ! docker compose version &>/dev/null; then
        missing+=("docker compose (v2 plugin)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# Check if bc is available (optional, for traffic stats)
HAS_BC=false
if command -v bc &>/dev/null; then
    HAS_BC=true
fi

# Portable math function - uses bc if available, falls back to awk
calc() {
    local expr="$1"
    if $HAS_BC; then
        echo "$expr" | bc -l 2>/dev/null || echo "0"
    else
        awk "BEGIN {printf \"%.0f\", $expr}" 2>/dev/null || echo "0"
    fi
}

# Portable integer math
calc_int() {
    local expr="$1"
    if $HAS_BC; then
        echo "scale=0; $expr" | bc 2>/dev/null || echo "0"
    else
        awk "BEGIN {printf \"%.0f\", $expr}" 2>/dev/null || echo "0"
    fi
}

# Portable date parsing - convert a Docker timestamp (ISO 8601, UTC) to epoch
# Works on both GNU and BSD date
date_to_epoch() {
    local datestr="$1"
    # Try GNU date first (Linux, WSL)
    date -d "$datestr" +%s 2>/dev/null && return
    # BSD/macOS date: drop fractional seconds and the trailing Z, parse as UTC
    local trimmed="${datestr%%.*}"
    trimmed="${trimmed%Z}"
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "$trimmed" +%s 2>/dev/null && return
    # Fallback: try parsing with awk
    echo "$datestr" | awk -F'[-T:.]' '{
        # Basic ISO 8601 parsing
        cmd = "date -d \"" $1"-"$2"-"$3" "$4":"$5":"$6"\" +%s 2>/dev/null"
        cmd | getline epoch
        close(cmd)
        if (epoch != "") print epoch
        else print 0
    }'
}

# Compose file names, in the order docker compose itself prefers them
COMPOSE_FILENAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

# Print one compose file per stack directory (up to 2 levels below BASE_DIR),
# sorted by path. If a directory has several, the one docker compose would
# pick is used, so a stack is never listed twice.
find_compose_files() {
    local name_args=() n
    for n in "${COMPOSE_FILENAMES[@]}"; do
        name_args+=(-o -name "$n")
    done
    find "$BASE_DIR" -maxdepth 2 -type f \( "${name_args[@]:1}" \) 2>/dev/null |
        awk -v order="${COMPOSE_FILENAMES[*]}" '
            BEGIN { n = split(order, names, " "); for (i = 1; i <= n; i++) rank[names[i]] = i }
            {
                file = $0; dir = file; sub(/\/[^\/]*$/, "", dir)
                base = substr(file, length(dir) + 2)
                if (!(dir in best) || rank[base] < rank[bestbase[dir]]) { best[dir] = file; bestbase[dir] = base }
            }
            END { for (d in best) print best[d] }' |
        sort
}


# Wait for any key press (not just Enter)
press_any_key() {
    local msg="${1:-Press any key to continue...}"
    echo -ne "${DIM}${msg}${NC}"
    read_char _key
    echo
}

# ============================================================================
# Self-update (-U/--update)
# ============================================================================

# Print the real path of this script (or of $1), following symlinks; BSD has
# no readlink -f
self_path() {
    local file="${1:-$DSM_SELF}" dir link
    while [ -L "$file" ]; do
        dir="$(cd -P "$(dirname "$file")" && pwd)"
        link="$(readlink "$file")"
        [[ "$link" == /* ]] && file="$link" || file="$dir/$link"
    done
    echo "$(cd -P "$(dirname "$file")" && pwd)/$(basename "$file")"
}

# Fetch a URL to stdout with curl or wget
fetch_url() {
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 2 "$1"
    elif command -v wget &>/dev/null; then
        wget -qO- "$1"
    else
        echo "Error: --update needs curl or wget" >&2
        return 1
    fi
}

# version_gt A B: true if version A is newer than B (numeric, dot separated)
version_gt() {
    awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = na > nb ? na : nb
        for (i = 1; i <= n; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 1
    }'
}

# Replace this script with the latest release (or $DSM_UPDATE_REF: a tag or
# branch). A git clone of the project is updated with git pull instead.
self_update() {
    local self dir ref url tmp new_version
    self="$(self_path)"
    dir="$(dirname "$self")"

    if command -v git &>/dev/null && git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null &&
        git -C "$dir" remote get-url origin 2>/dev/null | grep -qE "${DSM_REPO#*/}(\.git)?/?$"; then
        echo "Updating the git clone in $dir"
        git -C "$dir" pull --ff-only || return 1
        echo "Now at $("$self" --version)"
        return 0
    fi

    ref="${DSM_UPDATE_REF:-}"
    if [ -z "$ref" ]; then
        ref="$(fetch_url "https://api.github.com/repos/$DSM_REPO/releases/latest" 2>/dev/null |
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$ref" ] || ref=main
    fi
    url="https://raw.githubusercontent.com/$DSM_REPO/$ref/docker-stacks-manager.sh"

    if [ ! -w "$dir" ] || [ ! -w "$self" ]; then
        echo "Error: no write access to $self" >&2
        echo "Run the update with sudo: sudo $self --update" >&2
        return 1
    fi

    echo "Checking $ref for a new version..."
    tmp="$(mktemp "$dir/.docker-stacks-manager.XXXXXX")" || return 1
    if ! fetch_url "$url" > "$tmp"; then
        rm -f "$tmp"
        echo "Error: could not download $url" >&2
        return 1
    fi
    new_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$tmp" | head -1)"
    if [ -z "$new_version" ] || ! head -1 "$tmp" | grep -q '^#!.*bash' || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Error: the download from $url is not a valid docker-stacks-manager script" >&2
        return 1
    fi
    if ! version_gt "$new_version" "$VERSION" && [ -z "${DSM_UPDATE_REF:-}" ]; then
        rm -f "$tmp"
        echo "Already up to date ($VERSION)"
        return 0
    fi
    chmod 755 "$tmp"
    mv -f "$tmp" "$self" || { rm -f "$tmp"; return 1; }
    echo "Updated $self: $VERSION -> $new_version"
}

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'
REVERSE='\033[7m'

# Parse arguments
SHOW_STATS=false
SHOW_PORTS=false
SHOW_IMAGES=false
VERBOSE=false
WATCH_MODE=false
INTERACTIVE=false
SHOW_NETWORK=false
IMPORT_MODE=""
IMPORT_TARGET=""
CONVERT_CMD=""
PRINT_ONLY=false

show_help() {
    cat <<EOF
Docker Stack Manager $VERSION - status and control for Docker Compose stacks

Usage: ${0##*/} [options]

Stacks are the compose files in the base directory and its direct
subdirectories. The base directory is the current one unless -d or
\$DSM_DIR says otherwise.

Views:
  -I, --interactive  Interactive TUI (recommended)
  -v, --verbose      Status with CPU/memory, ports and images
  -s, --stats        Status with CPU/memory
  -p, --ports        Status with port mappings
  -i, --images       Status with image versions
  -w, --watch        Redraw the status every 5 seconds
  -n, --network      Networks and the containers on them

Import (turn plain docker containers into compose stacks, guided):
  --import NAME      Convert a container started with docker run; without
                     NAME, lists the containers compose doesn't manage
  --convert CMD...   Convert a docker run command: the rest of the line, or
                     read from stdin. Must come last
  --print            With --import/--convert: only print the compose file

Options:
  -d, --dir DIR      Directory holding your stacks (default: current directory)
  -U, --update       Update this script to the latest release
  -V, --version      Print the version
  -h, --help         Show this help

Environment:
  DSM_DIR            Default for --dir
  DSM_REFRESH        TUI refresh interval in seconds (default 5)

https://github.com/$DSM_REPO
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--stats) SHOW_STATS=true ;;
        -p|--ports) SHOW_PORTS=true ;;
        -i|--images) SHOW_IMAGES=true ;;
        -v|--verbose) VERBOSE=true; SHOW_STATS=true; SHOW_PORTS=true; SHOW_IMAGES=true ;;
        -w|--watch) WATCH_MODE=true ;;
        -I|--interactive) INTERACTIVE=true ;;
        -n|--network) SHOW_NETWORK=true ;;
        -d|--dir)
            [[ -n "${2:-}" ]] || { echo "Error: $1 needs a directory" >&2; exit 1; }
            BASE_DIR="$2"; shift ;;
        --dir=*) BASE_DIR="${1#--dir=}" ;;
        --import)
            if [[ -n "${2:-}" && "$2" != -* ]]; then IMPORT_MODE=container; IMPORT_TARGET="$2"; shift
            else IMPORT_MODE=list; fi ;;
        --import=*) IMPORT_MODE=container; IMPORT_TARGET="${1#--import=}" ;;
        --convert) shift; IMPORT_MODE="command"; CONVERT_CMD="$*"; break ;;
        --print) PRINT_ONLY=true ;;
        -U|--update) self_update; exit $? ;;
        -V|--version) echo "docker-stacks-manager $VERSION"; exit 0 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

if ! _dir="$(cd "$BASE_DIR" 2>/dev/null && pwd)"; then
    echo "Error: stacks directory not found: $BASE_DIR" >&2
    exit 1
fi
BASE_DIR="$_dir"; unset _dir

check_requirements

# Format an epoch as local "YYYY-MM-DD HH:MM" (GNU date -d @, BSD date -r).
# Pass "zone" as a second argument to append the time zone, e.g. "CET".
epoch_to_local() {
    local fmt='+%Y-%m-%d %H:%M'
    [ "${2:-}" = zone ] && fmt='+%Y-%m-%d %H:%M %Z'
    date -d "@$1" "$fmt" 2>/dev/null || date -r "$1" "$fmt" 2>/dev/null
}

# Parse a Watchtower log time like "2026-11-09 04:00:00 +0100 CET" to epoch
watchtower_time_to_epoch() {
    local str="${1% *}"  # drop the zone name, keep the numeric offset
    date -d "$str" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S %z" "$str" +%s 2>/dev/null
}

# Work out when Watchtower will next check for updates. Usage:
#   watchtower_next_check <container> <recent logs>
# 1. With WATCHTOWER_DEBUG, Watchtower logs "Scheduled next run: ..." after
#    each session; that is used when it's still in the future.
# 2. Otherwise it's derived from the settings:
#    WATCHTOWER_SCHEDULE      6-field cron (sec min hour dom month dow). Daily
#                             schedules are resolved in the container's TZ;
#                             anything else is shown as-is.
#    WATCHTOWER_POLL_INTERVAL seconds between runs (default 86400), counted
#                             from the "Scheduling first run" line at startup.
watchtower_next_check() {
    local id="$1" logs="$2" now env schedule interval tz line epoch
    now=$(date +%s)

    line=$(printf '%s\n' "$logs" | grep "Scheduled next run: " | tail -1 |
        sed -n 's/.*Scheduled next run: \([0-9-]* [0-9:]* [+-][0-9]* [A-Za-z0-9+-]*\).*/\1/p')
    if [ -n "$line" ]; then
        epoch=$(watchtower_time_to_epoch "$line")
        if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ]; then
            # "2026-11-09 04:00:00 +0100 CET" -> "2026-11-09 04:00 CET"
            echo "$line" | awk '{print $1, substr($2, 1, 5), $4}'
            return
        fi
    fi

    env=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null)
    schedule=$(printf '%s\n' "$env" | sed -n 's/^WATCHTOWER_SCHEDULE=//p' | tr -d "\"'")
    interval=$(printf '%s\n' "$env" | sed -n 's/^WATCHTOWER_POLL_INTERVAL=//p')
    tz=$(printf '%s\n' "$env" | sed -n 's/^TZ=//p')

    if [ -n "$schedule" ]; then
        case "$schedule" in
            @daily|@midnight) schedule="0 0 0 * * *" ;;
        esac
        local sec min hour dom mon dow extra
        read -r sec min hour dom mon dow extra <<< "$schedule"
        if [[ "$sec" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ &&
              "$dom" =~ ^[*?]$ && "$mon" =~ ^[*?]$ && "$dow" =~ ^[*?]$ && -z "$extra" ]]; then
            local clock h m s delta
            # Epoch and clock from one call, so a second ticking over between two can't skew it
            clock=$(TZ="${tz:-${TZ:-}}" date '+%s %H %M %S')
            read -r now h m s <<< "$clock"
            delta=$(( (10#$hour * 3600 + 10#$min * 60 + 10#$sec) - (10#$h * 3600 + 10#$m * 60 + 10#$s) ))
            [ "$delta" -le 0 ] && delta=$((delta + 86400))
            echo "$(TZ="${tz:-${TZ:-}}" epoch_to_local $((now + delta)) zone) (daily)"
        else
            echo "schedule: $schedule"
        fi
        return
    fi

    [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -gt 0 ] || interval=86400
    # Startup line, e.g. msg="Scheduling first run: 2026-09-23 04:00:00 +0200 CEST"
    local first=""
    line=$(docker logs "$id" 2>&1 | grep "Scheduling first run: " | tail -1 |
        sed -n 's/.*Scheduling first run: \([0-9-]* [0-9:]* [+-][0-9]* [A-Za-z0-9+-]*\).*/\1/p')
    [ -n "$line" ] && first=$(watchtower_time_to_epoch "$line")
    if [ -n "$first" ]; then
        local next=$first
        [ "$next" -le "$now" ] && next=$(( first + ((now - first) / interval + 1) * interval ))
        echo "$(epoch_to_local "$next" zone) (every $(format_duration "$interval"))"
    else
        echo "every $(format_duration "$interval")"
    fi
}

# Summarise Watchtower's most recent session from its logs:
# which images were new, which containers were recreated, which couldn't be checked.
watchtower_last_session() {
    local logs="$1" session done_line when scanned updated
    # Lines after the second-to-last "Session done", up to and including the last one
    session=$(printf '%s\n' "$logs" | awk '
        { buf = buf $0 "\n" }
        /msg="Session done"/ { last = buf; buf = "" }
        END { printf "%s", last }')
    [ -z "$session" ] && return

    done_line=$(printf '%s' "$session" | grep 'msg="Session done"' | tail -1)
    # time="2026-11-08T04:02:12+01:00" -> 2026-11-08 04:02
    when=$(printf '%s\n' "$done_line" | sed -n 's/.*time="\([0-9-]*\)T\([0-9]*:[0-9]*\).*/\1 \2/p')
    scanned=$(printf '%s\n' "$done_line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p')
    updated=$(printf '%s\n' "$done_line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')

    local images recreated unreachable
    # Comma-separated, one entry per name, in log order
    list() { awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g'; }
    images=$(printf '%s' "$session" | sed -n 's/.*msg="Found new \([^ ]*\) image.*/\1/p' | list)
    recreated=$(printf '%s' "$session" | sed -n 's/.*msg="Creating \/\([^"]*\)".*/\1/p' | list)
    unreachable=$(printf '%s' "$session" | sed -n 's/.*msg="Unable to update container \\"\/\([^\\]*\)\\".*/\1/p' | list)

    echo -e "\n  Last check: ${when:-unknown} ${DIM}(${scanned:-?} scanned, ${updated:-0} updated)${NC}"
    if [ -n "$images" ]; then
        echo -e "    ${GREEN}✓${NC} New images: $images"
        [ -n "$recreated" ] && echo -e "    ${GREEN}↻${NC} Recreated: $recreated"
    elif [ -z "$unreachable" ]; then
        echo -e "    ${DIM}No updates needed${NC}"
    fi
    [ -n "$unreachable" ] && echo -e "    ${YELLOW}⚠${NC} Could not check: $unreachable ${DIM}(see: docker logs watchtower)${NC}"
}

# 86400 -> 24h, 5400 -> 1h 30m, 300 -> 5m
format_duration() {
    local secs=$1 h m
    h=$((secs / 3600)); m=$(( (secs % 3600) / 60 ))
    if [ "$h" -gt 0 ] && [ "$m" -gt 0 ]; then echo "${h}h ${m}m"
    elif [ "$h" -gt 0 ]; then echo "${h}h"
    else echo "${m}m"
    fi
}

# Function to format uptime
format_uptime() {
    local started=$1
    local now=${2:-$(date +%s)}
    local diff=$((now - started))
    
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    
    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# ============================================================================
# Snapshot: everything the views need, from a handful of docker calls
# ============================================================================
# Per stack (index 0..n-1, sorted by directory)
declare -a STACK_NAMES STACK_DIRS STACK_STATUS STACK_CIDS STACK_UP STACK_TOTAL STACK_UNHEALTHY
# Per container, keyed by short (12-character) container ID
declare -A C_SERVICE C_NAME C_STATE C_STATUS C_HEALTH C_KIND C_STARTED C_RESTARTS \
           C_AUTO C_IMAGE C_NETMODE C_PORTS C_NETS C_CPU C_MEM C_STACK
declare -A C_ID_BY_FULL   # full ID -> short ID (network_mode: container:<full ID>)
SNAPSHOT_TIME=""

# Compose's default project name for a directory: lowercase, only [a-z0-9_-]
compose_project_name() {
    lower "$1"
    echo "${REPLY//[^a-z0-9_-]/}"
}

# Load all stacks and their containers with three docker calls (ps, inspect,
# and with "stats" also docker stats, which takes ~2s and runs in the
# background meanwhile).
#
# Containers are matched to stacks by Compose's working-directory label, or
# failing that by project name (stacks started from elsewhere, e.g. Dockge).
# Each container gets a C_KIND:
#   up    running
#   done  exited 0 with restart policy "no"/"on-failure": a finished one-shot job
#   down  anything else that isn't running (stopped, crashed, restarting, created)
# A stack is "stopped" when nothing is up, "partial" when something is down,
# "unhealthy" when all are up but a healthcheck fails, otherwise "running".
load_snapshot() {
    local want_stats=${1:-} stats_file="" stats_pid=""
    if [ "$want_stats" = stats ]; then
        stats_file=$(mktemp)
        docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}' > "$stats_file" 2>/dev/null &
        stats_pid=$!
    fi

    STACK_NAMES=(); STACK_DIRS=(); STACK_STATUS=(); STACK_CIDS=()
    STACK_UP=(); STACK_TOTAL=(); STACK_UNHEALTHY=()
    C_SERVICE=(); C_NAME=(); C_STATE=(); C_STATUS=(); C_HEALTH=(); C_KIND=(); C_STARTED=()
    C_RESTARTS=(); C_AUTO=(); C_IMAGE=(); C_NETMODE=(); C_PORTS=(); C_NETS=()
    C_CPU=(); C_MEM=(); C_STACK=(); C_ID_BY_FULL=()

    local -A by_dir=() by_project=()
    local i=0 file dir pname
    while IFS= read -r file; do
        dir="${file%/*}"
        STACK_DIRS[i]="$dir"
        STACK_NAMES[i]="${dir##*/}"
        STACK_CIDS[i]=""
        # Unquoted subscripts: zsh would keep quotes as part of the key
        by_dir[$dir]=$i
        pname=$(compose_project_name "${dir##*/}")
        by_project[$pname]=$i
        i=$((i + 1))
    done < <(find_compose_files)

    local project wdir service id name state cstatus idx ids=()
    while IFS='|' read -r project wdir service id name state cstatus; do
        [ -z "$id" ] && continue
        idx=""
        [ -n "$wdir" ] && idx="${by_dir[$wdir]:-}"
        [ -z "$idx" ] && [ -n "$project" ] && idx="${by_project[$project]:-}"
        [ -z "$idx" ] && continue
        C_SERVICE[$id]="$service"
        C_NAME[$id]="$name"
        C_STATE[$id]="$state"
        C_STATUS[$id]="$cstatus"
        C_STACK[$id]=$idx
        case "$cstatus" in
            *"(unhealthy)"*)        C_HEALTH[$id]=unhealthy ;;
            *"(healthy)"*)          C_HEALTH[$id]=healthy ;;
            *"(health: starting)"*) C_HEALTH[$id]=starting ;;
            *)                      C_HEALTH[$id]="" ;;
        esac
        STACK_CIDS[idx]+="$id "
        ids+=("$id")
    done < <(docker ps -a --filter label=com.docker.compose.project \
        --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.service"}}|{{.ID}}|{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null |
        sort -t '|' -k2,2 -k3,3)

    if [ ${#ids[@]} -gt 0 ]; then
        local full started restarts auto image netmode exitcode policy ports nets
        while IFS='|' read -r full started restarts auto image netmode exitcode policy ports nets; do
            id="${full:0:12}"
            [ -n "${C_STATE[$id]+x}" ] || continue
            C_ID_BY_FULL[$full]=$id
            C_RESTARTS[$id]="$restarts"
            C_AUTO[$id]="$auto"
            C_IMAGE[$id]="$image"
            C_NETMODE[$id]="$netmode"
            C_PORTS[$id]="${ports% }"
            C_NETS[$id]="${nets% }"
            C_STARTED[$id]=""
            if [ "${C_STATE[$id]}" = running ]; then
                C_KIND[$id]=up
                C_STARTED[$id]=$(date_to_epoch "$started")
            elif [ "${C_STATE[$id]}" = exited ] && [ "$exitcode" = 0 ] &&
                 [[ -z "$policy" || "$policy" == no || "$policy" == on-failure ]]; then
                C_KIND[$id]=done
            else
                C_KIND[$id]=down
            fi
        done < <(docker inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.RestartCount}}|{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}|{{.Config.Image}}|{{.HostConfig.NetworkMode}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}|{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{$p}} -> {{(index $c 0).HostPort}} {{end}}{{end}}|{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "${ids[@]}" 2>/dev/null)
    fi

    if [ -n "$stats_pid" ]; then
        wait "$stats_pid"
        local cpu mem
        while IFS='|' read -r id cpu mem; do
            [ -n "$id" ] && [ -n "${C_STATE[$id]+x}" ] || continue
            C_CPU[$id]="$cpu"
            C_MEM[$id]="${mem%% /*}"
        done < "$stats_file"
        rm -f "$stats_file"
    fi

    local up total unhealthy
    for ((i = 0; i < ${#STACK_DIRS[@]}; i++)); do
        up=0; total=0; unhealthy=0
        for id in ${STACK_CIDS[i]}; do
            case "${C_KIND[$id]:-down}" in
                up)
                    up=$((up + 1)); total=$((total + 1))
                    if [ "${C_HEALTH[$id]}" = unhealthy ]; then unhealthy=$((unhealthy + 1)); fi
                    ;;
                down) total=$((total + 1)) ;;
            esac
        done
        STACK_UP[i]=$up
        STACK_TOTAL[i]=$total
        STACK_UNHEALTHY[i]=$unhealthy
        if [ $up -eq 0 ]; then STACK_STATUS[i]=stopped
        elif [ $up -lt $total ]; then STACK_STATUS[i]=partial
        elif [ $unhealthy -gt 0 ]; then STACK_STATUS[i]=unhealthy
        else STACK_STATUS[i]=running
        fi
    done
    SNAPSHOT_TIME=$(date '+%H:%M:%S')
}

# Index of the stack in directory $1 (after a reload, indexes can shift)
stack_index_of() {
    local i
    for ((i = 0; i < ${#STACK_DIRS[@]}; i++)); do
        [ "${STACK_DIRS[i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

# The following set REPLY instead of printing, to avoid a subshell per line
# when the TUI redraws.

# Stack state for menus: "● 3/3 running", "◐ 2/3 running", "○ stopped"
stack_badge() {
    local i=$1
    local up=${STACK_UP[i]} total=${STACK_TOTAL[i]} bad=${STACK_UNHEALTHY[i]}
    case "${STACK_STATUS[i]}" in
        running)   REPLY="${GREEN}●${NC} ${up}/${total} running" ;;
        unhealthy) REPLY="${YELLOW}●${NC} ${up}/${total} running ${RED}· ${bad} unhealthy${NC}" ;;
        partial)   REPLY="${YELLOW}◐${NC} ${up}/${total} running" ;;
        *)         REPLY="${RED}○${NC} ${DIM}stopped${NC}" ;;
    esac
}

# Coloured state marker for a container
container_dot() {
    local id=$1
    case "${C_KIND[$id]:-down}" in
        up)
            case "${C_HEALTH[$id]}" in
                unhealthy) REPLY="${RED}●${NC}" ;;
                starting)  REPLY="${YELLOW}●${NC}" ;;
                *)         REPLY="${GREEN}●${NC}" ;;
            esac
            ;;
        done) REPLY="${DIM}✓${NC}" ;;
        *)    REPLY="${RED}●${NC}" ;;
    esac
}

# What a container is doing: uptime and badges if up, Docker's status otherwise
container_summary() {
    local id=$1 now=${2:-$(date +%s)}
    case "${C_KIND[$id]:-down}" in
        up)
            REPLY=""
            if [ -n "${C_STARTED[$id]}" ] && [ "${C_STARTED[$id]}" != 0 ]; then
                REPLY="${DIM}$(format_uptime "${C_STARTED[$id]}" "$now")${NC}"
            fi
            [ "${C_HEALTH[$id]}" = unhealthy ] && REPLY+=" ${RED}unhealthy${NC}"
            [ "${C_HEALTH[$id]}" = starting ] && REPLY+=" ${YELLOW}starting${NC}"
            [ -n "${C_RESTARTS[$id]}" ] && [ "${C_RESTARTS[$id]}" -gt 0 ] 2>/dev/null && REPLY+=" ${YELLOW}↻${C_RESTARTS[$id]}${NC}"
            [ "${C_AUTO[$id]}" = true ] && REPLY+=" ${CYAN}[auto]${NC}"
            ;;
        done) REPLY="${DIM}done (${C_STATUS[$id]})${NC}" ;;
        *)    REPLY="${RED}${C_STATUS[$id]:-${C_STATE[$id]}}${NC}" ;;
    esac
    REPLY="${REPLY# }"
}

# Name of the container whose network a container shares, if any
shared_network_host() {
    local mode="${C_NETMODE[$1]}"
    REPLY=""
    if [[ "$mode" == container:* ]]; then
        local full="${mode#container:}"
        local host="${C_ID_BY_FULL[$full]:-}"
        REPLY="${C_NAME[$host]:-${full:0:12}}"
    fi
}

# ============================================================================
# Import: docker run commands and existing containers -> compose stacks
# ============================================================================
# Both sources fill one service spec: SP holds single values, SPL lists
# (newline-separated), SPN_* per-network settings. Keys starting with "_" are
# internal; the others are compose keys. spec_to_compose prints the file.
declare -A SP=() SPL=() SPN_IP=() SPN_IP6=() SPN_ALIAS=()

sp_reset() { SP=(); SPL=(); SPN_IP=(); SPN_IP6=(); SPN_ALIAS=(); }
sp_add() { SPL[$1]+="${SPL[$1]:+$NL}$2"; }
sp_has() { [[ $'\n'"${SPL[$1]:-}"$'\n' == *$'\n'"$2"$'\n'* ]]; }
sp_add_once() { sp_has "$1" "$2" || sp_add "$1" "$2"; }
sp_warn() { sp_add_once _warn "$1"; }

# Split a shell command line into words (TOKS) the way a POSIX shell would
# quote them: '...', "..." with \ escapes, backslash-newline continuations and
# # comments. Variables are not expanded. Returns 1 on an unclosed quote.
shell_split() {
    local s=$1 i=0 n=${#1} c nx tok="" have=0 q=""
    TOKS=()
    while (( i < n )); do
        c=${s:$i:1}
        if [[ $q == "'" ]]; then
            if [[ $c == "'" ]]; then q=""; else tok+=$c; fi
        elif [[ $q == '"' ]]; then
            if [[ $c == '"' ]]; then
                q=""
            elif [[ $c == '\' ]]; then
                nx=${s:$((i + 1)):1}
                case $nx in
                    '"'|'\'|'$'|'`') tok+=$nx; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) tok+=$c ;;
                esac
            else
                tok+=$c
            fi
        else
            case $c in
                ' '|$'\t'|$'\n'|$'\r')
                    if (( have )); then TOKS+=("$tok"); tok=""; have=0; fi ;;
                "'"|'"') q=$c; have=1 ;;
                '\')
                    nx=${s:$((i + 1)):1}
                    i=$((i + 1))
                    if [[ $nx == $'\r' && ${s:$((i + 1)):1} == $'\n' ]]; then
                        i=$((i + 1))
                    elif [[ $nx != $'\n' ]]; then
                        tok+=$nx; have=1
                    fi ;;
                '#') if (( have )); then tok+=$c; else break; fi ;;
                *) tok+=$c; have=1 ;;
            esac
        fi
        i=$((i + 1))
    done
    [[ -z $q ]] || return 1
    (( have )) && TOKS+=("$tok")
    return 0
}

# Long name of a docker run short option, in REPLY ("" if unknown)
run_short_opt() {
    case $1 in
        d) REPLY=--detach ;; i) REPLY=--interactive ;; t) REPLY=--tty ;;
        P) REPLY=--publish-all ;; q) REPLY=--quiet ;; a) REPLY=--attach ;;
        c) REPLY=--cpu-shares ;; e) REPLY=--env ;; h) REPLY=--hostname ;;
        l) REPLY=--label ;; m) REPLY=--memory ;; p) REPLY=--publish ;;
        u) REPLY=--user ;; v) REPLY=--volume ;; w) REPLY=--workdir ;;
        *) REPLY="" ;;
    esac
}

# How a docker run option converts, in REPLY: s:KEY (one value), l:KEY (a
# list), b:KEY (a flag set to true), x (handled by run_apply), f / v (dropped
# flag / dropped option with a value), "" (unknown)
run_option_kind() {
    case $1 in
        --name) REPLY=s:container_name ;;
        --hostname) REPLY=s:hostname ;;
        --domainname) REPLY=s:domainname ;;
        --user) REPLY=s:user ;;
        --workdir) REPLY=s:working_dir ;;
        --restart) REPLY=s:restart ;;
        --pid) REPLY=s:pid ;;
        --ipc) REPLY=s:ipc ;;
        --uts) REPLY=s:uts ;;
        --userns) REPLY=s:userns_mode ;;
        --cgroupns) REPLY=s:cgroup ;;
        --cgroup-parent) REPLY=s:cgroup_parent ;;
        --isolation) REPLY=s:isolation ;;
        --runtime) REPLY=s:runtime ;;
        --platform) REPLY=s:platform ;;
        --pull) REPLY=s:pull_policy ;;
        --mac-address) REPLY=s:mac_address ;;
        --stop-signal) REPLY=s:stop_signal ;;
        --shm-size) REPLY=s:shm_size ;;
        --memory) REPLY=s:mem_limit ;;
        --memory-reservation) REPLY=s:mem_reservation ;;
        --memory-swap) REPLY=s:memswap_limit ;;
        --memory-swappiness) REPLY=s:mem_swappiness ;;
        --cpus) REPLY=s:cpus ;;
        --cpu-shares) REPLY=s:cpu_shares ;;
        --cpuset-cpus) REPLY=s:cpuset ;;
        --cpu-period) REPLY=s:cpu_period ;;
        --cpu-quota) REPLY=s:cpu_quota ;;
        --pids-limit) REPLY=s:pids_limit ;;
        --oom-score-adj) REPLY=s:oom_score_adj ;;
        --log-driver) REPLY=s:_log_driver ;;
        --gpus) REPLY=s:_gpus ;;
        --health-cmd) REPLY=s:_health_cmd ;;
        --health-interval) REPLY=s:_health_interval ;;
        --health-timeout) REPLY=s:_health_timeout ;;
        --health-retries) REPLY=s:_health_retries ;;
        --health-start-period) REPLY=s:_health_start_period ;;
        --health-start-interval) REPLY=s:_health_start_interval ;;
        --env) REPLY=l:environment ;;
        --env-file) REPLY=l:env_file ;;
        --label) REPLY=l:labels ;;
        --annotation) REPLY=l:annotations ;;
        --publish) REPLY=l:ports ;;
        --expose) REPLY=l:expose ;;
        --tmpfs) REPLY=l:tmpfs ;;
        --add-host) REPLY=l:extra_hosts ;;
        --link) REPLY=l:external_links ;;
        --dns) REPLY=l:dns ;;
        --dns-search) REPLY=l:dns_search ;;
        --dns-option) REPLY=l:dns_opt ;;
        --cap-add) REPLY=l:cap_add ;;
        --cap-drop) REPLY=l:cap_drop ;;
        --device) REPLY=l:devices ;;
        --device-cgroup-rule) REPLY=l:device_cgroup_rules ;;
        --security-opt) REPLY=l:security_opt ;;
        --group-add) REPLY=l:group_add ;;
        --sysctl) REPLY=l:sysctls ;;
        --ulimit) REPLY=l:_ulimits ;;
        --log-opt) REPLY=l:_log_opts ;;
        --storage-opt) REPLY=l:_storage_opt ;;
        --network-alias) REPLY=l:_aliases ;;
        --volume|--mount|--network|--ip|--ip6|--entrypoint|--stop-timeout|--volumes-from) REPLY=x ;;
        --tty) REPLY=b:tty ;;
        --interactive) REPLY=b:stdin_open ;;
        --privileged) REPLY=b:privileged ;;
        --init) REPLY=b:init ;;
        --read-only) REPLY=b:read_only ;;
        --oom-kill-disable) REPLY=b:oom_kill_disable ;;
        --no-healthcheck) REPLY=b:_health_disable ;;
        --detach|--rm|--publish-all|--sig-proxy|--quiet|--disable-content-trust|--help) REPLY=f ;;
        --attach|--cidfile|--detach-keys|--label-file|--volume-driver|--blkio-weight|--blkio-weight-device|\
        --cpu-rt-period|--cpu-rt-runtime|--cpuset-mems|--device-read-bps|--device-read-iops|\
        --device-write-bps|--device-write-iops|--kernel-memory|--link-local-ip|--io-maxbandwidth|\
        --io-maxiops) REPLY=v ;;
        *) REPLY="" ;;
    esac
}

run_apply() { # run_apply <option> <kind> <value>
    local opt=$1 kind=$2 val=$3
    case $kind in
        s:*) SP[${kind#s:}]=$val ;;
        l:*) sp_add "${kind#l:}" "$val" ;;
        b:*) SP[${kind#b:}]=true ;;
        f)
            case $opt in
                --rm) sp_warn "--rm has no compose equivalent: compose keeps the container (docker compose run --rm is the one-off form)" ;;
                --publish-all) sp_warn "--publish-all (-P) is not converted: list the ports under ports:" ;;
            esac ;;
        v)
            case $opt in
                --attach|--cidfile|--detach-keys) ;;
                *) sp_warn "$opt is not converted" ;;
            esac ;;
        x)
            case $opt in
                --volume) spec_add_volume "$val" ;;
                --mount) spec_add_mount "$val" ;;
                --network) spec_add_network "$val" ;;
                --ip) SP[_ip]=$val ;;
                --ip6) SP[_ip6]=$val ;;
                --entrypoint) SPL[entrypoint]=$val; SP[_entry_set]=1 ;;
                --stop-timeout) SP[stop_grace_period]=${val}s ;;
                --volumes-from) sp_add volumes_from "container:$val" ;;
            esac ;;
    esac
}

# A -v/--volume value; named volumes are also declared at the top level
spec_add_volume() {
    local v=$1 src
    if [[ $v == *:* && ! $v =~ ^[A-Za-z]:[\\/] ]]; then
        src=${v%%:*}
        case $src in
            /*|~*|'$'*) ;;
            .*) sp_warn "The relative path $src is now relative to the stack folder" ;;
            *[/\\]*) ;;
            ?*) sp_add_once _volumes "$src" ;;
        esac
    fi
    sp_add volumes "$v"
}

# A --mount value (type=bind|volume|tmpfs,source=...,target=...,readonly)
spec_add_mount() {
    local kv k v type=volume src="" dst="" ro="" size="" mode="" extra=""
    local -a parts
    read_array parts , "$1"
    for kv in "${parts[@]}"; do
        k=${kv%%=*}
        if [[ $kv == *=* ]]; then v=${kv#*=}; else v=true; fi
        lower "$k"
        case $REPLY in
            type) type=$v ;;
            source|src) src=$v ;;
            destination|dst|target) dst=$v ;;
            readonly|ro) [[ $v == true || $v == 1 ]] && ro=:ro ;;
            tmpfs-size) size=$v ;;
            tmpfs-mode) mode=$v ;;
            *) extra+=" $k" ;;
        esac
    done
    if [[ -z $dst ]]; then
        sp_warn "--mount $1 has no target; skipped"
        return
    fi
    case $type in
        bind|volume)
            [[ -n $extra ]] && sp_warn "--mount options dropped:$extra (the long volume syntax can keep them)"
            if [[ -n $src ]]; then spec_add_volume "$src:$dst$ro"; else sp_add volumes "$dst"; fi ;;
        tmpfs)
            v=${size:+size=$size}
            [[ -n $mode ]] && v+="${v:+,}mode=$mode"
            sp_add tmpfs "$dst${v:+:$v}" ;;
        *) sp_warn "--mount type=$type is not converted" ;;
    esac
}

# A --network value: a mode (host, none, container:x) or a network to join
spec_add_network() {
    local v=$1 kv name="" ip="" ip6="" aliases=""
    local -a parts
    case $v in
        default) ;;
        host|none|bridge|container:*) SP[network_mode]=$v ;;
        *=*)
            read_array parts , "$v"
            for kv in "${parts[@]}"; do
                case ${kv%%=*} in
                    name) name=${kv#*=} ;;
                    ip) ip=${kv#*=} ;;
                    ip6) ip6=${kv#*=} ;;
                    alias) aliases+="${aliases:+$NL}${kv#*=}" ;;
                    *) sp_warn "--network option ${kv%%=*} is not converted" ;;
                esac
            done
            if [[ -n $name ]]; then
                spec_add_network "$name"
                [[ -n $ip ]] && SPN_IP[$name]=$ip
                [[ -n $ip6 ]] && SPN_IP6[$name]=$ip6
                [[ -n $aliases ]] && SPN_ALIAS[$name]=$aliases
            fi ;;
        *) sp_add_once networks "$v" ;;
    esac
}

# Fill the spec from the words of a docker run (or create) command. Returns 1
# with the reason in REPLY when it isn't one.
run_to_spec() {
    local -a t=("$@")
    local n=$# i=0 j a opt val kind c hasval found=0
    sp_reset
    SP[_source]=run
    for ((j = 0; j < n; j++)); do
        a=${t[j]##*/}
        if [[ $a == docker || $a == podman ]]; then found=1; i=$((j + 1)); break; fi
    done
    if (( found )); then
        # Global options (docker --context x run ...)
        while (( i < n )) && [[ ${t[i]} == -* ]]; do
            case ${t[i]} in
                -H|--host|-c|--context|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey) i=$((i + 2)) ;;
                *) i=$((i + 1)) ;;
            esac
        done
        [[ ${t[i]:-} == container ]] && i=$((i + 1))
        if [[ ${t[i]:-} != run && ${t[i]:-} != create ]]; then
            REPLY="not a docker run command"
            return 1
        fi
        i=$((i + 1))
    elif [[ ${t[0]:-} == run || ${t[0]:-} == create ]]; then
        i=1
    fi

    while (( i < n )); do
        a=${t[i]}
        case $a in
            '|'|'||'|'&&'|';'|'&'|'>'|'>>')
                sp_warn "Stopped at \"$a\": only the docker run command itself is converted"
                break ;;
            --) i=$((i + 1)); break ;;
            --?*)
                if [[ $a == *=* ]]; then opt=${a%%=*}; val=${a#*=}; hasval=1; else opt=$a; val=""; hasval=0; fi
                case $opt in
                    --net) opt=--network ;;
                    --net-alias) opt=--network-alias ;;
                esac
                run_option_kind "$opt"; kind=$REPLY
                case $kind in
                    b:*|f)
                        if (( ! hasval )) || [[ $val != false && $val != 0 ]]; then
                            run_apply "$opt" "$kind" ""
                        fi ;;
                    '') sp_warn "$opt is not a docker run option this tool knows; skipped" ;;
                    *)
                        if (( ! hasval )); then
                            i=$((i + 1))
                            if (( i >= n )); then REPLY="$opt needs a value"; return 1; fi
                            val=${t[i]}
                        fi
                        run_apply "$opt" "$kind" "$val" ;;
                esac ;;
            -?*)
                for ((j = 1; j < ${#a}; j++)); do
                    c=${a:$j:1}
                    run_short_opt "$c"; opt=$REPLY
                    if [[ -z $opt ]]; then sp_warn "-$c is not a docker run option this tool knows; skipped"; continue; fi
                    run_option_kind "$opt"; kind=$REPLY
                    case $kind in
                        b:*|f) run_apply "$opt" "$kind" "" ;;
                        *)
                            val=${a:$((j + 1))}
                            if [[ -z $val ]]; then
                                i=$((i + 1))
                                if (( i >= n )); then REPLY="-$c needs a value"; return 1; fi
                                val=${t[i]}
                            fi
                            run_apply "$opt" "$kind" "$val"
                            break ;;
                    esac
                done ;;
            *) break ;;
        esac
        i=$((i + 1))
    done

    if (( i >= n )) || [[ ${t[i]} == [\|\&\;\>]* ]]; then
        REPLY="no image in the command"
        return 1
    fi
    SP[image]=${t[i]}
    for ((i = i + 1; i < n; i++)); do
        case ${t[i]} in
            '|'|'||'|'&&'|';'|'&'|'>'|'>>')
                sp_warn "Stopped at \"${t[i]}\": only the docker run command itself is converted"
                break ;;
        esac
        sp_add command "${t[i]}"
        SP[_cmd_set]=1
    done
    spec_finish
}

# Turn a docker run command line (as typed or pasted) into the spec
convert_command() {
    local line
    if ! shell_split "$1"; then REPLY="the command has an unclosed quote"; return 1; fi
    if [ ${#TOKS[@]} -eq 0 ]; then REPLY="no command given"; return 1; fi
    run_to_spec "${TOKS[@]}" || return 1
    line=${1//\\$'\n'/ }
    line=${line//$'\r'/}
    line=${line//$'\n'/ }
    SP[_origin]="this docker run command:"
    SP[_cmdline]=$(printf '%s' "$line" | tr -s ' ' | sed 's/^ //; s/ $//')
    return 0
}

# Nanoseconds as a compose duration (30s, 500ms)
ns_to_duration() {
    local n=$1
    if (( n % 1000000000 == 0 )); then REPLY="$((n / 1000000000))s"
    elif (( n % 1000000 == 0 )); then REPLY="$((n / 1000000))ms"
    else REPLY="$((n / 1000))us"
    fi
}

# Bytes as a compose size (512m, 2g)
bytes_to_size() {
    local n=$1
    if (( n % 1073741824 == 0 )); then REPLY="$((n / 1073741824))g"
    elif (( n % 1048576 == 0 )); then REPLY="$((n / 1048576))m"
    elif (( n % 1024 == 0 )); then REPLY="$((n / 1024))k"
    else REPLY="${n}b"
    fi
}

# Fill the spec from an existing container: one docker inspect for the
# container and one for its image, whose defaults (environment, labels,
# command, ...) are left out so the compose file holds only what was set.
inspect_to_spec() {
    local tab=$'\t' recs imgrecs line k v last="" id12 x name ip aliases a
    local -a a_list
    local -A r=() img=() covered=()
    local fmt="id${tab}{{.Id}}
name${tab}{{.Name}}
image${tab}{{index .Config \"Image\"}}
imageid${tab}{{.Image}}
state${tab}{{.State.Status}}
hostname${tab}{{index .Config \"Hostname\"}}
domainname${tab}{{index .Config \"Domainname\"}}
user${tab}{{index .Config \"User\"}}
workdir${tab}{{index .Config \"WorkingDir\"}}
{{range index .Config \"Env\"}}env${tab}{{.}}
{{end}}{{range index .Config \"Cmd\"}}cmd${tab}{{.}}
{{end}}{{range index .Config \"Entrypoint\"}}entry${tab}{{.}}
{{end}}{{range \$k, \$v := index .Config \"Labels\"}}label${tab}{{\$k}}={{\$v}}
{{end}}tty${tab}{{index .Config \"Tty\"}}
stdin${tab}{{index .Config \"OpenStdin\"}}
stopsignal${tab}{{index .Config \"StopSignal\"}}
health${tab}{{json (index .Config \"Healthcheck\")}}
{{with index .Config \"Healthcheck\"}}{{range index . \"Test\"}}htest${tab}{{.}}
{{end}}hinterval${tab}{{index . \"Interval\"}}
htimeout${tab}{{index . \"Timeout\"}}
hretries${tab}{{index . \"Retries\"}}
hstart${tab}{{index . \"StartPeriod\"}}
{{end}}{{with .HostConfig}}{{range index . \"Binds\"}}bind${tab}{{.}}
{{end}}{{range index . \"Mounts\"}}mount${tab}{{index . \"Type\"}}|{{index . \"Source\"}}|{{index . \"Target\"}}|{{index . \"ReadOnly\"}}
{{end}}{{range \$p, \$b := index . \"PortBindings\"}}{{range \$b}}port${tab}{{index . \"HostIp\"}}|{{index . \"HostPort\"}}|{{\$p}}
{{end}}{{end}}{{with index . \"RestartPolicy\"}}restart${tab}{{index . \"Name\"}}|{{index . \"MaximumRetryCount\"}}
{{end}}netmode${tab}{{index . \"NetworkMode\"}}
privileged${tab}{{index . \"Privileged\"}}
{{range index . \"CapAdd\"}}capadd${tab}{{.}}
{{end}}{{range index . \"CapDrop\"}}capdrop${tab}{{.}}
{{end}}{{range index . \"Devices\"}}device${tab}{{index . \"PathOnHost\"}}:{{index . \"PathInContainer\"}}:{{index . \"CgroupPermissions\"}}
{{end}}{{range index . \"Dns\"}}dns${tab}{{.}}
{{end}}{{range index . \"DnsSearch\"}}dnssearch${tab}{{.}}
{{end}}{{range index . \"DnsOptions\"}}dnsopt${tab}{{.}}
{{end}}{{range index . \"ExtraHosts\"}}host${tab}{{.}}
{{end}}{{range index . \"SecurityOpt\"}}secopt${tab}{{.}}
{{end}}{{range \$k, \$v := index . \"Sysctls\"}}sysctl${tab}{{\$k}}={{\$v}}
{{end}}{{range \$k, \$v := index . \"Tmpfs\"}}tmpfs${tab}{{\$k}}{{if \$v}}:{{\$v}}{{end}}
{{end}}shm${tab}{{index . \"ShmSize\"}}
memory${tab}{{index . \"Memory\"}}
nanocpus${tab}{{index . \"NanoCpus\"}}
pid${tab}{{index . \"PidMode\"}}
ipc${tab}{{index . \"IpcMode\"}}
{{range index . \"GroupAdd\"}}groupadd${tab}{{.}}
{{end}}readonly${tab}{{index . \"ReadonlyRootfs\"}}
init${tab}{{index . \"Init\"}}
{{with index . \"LogConfig\"}}logtype${tab}{{index . \"Type\"}}
{{range \$k, \$v := index . \"Config\"}}logopt${tab}{{\$k}}={{\$v}}
{{end}}{{end}}runtime${tab}{{index . \"Runtime\"}}
gpus${tab}{{with index . \"DeviceRequests\"}}{{len .}}{{end}}
{{range index . \"Ulimits\"}}ulimit${tab}{{index . \"Name\"}}={{index . \"Soft\"}}:{{index . \"Hard\"}}
{{end}}autoremove${tab}{{index . \"AutoRemove\"}}
publishall${tab}{{index . \"PublishAllPorts\"}}
{{range index . \"Links\"}}link${tab}{{.}}
{{end}}{{end}}{{range .Mounts}}cmount${tab}{{index . \"Type\"}}|{{index . \"Name\"}}|{{index . \"Destination\"}}
{{end}}{{range \$n, \$c := .NetworkSettings.Networks}}net${tab}{{\$n}}|{{with index \$c \"IPAMConfig\"}}{{index . \"IPv4Address\"}}{{end}}|{{with index \$c \"Aliases\"}}{{join . \",\"}}{{end}}
{{end}}"
    local imgfmt="{{with .Config}}{{range index . \"Env\"}}env${tab}{{.}}
{{end}}{{range index . \"Cmd\"}}cmd${tab}{{.}}
{{end}}{{range index . \"Entrypoint\"}}entry${tab}{{.}}
{{end}}{{range \$k, \$v := index . \"Labels\"}}label${tab}{{\$k}}={{\$v}}
{{end}}workdir${tab}{{index . \"WorkingDir\"}}
user${tab}{{index . \"User\"}}
stopsignal${tab}{{index . \"StopSignal\"}}
health${tab}{{json (index . \"Healthcheck\")}}
{{end}}"
    sp_reset
    SP[_source]=container
    SP[_dollar]=escape
    if ! recs=$(docker inspect --type container --format "$fmt" "$1" 2>/dev/null) || [[ -z $recs ]]; then
        REPLY="no such container: $1"
        return 1
    fi
    while IFS= read -r line; do
        if [[ $line != *"$tab"* ]]; then
            # A value with a line break: only its first line is kept
            [[ -n $last ]] && sp_warn "A ${last} value spans several lines; only its first line was kept"
            continue
        fi
        k=${line%%"$tab"*}; v=${line#*"$tab"}
        [[ $v == "<no value>" ]] && v=""
        r[$k]+="${r[$k]+$NL}$v"
        last=$k
    done <<< "$recs"
    imgrecs=$(docker image inspect --format "$imgfmt" "${r[imageid]}" 2>/dev/null)
    [[ -z $imgrecs ]] && sp_warn "The image ${r[image]} is no longer on this host, so its defaults could not be told apart from settings made with docker run"
    while IFS= read -r line; do
        [[ $line == *"$tab"* ]] || continue
        k=${line%%"$tab"*}; v=${line#*"$tab"}
        [[ $v == "<no value>" ]] && v=""
        img[$k]+="${img[$k]+$NL}$v"
    done <<< "$imgrecs"

    name=${r[name]#/}
    SP[_container]=$name
    SP[_state]=${r[state]}
    while IFS= read -r v; do
        if [[ $v == com.docker.compose.project=* ]]; then
            REPLY="$name is already part of the compose stack ${v#*=}"
            return 1
        fi
    done <<< "${r[label]:-}"
    SP[_origin]="the container \"$name\""
    SP[image]=${r[image]}
    [[ ${r[image]} == sha256:* ]] && sp_warn "The container's image has no name any more; put the right image: in"
    SP[container_name]=$name
    id12=${r[id]:0:12}

    case ${r[netmode]} in
        host|none) SP[network_mode]=${r[netmode]} ;;
        container:*)
            x=$(docker inspect --format '{{.Name}}' "${r[netmode]#container:}" 2>/dev/null)
            SP[network_mode]="container:${x#/}"
            [[ -z $x ]] && SP[network_mode]=${r[netmode]} ;;
    esac
    if [[ -n ${r[hostname]} && ${r[hostname]} != "$id12" && -z ${SP[network_mode]:-} ]]; then
        SP[hostname]=${r[hostname]}
    fi
    [[ -n ${r[domainname]} ]] && SP[domainname]=${r[domainname]}
    [[ -n ${r[user]} && ${r[user]} != "${img[user]:-}" ]] && SP[user]=${r[user]}
    [[ -n ${r[workdir]} && ${r[workdir]} != "${img[workdir]:-}" ]] && SP[working_dir]=${r[workdir]}
    [[ -n ${r[stopsignal]} && ${r[stopsignal]} != "${img[stopsignal]:-}" ]] && SP[stop_signal]=${r[stopsignal]}

    while IFS= read -r v; do
        [[ -z $v ]] && continue
        [[ $'\n'"${img[env]:-}"$'\n' == *$'\n'"$v"$'\n'* ]] || sp_add environment "$v"
    done <<< "${r[env]:-}"
    while IFS= read -r v; do
        [[ -z $v || $v == com.docker.compose.* ]] && continue
        [[ $'\n'"${img[label]:-}"$'\n' == *$'\n'"$v"$'\n'* ]] || sp_add labels "$v"
    done <<< "${r[label]:-}"
    # Setting an entrypoint drops the image's command, so both go in together
    if [[ ${r[entry]:-} != "${img[entry]:-}" ]]; then
        SPL[entrypoint]=${r[entry]:-}; SP[_entry_set]=1
        if [[ -n ${r[cmd]:-} ]]; then SPL[command]=${r[cmd]}; SP[_cmd_set]=1; fi
    elif [[ ${r[cmd]:-} != "${img[cmd]:-}" ]]; then
        SPL[command]=${r[cmd]:-}; SP[_cmd_set]=1
    fi
    [[ ${r[tty]} == true ]] && SP[tty]=true
    [[ ${r[stdin]} == true ]] && SP[stdin_open]=true
    if [[ ${r[health]} != null && ${r[health]} != "${img[health]:-null}" ]]; then
        if [[ ${r[htest]:-} == NONE ]]; then
            SP[_health_disable]=true
        else
            SPL[_health_test]=${r[htest]:-}
            for x in interval:hinterval timeout:htimeout start_period:hstart; do
                v=${r[${x#*:}]:-0}
                if [[ $v =~ ^[0-9]+$ ]] && (( v > 0 )); then ns_to_duration "$v"; SP[_health_${x%%:*}]=$REPLY; fi
            done
            [[ ${r[hretries]:-0} != 0 ]] && SP[_health_retries]=${r[hretries]}
        fi
    fi

    # Volumes: -v (Binds), --mount (Mounts), and anonymous volumes, which keep
    # their ID as the name so their data carries over to the new container
    while IFS= read -r v; do
        [[ -z $v ]] && continue
        spec_add_volume "$v"
        if [[ $v =~ ^[A-Za-z]:[\\/] ]]; then x=${v:2}; x=${x#*:}; else x=${v#*:}; fi
        covered[${x%%:*}]=1
    done <<< "${r[bind]:-}"
    while IFS='|' read -r k a x v; do
        [[ -z $k ]] && continue
        covered[$x]=1
        case $k in
            bind|volume)
                v=$([[ $v == true ]] && echo :ro)
                if [[ -n $a ]]; then spec_add_volume "$a:$x$v"; else sp_add volumes "$x"; fi ;;
            tmpfs) sp_add tmpfs "$x" ;;
        esac
    done <<< "${r[mount]:-}"
    while IFS='|' read -r k a x; do
        [[ $k == volume && -z ${covered[$x]:-} ]] || continue
        spec_add_volume "$a:$x"
        sp_warn "The anonymous volume at $x is kept by its ID, so its data carries over"
    done <<< "${r[cmount]:-}"

    while IFS='|' read -r ip a x; do
        [[ -z $x ]] && continue
        x=${x%/tcp}
        [[ $ip == 0.0.0.0 || $ip == :: ]] && ip=""
        [[ $ip == *:* ]] && ip="[$ip]"
        if [[ -n $a ]]; then x="$a:$x"; fi
        [[ -n $ip ]] && x="$ip:$x"
        sp_add_once ports "$x"
    done <<< "${r[port]:-}"

    IFS='|' read -r k v <<< "${r[restart]}"
    case $k in
        ''|no) SP[_restart_raw]=no ;;
        on-failure) SP[restart]=on-failure${v:+:$v}; [[ $v == 0 ]] && SP[restart]=on-failure; SP[_restart_raw]=${SP[restart]} ;;
        *) SP[restart]=$k; SP[_restart_raw]=$k ;;
    esac

    if [[ -z ${SP[network_mode]:-} ]]; then
        while IFS='|' read -r k ip aliases; do
            case $k in ''|host|none) continue ;; bridge) x=1; continue ;; esac
            spec_add_network "$k"
            [[ -n $ip ]] && SPN_IP[$k]=$ip
            v=""
            read_array a_list , "$aliases"
            for a in "${a_list[@]}"; do
                [[ -z $a || $a == "$id12" || $a == "$name" || $a == "${r[id]}" ]] && continue
                v+="${v:+$NL}$a"
            done
            [[ -n $v ]] && SPN_ALIAS[$k]=$v
        done <<< "${r[net]:-}"
        if [[ -n ${SPL[networks]:-} && ${x:-} == 1 ]]; then
            sp_warn "The container was also on Docker's default bridge network; compose attaches it to the networks listed only"
        fi
    fi

    [[ ${r[privileged]} == true ]] && SP[privileged]=true
    for x in capadd:cap_add capdrop:cap_drop dns:dns dnssearch:dns_search dnsopt:dns_opt \
             host:extra_hosts secopt:security_opt sysctl:sysctls tmpfs:tmpfs groupadd:group_add \
             ulimit:_ulimits logopt:_log_opts; do
        while IFS= read -r v; do
            [[ -n $v ]] && sp_add "${x#*:}" "$v"
        done <<< "${r[${x%%:*}]:-}"
    done
    while IFS= read -r v; do
        [[ -z $v ]] && continue
        sp_add devices "${v%:rwm}"
    done <<< "${r[device]:-}"
    v=${r[shm]:-0}
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 0 && v != 67108864 )); then bytes_to_size "$v"; SP[shm_size]=$REPLY; fi
    v=${r[memory]:-0}
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 0 )); then bytes_to_size "$v"; SP[mem_limit]=$REPLY; fi
    v=${r[nanocpus]:-0}
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 0 )); then SP[cpus]=$(awk -v n="$v" 'BEGIN { printf "%g", n / 1e9 }'); fi
    [[ -n ${r[pid]} ]] && SP[pid]=${r[pid]}
    case ${r[ipc]} in ''|private|shareable) ;; *) SP[ipc]=${r[ipc]} ;; esac
    [[ ${r[readonly]} == true ]] && SP[read_only]=true
    [[ ${r[init]} == true ]] && SP[init]=true
    if [[ -n ${SPL[_log_opts]:-} || ( -n ${r[logtype]} && ${r[logtype]} != json-file ) ]]; then
        SP[_log_driver]=${r[logtype]}
    fi
    case ${r[runtime]} in ''|runc) ;; *) SP[runtime]=${r[runtime]} ;; esac
    if [[ ${r[gpus]:-0} != 0 ]]; then
        SP[_gpus]=all
        sp_warn "GPU access is converted as \"all GPUs\"; check the deploy: section"
    fi
    [[ ${r[autoremove]} == true ]] && sp_warn "The container was started with --rm; compose keeps its containers"
    [[ ${r[publishall]} == true ]] && sp_warn "The container was started with -P; list any extra ports under ports:"
    while IFS= read -r v; do
        [[ -z $v ]] && continue
        x=${v%%:*}; a=${v##*/}
        sp_add external_links "${x#/}:$a"
    done <<< "${r[link]:-}"
    spec_finish
}

# Settings that depend on several options; picks the service and stack names
spec_finish() {
    local first base v
    first=${SPL[networks]:-}; first=${first%%$'\n'*}
    if [[ -n ${SP[_ip]:-}${SP[_ip6]:-}${SPL[_aliases]:-} ]]; then
        if [[ -n $first ]]; then
            [[ -n ${SP[_ip]:-} ]] && SPN_IP[$first]=${SP[_ip]}
            [[ -n ${SP[_ip6]:-} ]] && SPN_IP6[$first]=${SP[_ip6]}
            if [[ -n ${SPL[_aliases]:-} ]]; then
                SPN_ALIAS[$first]+="${SPN_ALIAS[$first]:+$NL}${SPL[_aliases]}"
            fi
        else
            sp_warn "--ip and --network-alias need a user-defined network (--network); dropped"
        fi
    fi
    if [[ -n ${SP[_health_cmd]:-} ]]; then
        SPL[_health_test]="CMD-SHELL"$'\n'"${SP[_health_cmd]}"
    fi
    if [[ -n ${SP[network_mode]:-} && -n ${SPL[networks]:-} ]]; then
        sp_warn "network_mode ${SP[network_mode]} can't be combined with networks:; the networks were dropped"
        SPL[networks]=""
    fi
    base=${SP[container_name]:-}
    if [[ -z $base ]]; then
        base=${SP[image]##*/}; base=${base%%[:@]*}
    fi
    lower "$base"; base=$REPLY
    base=${base//[^a-z0-9_.-]/-}
    while [[ $base == [^a-z0-9]* ]]; do base=${base:1}; done
    [[ -z $base ]] && base=app
    SP[_service]=$base
    SP[_stack]=${base//./-}
    if [[ ${SP[_source]} == run ]]; then
        for v in "${SP[@]}" "${SPL[@]}"; do
            if [[ $v == *'$'* ]]; then
                sp_warn "Compose fills in \$VARIABLES from your environment or the stack's .env file (use \$\$ for a literal \$)"
                break
            fi
        done
    fi
}

# Quote $1 as a YAML double-quoted string, in REPLY. Values taken from a
# container are literal, so $ is doubled to stop compose interpolating it.
yaml_q() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    [[ ${SP[_dollar]:-} == escape ]] && s=${s//\$/\$\$}
    REPLY="\"$s\""
}

# Print "<indent>KEY: [items]" for the list SPL[$3]
yaml_flow() {
    local ind=$1 key=$2 out="" v
    if [[ -n ${SPL[$3]:-} ]]; then
        while IFS= read -r v; do yaml_q "$v"; out+="${out:+, }$REPLY"; done <<< "${SPL[$3]}"
    fi
    echo "$ind$key: [$out]"
}

# Print the spec as a compose file
spec_to_compose() {
    local k v line name ulim_name ulim_val map=0 i4="    " i6="      " i8="        "
    echo "# Generated by docker-stacks-manager $VERSION from ${SP[_origin]:-a docker run command}"
    [[ -n ${SP[_cmdline]:-} ]] && echo "#   ${SP[_cmdline]}"
    echo "# Review it before use; \`docker compose config\` checks it."
    if [[ -n ${SPL[_warn]:-} ]]; then
        echo "#"
        echo "# Notes:"
        while IFS= read -r line; do echo "#   - $line"; done <<< "${SPL[_warn]}"
    fi
    echo "services:"
    echo "  ${SP[_service]}:"
    yaml_q "${SP[image]}"; echo "${i4}image: $REPLY"
    for k in container_name hostname domainname user working_dir; do
        [[ -n ${SP[$k]:-} ]] && { yaml_q "${SP[$k]}"; echo "$i4$k: $REPLY"; }
    done
    [[ -n ${SP[_entry_set]:-} ]] && yaml_flow "$i4" entrypoint entrypoint
    [[ -n ${SP[_cmd_set]:-} ]] && yaml_flow "$i4" command command
    for k in restart network_mode; do
        [[ -n ${SP[$k]:-} ]] && { yaml_q "${SP[$k]}"; echo "$i4$k: $REPLY"; }
    done

    if [[ -n ${SPL[networks]:-} ]]; then
        echo "${i4}networks:"
        while IFS= read -r name; do
            [[ -n ${SPN_IP[$name]:-}${SPN_IP6[$name]:-}${SPN_ALIAS[$name]:-} ]] && map=1
        done <<< "${SPL[networks]}"
        while IFS= read -r name; do
            yaml_q "$name"
            if (( ! map )); then echo "$i6- $REPLY"; continue; fi
            if [[ -z ${SPN_IP[$name]:-}${SPN_IP6[$name]:-}${SPN_ALIAS[$name]:-} ]]; then echo "$i6$REPLY: {}"; continue; fi
            echo "$i6$REPLY:"
            [[ -n ${SPN_IP[$name]:-} ]] && { yaml_q "${SPN_IP[$name]}"; echo "${i8}ipv4_address: $REPLY"; }
            [[ -n ${SPN_IP6[$name]:-} ]] && { yaml_q "${SPN_IP6[$name]}"; echo "${i8}ipv6_address: $REPLY"; }
            if [[ -n ${SPN_ALIAS[$name]:-} ]]; then
                SPL[_tmp]=${SPN_ALIAS[$name]}
                yaml_flow "$i8" aliases _tmp
            fi
        done <<< "${SPL[networks]}"
    fi

    for k in ports expose volumes volumes_from tmpfs environment env_file labels annotations \
             extra_hosts external_links dns dns_search dns_opt cap_add cap_drop security_opt \
             devices device_cgroup_rules group_add sysctls; do
        [[ -n ${SPL[$k]:-} ]] || continue
        echo "$i4$k:"
        while IFS= read -r v; do yaml_q "$v"; echo "$i6- $REPLY"; done <<< "${SPL[$k]}"
    done
    if [[ -n ${SPL[_ulimits]:-} ]]; then
        echo "${i4}ulimits:"
        while IFS= read -r v; do
            ulim_name=${v%%=*}; ulim_val=${v#*=}
            if [[ $ulim_val == *:* ]]; then
                echo "$i6$ulim_name:"
                echo "${i8}soft: ${ulim_val%%:*}"
                echo "${i8}hard: ${ulim_val#*:}"
            else
                echo "$i6$ulim_name: $ulim_val"
            fi
        done <<< "${SPL[_ulimits]}"
    fi
    if [[ -n ${SPL[_storage_opt]:-} ]]; then
        echo "${i4}storage_opt:"
        while IFS= read -r v; do yaml_q "${v#*=}"; echo "$i6${v%%=*}: $REPLY"; done <<< "${SPL[_storage_opt]}"
    fi
    for k in pid ipc uts userns_mode cgroup cgroup_parent isolation runtime platform pull_policy \
             mac_address stop_signal stop_grace_period shm_size mem_limit mem_reservation \
             memswap_limit cpuset; do
        [[ -n ${SP[$k]:-} ]] && { yaml_q "${SP[$k]}"; echo "$i4$k: $REPLY"; }
    done
    for k in cpus cpu_shares cpu_period cpu_quota pids_limit oom_score_adj mem_swappiness; do
        [[ -n ${SP[$k]:-} ]] || continue
        if [[ ${SP[$k]} =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then echo "$i4$k: ${SP[$k]}"; else yaml_q "${SP[$k]}"; echo "$i4$k: $REPLY"; fi
    done
    for k in privileged init read_only tty stdin_open oom_kill_disable; do
        [[ ${SP[$k]:-} == true ]] && echo "$i4$k: true"
    done

    if [[ -n ${SP[_health_disable]:-} ]]; then
        echo "${i4}healthcheck:"
        echo "${i6}disable: true"
    elif [[ -n ${SPL[_health_test]:-} ]]; then
        echo "${i4}healthcheck:"
        yaml_flow "$i6" test _health_test
        for k in interval timeout start_period start_interval; do
            [[ -n ${SP[_health_$k]:-} ]] && { yaml_q "${SP[_health_$k]}"; echo "$i6$k: $REPLY"; }
        done
        [[ -n ${SP[_health_retries]:-} ]] && echo "${i6}retries: ${SP[_health_retries]}"
    fi
    if [[ -n ${SP[_log_driver]:-}${SPL[_log_opts]:-} ]]; then
        echo "${i4}logging:"
        yaml_q "${SP[_log_driver]:-json-file}"; echo "${i6}driver: $REPLY"
        if [[ -n ${SPL[_log_opts]:-} ]]; then
            echo "${i6}options:"
            while IFS= read -r v; do yaml_q "${v#*=}"; echo "$i8${v%%=*}: $REPLY"; done <<< "${SPL[_log_opts]}"
        fi
    fi
    if [[ -n ${SP[_gpus]:-} ]]; then
        v=${SP[_gpus]//\"/}
        echo "${i4}deploy:"
        echo "${i6}resources:"
        echo "${i8}reservations:"
        echo "${i8}  devices:"
        echo "${i8}    - driver: nvidia"
        if [[ $v == all || $v =~ ^[0-9]+$ ]]; then
            echo "${i8}      count: $v"
        elif [[ $v == device=* ]]; then
            SPL[_tmp]=${v#device=}; SPL[_tmp]=${SPL[_tmp]//,/$'\n'}
            yaml_flow "${i8}      " device_ids _tmp
        fi
        echo "${i8}      capabilities: [gpu]"
    fi

    if [[ -n ${SPL[networks]:-} ]]; then
        echo "networks:"
        while IFS= read -r name; do
            yaml_q "$name"; echo "  $REPLY:"
            echo "    external: true"
        done <<< "${SPL[networks]}"
    fi
    if [[ -n ${SPL[_volumes]:-} ]]; then
        echo "volumes:"
        while IFS= read -r name; do
            yaml_q "$name"; echo "  $REPLY:"
            echo "    external: true"
        done <<< "${SPL[_volumes]}"
    fi
}

# Containers not managed by compose: id, name, image, state (tab-separated)
standalone_containers() {
    local tab=$'\t'
    docker ps -a --format "{{.ID}}${tab}{{.Names}}${tab}{{.Image}}${tab}{{.State}}${tab}{{.Label \"com.docker.compose.project\"}}" 2>/dev/null |
        awk -F '\t' '$5 == "" { print $1 "\t" $2 "\t" $3 "\t" $4 }' | sort -t "$tab" -k2
}

# Read a docker run command typed or pasted at the terminal, following lines
# that end in a backslash. Returns 1 on an empty first line (cancel).
read_command_lines() {
    local line all=""
    while printf '> ' && IFS= read -r line; do
        line=${line%$'\r'}
        if [[ -z $all && -z ${line//[[:space:]]/} ]]; then return 1; fi
        all+=$line$'\n'
        [[ $line == *\\ ]] || break
    done
    [[ -n $all ]] || return 1
    REPLY=$all
}

# Create the external networks and volumes the spec uses, if missing
ensure_externals() {
    local v
    while IFS= read -r v; do
        [[ -z $v ]] && continue
        if ! docker network inspect "$v" >/dev/null 2>&1; then
            echo "Creating network $v"
            docker network create "$v" >/dev/null || return 1
        fi
    done <<< "${SPL[networks]:-}"
    while IFS= read -r v; do
        [[ -z $v ]] && continue
        if ! docker volume inspect "$v" >/dev/null 2>&1; then
            echo "Creating volume $v"
            docker volume create "$v" >/dev/null || return 1
        fi
    done <<< "${SPL[_volumes]:-}"
}

# Replace container $1 with the stack in directory $2. The old container is
# stopped, renamed and kept (restart policy off) so nothing is lost; if the
# stack doesn't start, everything is put back.
migrate_container() {
    local c=$1 dir=$2 old="$1-pre-compose" was_running=false
    docker inspect --type container "$old" >/dev/null 2>&1 && old="$c-pre-compose-$(date +%s)"
    [[ ${SP[_state]} == running || ${SP[_state]} == restarting ]] && was_running=true
    echo -e "${CYAN}Stopping $c...${NC}"
    docker stop "$c" >/dev/null || { echo -e "${RED}Could not stop $c; nothing was changed${NC}"; return 1; }
    if ! docker rename "$c" "$old"; then
        echo -e "${RED}Could not rename $c; starting it again${NC}"
        [[ $was_running == true ]] && docker start "$c" >/dev/null
        return 1
    fi
    docker update --restart=no "$old" >/dev/null
    echo -e "${CYAN}Starting the stack...${NC}"
    if (cd "$dir" && docker compose up -d); then
        echo
        echo -e "${GREEN}✓ $c now runs from $dir${NC}"
        echo "The old container is stopped and kept as $old."
        echo "Once the stack works, remove it with:  docker rm $old"
        return 0
    fi
    echo -e "${RED}The stack did not start; putting the old container back${NC}"
    (cd "$dir" && docker compose down) >/dev/null 2>&1
    docker rename "$old" "$c"
    docker update --restart="${SP[_restart_raw]:-no}" "$c" >/dev/null
    [[ $was_running == true ]] && docker start "$c" >/dev/null
    echo "compose.yaml is still in $dir for you to fix."
    return 1
}

# Show the compose file for the spec, then write it to a new stack folder and
# offer to start it (replacing the container it came from, if any)
compose_wizard() {
    local yaml name dir f exists
    yaml=$(spec_to_compose)
    echo
    printf '%s\n' "$yaml" | while IFS= read -r f; do
        if [[ $f == '#'* ]]; then echo -e "${DIM}${f}${NC}"; else printf '%s\n' "$f"; fi
    done
    echo
    while true; do
        printf '%s' "Stack folder name in $BASE_DIR [${SP[_stack]}]: "
        IFS= read -r name || { echo; return 1; }
        name=${name:-${SP[_stack]}}
        if [[ ! $name =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            echo -e "${YELLOW}Use lowercase letters, digits, - and _ (a compose project name)${NC}"
            continue
        fi
        dir="$BASE_DIR/$name"
        exists=""
        for f in "${COMPOSE_FILENAMES[@]}"; do [[ -e $dir/$f ]] && exists=$f; done
        if [[ -n $exists ]]; then
            echo -e "${YELLOW}$dir already has a $exists; pick another name${NC}"
            continue
        fi
        break
    done
    confirm "Write $dir/compose.yaml?" || { echo "Cancelled; nothing was written."; return 1; }
    if ! { mkdir -p "$dir" && printf '%s\n' "$yaml" > "$dir/compose.yaml"; }; then
        echo -e "${RED}Could not write $dir/compose.yaml${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Wrote $dir/compose.yaml${NC}"
    echo

    if [[ ${SP[_source]} == container ]]; then
        local c=${SP[_container]}
        echo "To run $c from the stack, it has to be replaced: it is stopped and kept"
        echo "as $c-pre-compose (not started again on boot), then the stack starts."
        echo "Volumes and bind mounts carry over. If the stack fails, $c is put back."
        if confirm "Switch $c over to the stack now?"; then
            migrate_container "$c" "$dir"
            return
        fi
        echo "Left $c as it is. To switch over later:"
        echo "  docker stop $c && docker rename $c $c-pre-compose && docker update --restart=no $c-pre-compose"
        echo "  cd \"$dir\" && docker compose up -d"
    else
        if confirm "Start the stack now (docker compose up -d)?"; then
            ensure_externals || return 1
            (cd "$dir" && docker compose up -d)
            return
        fi
        echo "To start it later:  cd \"$dir\" && docker compose up -d"
    fi
}

# --import / --convert from the command line
import_cli() {
    local line
    if [[ $IMPORT_MODE == container ]] && ! inspect_to_spec "$IMPORT_TARGET"; then
        echo "Error: $REPLY" >&2
        [[ $REPLY == "no such container"* ]] && IMPORT_MODE=list
        [[ $IMPORT_MODE == list ]] || return 1
        echo
    fi
    if [[ $IMPORT_MODE == list ]]; then
        line=$(standalone_containers)
        if [[ -z $line ]]; then
            echo "Every container is already managed by compose."
            return 0
        fi
        echo -e "${BOLD}Containers not managed by compose${NC}"
        printf '%s\n' "$line" | awk -F '\t' '{ printf "  %-28s %-36s %s\n", $2, $3, $4 }'
        echo
        echo "Convert one with:  ${0##*/} --import NAME"
        [[ -z $IMPORT_TARGET ]]
        return
    fi
    if [[ $IMPORT_MODE == command ]]; then
        if [[ -z $CONVERT_CMD ]]; then
            if [[ -t 0 ]]; then
                echo "Paste or type a docker run command (lines ending in \\ continue):"
                read_command_lines || { echo "Cancelled."; return 1; }
                CONVERT_CMD=$REPLY
            else
                CONVERT_CMD=$(cat)
            fi
        fi
        convert_command "$CONVERT_CMD" || { echo "Error: $REPLY" >&2; return 1; }
    fi
    if [[ $PRINT_ONLY == true || ! -t 0 || ! -t 1 ]]; then
        spec_to_compose
        return 0
    fi
    compose_wizard
}

# ============================================================================
# Terminal UI helpers
# ============================================================================
REFRESH_SECS=${DSM_REFRESH:-5}   # TUI auto-refresh interval (seconds)
TUI_ACTIVE=false
TUI_INT=0

# Switch to the terminal's alternate screen (like less/htop): redraws happen
# in place and your scrollback is untouched when the tool exits.
tui_start() {
    printf '\033[?1049h\033[?25l'
    TUI_ACTIVE=true
    key_mode on
    trap tui_end EXIT
}

tui_end() {
    if [ "$TUI_ACTIVE" = true ]; then
        printf '\033[?25h\033[?1049l'
        TUI_ACTIVE=false
        key_mode off
    fi
}

tui_rows() {
    local rows
    rows=$(stty size 2>/dev/null | awk '{print $1}')
    REPLY=${rows:-24}
    [ "$REPLY" -gt 0 ] 2>/dev/null || REPLY=24
}

# Draw a frame (one argument per line) over the previous one without clearing
# the screen first, so nothing flickers.
tui_draw() {
    local out='\033[H\033[?25l' line
    for line in "$@"; do
        out+="${line}\033[K\n"
    done
    printf '%b\033[J' "$out"
}

# Start a full-screen sub-view (logs, shell, ...): clear and show the cursor
view_start() {
    printf '\033[H\033[2J\033[?25h'
}

# Ask a yes/no question with one keypress; only y/Y confirms
confirm() {
    local answer
    printf '%b' "${YELLOW}$1 (y/N)${NC} "
    TUI_INT=0
    read_char answer
    echo
    [[ "$answer" == [yY] ]]
}

# Read one key for a menu. Sets KEY to: up, down, enter, esc, a character,
# "refresh" (no key within REFRESH_SECS) or "quit" (Ctrl+C).
read_menu_key() {
    local k rest rc
    TUI_INT=0
    read_char k 1 "$REFRESH_SECS"
    rc=$?
    if [ "$TUI_INT" = 1 ]; then KEY=quit; return; fi
    if [ $rc -eq 142 ]; then KEY=refresh; return; fi
    if [ $rc -ne 0 ]; then KEY=quit; return; fi   # end of input
    case "$k" in
        $'\x1b')
            read_char rest 2 0.05
            case "$rest" in
                '[A') KEY=up ;;
                '[B') KEY=down ;;
                '')   KEY=esc ;;
                *)    KEY=other ;;
            esac
            ;;
        '') KEY=enter ;;
        k)  KEY=up ;;
        j)  KEY=down ;;
        *)  KEY="$k" ;;
    esac
}

# Interactive menu for stacks
interactive_stack_menu() {
    local selected=0 top=0 filter="" i n w name
    local -a view frame

    while true; do
        # Stacks shown, after the filter
        view=()
        lower "$filter"; local lfilter=$REPLY
        for ((i = 0; i < ${#STACK_NAMES[@]}; i++)); do
            lower "${STACK_NAMES[i]}"
            if [ -z "$filter" ] || [[ "$REPLY" == *"$lfilter"* ]]; then
                view+=("$i")
            fi
        done
        [ $selected -ge ${#view[@]} ] && selected=$(( ${#view[@]} - 1 ))
        [ $selected -lt 0 ] && selected=0

        tui_rows; local rows=$REPLY
        frame=("${BOLD}Docker Stack Manager${NC}  ${DIM}${BASE_DIR} · updated ${SNAPSHOT_TIME}${NC}")
        if [ -n "$filter" ]; then
            frame+=("${YELLOW}Filter: ${filter}${NC} ${DIM}(${#view[@]} of ${#STACK_NAMES[@]} · / change · Esc clear)${NC}")
        else
            frame+=("")
        fi
        local footer_lines=3
        local avail=$(( rows - ${#frame[@]} - footer_lines - 1 ))
        [ $avail -lt 3 ] && avail=3
        [ $selected -lt $top ] && top=$selected
        [ $selected -ge $((top + avail)) ] && top=$((selected - avail + 1))
        [ $top -gt 0 ] && [ $((top + avail)) -gt ${#view[@]} ] && top=$(( ${#view[@]} > avail ? ${#view[@]} - avail : 0 ))

        w=4
        for i in "${view[@]}"; do [ ${#STACK_NAMES[i]} -gt $w ] && w=${#STACK_NAMES[i]}; done
        for ((n = top; n < ${#view[@]} && n < top + avail; n++)); do
            i=${view[n]}
            printf -v name "%-${w}s" "${STACK_NAMES[i]}"
            stack_badge "$i"
            if [ $n -eq $selected ]; then
                frame+=("${REVERSE}> ${name} ${NC}  $REPLY")
            else
                frame+=("  ${name}   $REPLY")
            fi
        done
        [ ${#view[@]} -eq 0 ] && frame+=("  ${DIM}(no stacks match)${NC}")
        [ $((top + avail)) -lt ${#view[@]} ] && frame+=("  ${DIM}↓ $(( ${#view[@]} - top - avail )) more${NC}")
        frame+=("")
        frame+=("${CYAN}[L]ogs [R]estart [S]top [U]p [D]own [N]etwork [T]raffic [I]mport${NC}")
        frame+=("${DIM}↑/↓ j/k move · Enter containers · / filter · q quit · refreshes every ${REFRESH_SECS}s${NC}")
        tui_draw "${frame[@]}"

        read_menu_key
        local sel="${view[selected]:-}"
        case "$KEY" in
            quit|q|Q) return ;;
            refresh) load_snapshot ;;
            up)   [ ${#view[@]} -gt 0 ] && selected=$(( (selected - 1 + ${#view[@]}) % ${#view[@]} )) ;;
            down) [ ${#view[@]} -gt 0 ] && selected=$(( (selected + 1) % ${#view[@]} )) ;;
            esc)  filter=""; selected=0; top=0 ;;
            i|I) import_menu; load_snapshot; continue ;;
            /)
                printf '\033[%d;1H\033[K\033[?25h/' "$rows"
                key_mode off
                read -r filter
                key_mode on
                selected=0; top=0
                ;;
        esac
        [ -z "$sel" ] && continue
        case "$KEY" in
            l|L) stack_logs "${STACK_DIRS[sel]}" ;;
            r|R) stack_restart "${STACK_DIRS[sel]}" "${STACK_NAMES[sel]}"; load_snapshot ;;
            s|S) stack_stop "${STACK_DIRS[sel]}" "${STACK_NAMES[sel]}"; load_snapshot ;;
            u|U) stack_up "${STACK_DIRS[sel]}" "${STACK_NAMES[sel]}"; load_snapshot ;;
            d|D) stack_down "${STACK_DIRS[sel]}" "${STACK_NAMES[sel]}"; load_snapshot ;;
            n|N) all_stacks_network_view ;;
            t|T) all_stacks_traffic_stats; load_snapshot ;;
            enter) container_menu "${STACK_DIRS[sel]}"; load_snapshot ;;
        esac
    done
}

# Import menu: paste a docker run command, or pick a container compose
# doesn't manage, and turn it into a stack
import_menu() {
    local selected=0 top=0 n line rows avail id cname image state
    local -a items frame
    while true; do
        items=(paste)
        while IFS= read -r line; do
            [[ -n $line ]] && items+=("$line")
        done < <(standalone_containers)
        [ $selected -ge ${#items[@]} ] && selected=$(( ${#items[@]} - 1 ))

        tui_rows; rows=$REPLY
        frame=("${BOLD}Import into a compose stack${NC}  ${DIM}new stacks go in ${BASE_DIR}${NC}" "")
        if [ $selected -eq 0 ]; then
            frame+=("${REVERSE}> Paste a docker run command... ${NC}")
        else
            frame+=("  Paste a docker run command...")
        fi
        frame+=("")
        if [ ${#items[@]} -eq 1 ]; then
            frame+=("  ${DIM}Every container is already managed by compose${NC}")
        else
            frame+=("  ${BOLD}Containers not managed by compose${NC}")
        fi
        avail=$(( rows - 10 ))
        [ $avail -lt 3 ] && avail=3
        [ $selected -gt 0 ] && [ $((selected - 1)) -lt $top ] && top=$((selected - 1))
        [ $selected -gt 0 ] && [ $((selected - 1)) -ge $((top + avail)) ] && top=$((selected - avail))
        for ((n = top + 1; n < ${#items[@]} && n <= top + avail; n++)); do
            IFS=$'\t' read -r id cname image state <<< "${items[n]}"
            printf -v line '%-28s %-36s' "$cname" "$image"
            case $state in
                running) state="${GREEN}${state}${NC}" ;;
                *) state="${DIM}${state}${NC}" ;;
            esac
            if [ $n -eq $selected ]; then
                frame+=("${REVERSE}> ${line} ${NC} $state")
            else
                frame+=("  ${line}  $state")
            fi
        done
        [ $((top + avail + 1)) -lt ${#items[@]} ] && frame+=("  ${DIM}↓ $(( ${#items[@]} - top - avail - 1 )) more${NC}")
        frame+=("")
        frame+=("${CYAN}Enter: convert to a compose stack (you see the file before anything is written)${NC}")
        frame+=("${DIM}↑/↓ j/k move · Esc back${NC}")
        tui_draw "${frame[@]}"

        read_menu_key
        case "$KEY" in
            quit|q|Q|esc) return ;;
            up)   selected=$(( (selected - 1 + ${#items[@]}) % ${#items[@]} )) ;;
            down) selected=$(( (selected + 1) % ${#items[@]} )) ;;
            enter)
                # The wizard runs on the normal screen, so its output can be scrolled
                tui_end
                echo
                if [ $selected -eq 0 ]; then
                    echo -e "${BOLD}Paste or type a docker run command${NC}, then press Enter."
                    echo -e "${DIM}Lines ending in \\ continue on the next one. An empty line cancels.${NC}"
                    echo
                    if read_command_lines; then
                        if convert_command "$REPLY"; then
                            compose_wizard
                        else
                            echo -e "${RED}Error: $REPLY${NC}"
                        fi
                    fi
                else
                    IFS=$'\t' read -r id cname image state <<< "${items[selected]}"
                    if inspect_to_spec "$id"; then
                        compose_wizard
                    else
                        echo -e "${RED}Error: $REPLY${NC}"
                    fi
                fi
                echo
                press_any_key
                tui_start
                ;;
        esac
    done
}

# Container menu for the stack in directory $1
container_menu() {
    local stack_dir=$1 selected=0 n id si now
    local -a ids frame

    while true; do
        si=$(stack_index_of "$stack_dir") || return
        ids=(${STACK_CIDS[si]})
        if [ ${#ids[@]} -eq 0 ]; then
            view_start
            echo -e "${BOLD}=== ${STACK_NAMES[si]} ===${NC}\n"
            echo -e "${YELLOW}⚠ This stack has no containers${NC}\n"
            echo -e "${DIM}It has never been started, or was removed with [D]own.${NC}"
            echo -e "${DIM}Start it from the stack menu with [U]p.${NC}\n"
            press_any_key
            return
        fi
        [ $selected -ge ${#ids[@]} ] && selected=$(( ${#ids[@]} - 1 ))

        now=$(date +%s)
        stack_badge "$si"
        frame=("${BOLD}${STACK_NAMES[si]}${NC}  $REPLY  ${DIM}${stack_dir} · updated ${SNAPSHOT_TIME}${NC}" "")
        local w=4
        for id in "${ids[@]}"; do [ ${#C_SERVICE[$id]} -gt $w ] && w=${#C_SERVICE[$id]}; done
        for ((n = 0; n < ${#ids[@]}; n++)); do
            id=${ids[n]}
            local name dot summary
            printf -v name "%-${w}s" "${C_SERVICE[$id]}"
            container_dot "$id"; dot=$REPLY
            container_summary "$id" "$now"; summary=$REPLY
            if [ $n -eq $selected ]; then
                frame+=("${REVERSE}> ${name} ${NC} ${dot} ${summary}")
                frame+=("    ${DIM}Container: ${C_NAME[$id]} (${id})${NC}")
                frame+=("    ${DIM}Image:     ${C_IMAGE[$id]}${NC}")
                shared_network_host "$id"
                if [ -n "$REPLY" ]; then
                    frame+=("    ${DIM}Network:   via ${REPLY}${NC}")
                elif [ -n "${C_NETS[$id]}" ]; then
                    local entry nets_text=""
                    for entry in ${C_NETS[$id]}; do
                        nets_text+="${entry%%=*}"
                        [ -n "${entry#*=}" ] && nets_text+=" (${entry#*=})"
                        nets_text+=", "
                    done
                    frame+=("    ${DIM}Networks:  ${nets_text%, }${NC}")
                fi
                [ -n "${C_PORTS[$id]}" ] && frame+=("    ${DIM}Ports:     ${C_PORTS[$id]}${NC}")
            else
                frame+=("  ${name}  ${dot} ${summary}")
            fi
        done
        frame+=("")
        frame+=("${CYAN}[L]ogs [R]estart [S]top [T]op [N]etwork [F]low${NC}")
        frame+=("${DIM}↑/↓ j/k move · Enter more actions · q back · refreshes every ${REFRESH_SECS}s${NC}")
        tui_draw "${frame[@]}"

        read_menu_key
        id=${ids[selected]}
        local service=${C_SERVICE[$id]}
        case "$KEY" in
            quit|q|Q|esc) return ;;
            refresh) load_snapshot ;;
            up)    selected=$(( (selected - 1 + ${#ids[@]}) % ${#ids[@]} )) ;;
            down)  selected=$(( (selected + 1) % ${#ids[@]} )) ;;
            l|L)   container_logs "$id" "$service" ;;
            r|R)   container_restart "$stack_dir" "$service"; load_snapshot ;;
            s|S)   container_stop "$stack_dir" "$service"; load_snapshot ;;
            t|T)   container_top "$id" "$service" ;;
            n|N)   container_network_view "$id" "$service" ;;
            f|F)   container_stats "$id" "$service" ;;
            enter) container_action_menu "$stack_dir" "$id" "$service"; load_snapshot ;;
        esac
    done
}

# Container action submenu
container_action_menu() {
    local stack_dir=$1
    local container_id=$2
    local service=$3
    
    while true; do
        view_start
        echo -e "${BOLD}=== Actions: $service ===${NC}\n"
        echo -e "1. View logs (live) ${DIM}[Ctrl+C to exit]${NC}"
        echo -e "2. View logs (last 100 lines)"
        echo -e "3. Restart container"
        echo -e "4. Stop container"
        echo -e "5. Start container"
        echo -e "6. Execute shell (bash) ${DIM}['exit' or Ctrl+D to exit]${NC}"
        echo -e "7. Execute shell (sh) ${DIM}['exit' or Ctrl+D to exit]${NC}"
        echo -e "8. View top processes"
        echo -e "9. View stats (live) ${DIM}[Ctrl+C to exit]${NC}"
        echo -e "n. View network/ports"
        echo -e "q. Back\n"

        read_char action

        case "$action" in
            1) container_logs "$container_id" "$service" true ;;
            2) container_logs "$container_id" "$service" false ;;
            3) container_restart "$stack_dir" "$service" ;;
            4) container_stop "$stack_dir" "$service" ;;
            5) container_start "$stack_dir" "$service" ;;
            6)
                view_start
                echo -e "${BOLD}${CYAN}=== Interactive Shell (bash): $service ===${NC}"
                echo -e "${YELLOW}Type 'exit' or press Ctrl+D to close shell${NC}\n"
                docker exec -it "$container_id" bash 2>/dev/null || echo -e "${RED}Bash not available${NC}"
                press_any_key
                ;;
            7)
                view_start
                echo -e "${BOLD}${CYAN}=== Interactive Shell (sh): $service ===${NC}"
                echo -e "${YELLOW}Type 'exit' or press Ctrl+D to close shell${NC}\n"
                docker exec -it "$container_id" sh 2>/dev/null || echo -e "${RED}Shell not available${NC}"
                press_any_key
                ;;
            8) container_top "$container_id" "$service" ;;
            9) container_stats "$container_id" "$service" ;;
            n|N) container_network_view "$container_id" "$service" ;;
            q|Q) return ;;
        esac
    done
}

# Stack operations
stack_logs() {
    local stack_dir=$1
    cd "$stack_dir" || return
    view_start
    echo -e "${BOLD}${CYAN}=== Live Logs: All Containers ===${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop following logs${NC}\n"
    docker compose logs -f --tail=100
    echo -e "\n${DIM}Log streaming ended${NC}"
    press_any_key
}

stack_restart() {
    local stack_dir=$1
    local stack_name=$2
    cd "$stack_dir" || return
    view_start
    confirm "Restart all containers in $stack_name?" || return
    echo -e "${YELLOW}Restarting stack: $stack_name${NC}\n"
    docker compose restart
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

stack_stop() {
    local stack_dir=$1
    local stack_name=$2
    cd "$stack_dir" || return
    view_start
    confirm "Stop all containers in $stack_name?" || return
    echo -e "${RED}Stopping stack: $stack_name${NC}\n"
    docker compose stop
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

stack_up() {
    local stack_dir=$1
    local stack_name=$2
    cd "$stack_dir" || return
    view_start
    echo -e "${GREEN}Starting stack: $stack_name${NC}\n"
    docker compose up -d
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

stack_down() {
    local stack_dir=$1
    local stack_name=$2
    cd "$stack_dir" || return
    view_start
    echo -e "${RED}WARNING: This will stop and remove the containers of $stack_name!${NC}"
    confirm "Run docker compose down?" || return
    docker compose down
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

# Container operations
container_logs() {
    local container_id=$1
    local service=$2
    local follow=${3:-true}
    
    view_start
    if [ "$follow" = true ]; then
        echo -e "${BOLD}${CYAN}=== Live Logs: $service ===${NC}"
        echo -e "${YELLOW}Press Ctrl+C to stop following logs${NC}\n"
        docker logs -f --tail=100 "$container_id"
        echo -e "\n${DIM}Log streaming ended${NC}"
    else
        echo -e "${BOLD}${CYAN}=== Last 100 Lines: $service ===${NC}\n"
        docker logs --tail=100 "$container_id"
    fi
    press_any_key
}

container_restart() {
    local stack_dir=$1
    local service=$2
    cd "$stack_dir" || return
    view_start
    confirm "Restart $service?" || return
    echo -e "${YELLOW}Restarting $service...${NC}\n"
    docker compose restart "$service"
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

container_stop() {
    local stack_dir=$1
    local service=$2
    cd "$stack_dir" || return
    view_start
    confirm "Stop $service?" || return
    echo -e "${RED}Stopping $service...${NC}\n"
    docker compose stop "$service"
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

container_start() {
    local stack_dir=$1
    local service=$2
    cd "$stack_dir" || return
    view_start
    echo -e "${GREEN}Starting $service...${NC}\n"
    docker compose start "$service"
    echo -e "\n${GREEN}Done!${NC}"
    press_any_key
}

container_top() {
    local container_id=$1
    local service=$2
    view_start
    echo -e "${BOLD}${CYAN}=== Process List: $service ===${NC}\n"
    docker top "$container_id"
    echo -e "\n${DIM}Snapshot taken${NC}"
    press_any_key
}

container_stats() {
    local container_id=$1
    local service=$2
    view_start
    echo -e "${BOLD}${CYAN}=== Live Stats: $service ===${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop monitoring${NC}\n"

    # Use docker stats in streaming mode
    docker stats "$container_id" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"

    echo -e "\n${DIM}Monitoring stopped${NC}"
    press_any_key
}

# Network view for a single container
container_network_view() {
    local container_id=$1
    local service=$2
    view_start
    echo -e "${BOLD}${CYAN}=== Network View: $service ===${NC}\n"

    # Get container state
    local state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    local status_color=$GREEN
    [ "$state" != "running" ] && status_color=$RED
    echo -e "Status: ${status_color}${state}${NC}\n"

    # Network mode
    local network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$container_id" 2>/dev/null)
    echo -e "${BOLD}Network Mode:${NC} $network_mode"

    # Check if using another container's network
    if [[ "$network_mode" == container:* ]]; then
        local shared_container="${network_mode#container:}"
        echo -e "  ${YELLOW}→ Shares network stack with: $shared_container${NC}"
    fi
    echo

    # Networks and IPs
    echo -e "${BOLD}Networks:${NC}"
    local networks=$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}|{{$v.IPAddress}}|{{$v.Gateway}}|{{$v.MacAddress}}
{{end}}' "$container_id" 2>/dev/null)

    if [ -n "$networks" ]; then
        while IFS='|' read -r net_name ip gateway mac; do
            [ -z "$net_name" ] && continue
            echo -e "  ${CYAN}$net_name${NC}"
            [ -n "$ip" ] && echo -e "    IP Address: ${GREEN}$ip${NC}"
            [ -n "$gateway" ] && echo -e "    Gateway:    ${DIM}$gateway${NC}"
            [ -n "$mac" ] && echo -e "    MAC:        ${DIM}$mac${NC}"
        done <<< "$networks"
    else
        echo -e "  ${DIM}(no networks)${NC}"
    fi
    echo

    # Port mappings
    echo -e "${BOLD}Port Mappings:${NC}"
    local ports=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}}={{range $conf}}{{.HostIp}}:{{.HostPort}},{{end}}|{{end}}' "$container_id" 2>/dev/null)

    if [ -n "$ports" ] && [ "$ports" != "" ]; then
        local has_ports=false
        read_array port_list '|' "$ports"
        for port_entry in "${port_list[@]}"; do
            [ -z "$port_entry" ] && continue
            local container_port="${port_entry%%=*}"
            local host_bindings="${port_entry#*=}"
            [ -z "$host_bindings" ] || [ "$host_bindings" = "," ] && continue
            has_ports=true
            # Remove trailing comma
            host_bindings="${host_bindings%,}"
            echo -e "  ${GREEN}$container_port${NC} → $host_bindings"
        done
        [ "$has_ports" = false ] && echo -e "  ${DIM}(no ports exposed)${NC}"
    else
        echo -e "  ${DIM}(no ports exposed)${NC}"
    fi

    echo
    press_any_key
}

# Network view for ALL stacks (TUI): straight from the snapshot
all_stacks_network_view() {
    view_start
    echo -e "${BOLD}${CYAN}=== Network View: All Stacks ===${NC}"
    echo -e "${DIM}Snapshot from ${SNAPSHOT_TIME} · ${BASE_DIR}${NC}\n"

    local i id found_any=false entry net ip
    for ((i = 0; i < ${#STACK_NAMES[@]}; i++)); do
        [ "${STACK_UP[i]}" -gt 0 ] || continue
        found_any=true
        echo -e "${BOLD}${BLUE}[${STACK_NAMES[i]}]${NC}"
        for id in ${STACK_CIDS[i]}; do
            [ "${C_KIND[$id]}" = up ] || continue
            container_dot "$id"
            echo -e "  $REPLY ${BOLD}${C_SERVICE[$id]}${NC}"
            shared_network_host "$id"
            if [ -n "$REPLY" ]; then
                echo -e "    ${YELLOW}Network: via $REPLY${NC}"
            else
                for entry in ${C_NETS[$id]}; do
                    net="${entry%%=*}"; ip="${entry#*=}"
                    if [ -n "$ip" ]; then
                        echo -e "    Network: ${CYAN}$net${NC} (${GREEN}$ip${NC})"
                    else
                        echo -e "    Network: ${CYAN}$net${NC} ${DIM}(host network)${NC}"
                    fi
                done
            fi
            [ -n "${C_PORTS[$id]}" ] && echo -e "    Ports: ${DIM}${C_PORTS[$id]}${NC}"
        done
        echo
    done

    [ "$found_any" = false ] && echo -e "${YELLOW}No running stacks found${NC}"
    press_any_key
}

# Parse bytes from human-readable format (e.g., "1.5GB", "256MB", "1.2kB")
# Uses portable calc() function for math
parse_bytes() {
    local value="$1"
    local num=$(echo "$value" | sed 's/[^0-9.]//g')
    local unit=$(echo "$value" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

    # Handle empty or invalid input
    [ -z "$num" ] && echo "0" && return

    case "$unit" in
        TB) calc_int "$num * 1099511627776" ;;
        GB) calc_int "$num * 1073741824" ;;
        MB) calc_int "$num * 1048576" ;;
        KB) calc_int "$num * 1024" ;;
        B)  echo "${num%.*}" ;;
        *)  echo "0" ;;
    esac
}

# Format bytes per second to human readable
# Uses portable calc() function for math
format_rate() {
    local bytes_per_sec=$1
    if [ -z "$bytes_per_sec" ] || [ "$bytes_per_sec" = "0" ]; then
        echo "0 B/s"
        return
    fi

    # Convert to integer for comparison
    local int_bytes=${bytes_per_sec%.*}
    [ -z "$int_bytes" ] && int_bytes=0

    if [ "$int_bytes" -ge 1073741824 ]; then
        printf "%.1f GB/s" "$(calc "$bytes_per_sec / 1073741824")"
    elif [ "$int_bytes" -ge 1048576 ]; then
        printf "%.1f MB/s" "$(calc "$bytes_per_sec / 1048576")"
    elif [ "$int_bytes" -ge 1024 ]; then
        printf "%.1f KB/s" "$(calc "$bytes_per_sec / 1024")"
    else
        printf "%d B/s" "$int_bytes"
    fi
}

# Live traffic stats for ALL stacks with per-second rates
all_stacks_traffic_stats() {
    # Collect all container IDs from all stacks
    local all_containers="" id
    keys_of C_KIND
    for id in "${KEYS[@]}"; do
        [ "${C_KIND[$id]}" = up ] && all_containers+="$id "
    done
    all_containers="${all_containers% }"

    if [ -z "$all_containers" ]; then
        view_start
        echo -e "${BOLD}${CYAN}=== Live Traffic: All Stacks ===${NC}"
        echo -e "${YELLOW}No running containers found${NC}"
        press_any_key
        return
    fi

    # Use temp file to store previous values and timestamp
    local tmp_file="/tmp/docker_stats_$$"
    local time_file="/tmp/docker_stats_time_$$"
    # Ctrl+C ends the loop (and returns to the menu) instead of quitting
    local stop=0
    trap 'stop=1' INT

    local cycle=0
    local sample_interval=10  # 10 second cycle

    while [ $stop -eq 0 ]; do
        local start_time=$(date +%s)

        # Get current stats
        local stats_output=$(docker stats --no-stream $all_containers --format '{{.Name}}|{{.NetIO}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null)
        [ $stop -eq 1 ] && break

        # Calculate actual elapsed time since last sample
        local actual_interval=$sample_interval
        if [ -f "$time_file" ]; then
            local prev_time=$(cat "$time_file")
            actual_interval=$((start_time - prev_time))
            [ "$actual_interval" -lt 1 ] && actual_interval=1
        fi

        view_start
        echo -e "${BOLD}${CYAN}=== Live Traffic: All Stacks ===${NC}"
        echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
        echo -e "${DIM}Cycle: $cycle | Refresh: ${sample_interval}s | Showing: avg/s${NC}\n"

        printf "${BOLD}%-25s %12s %12s %10s %15s${NC}\n" "CONTAINER" "RX/s (avg)" "TX/s (avg)" "CPU %" "MEM USAGE"
        echo "─────────────────────────────────────────────────────────────────────────────"

        while IFS='|' read -r name net_io cpu mem; do
            [ -z "$name" ] && continue

            # Parse RX / TX from NetIO (format: "1.5GB / 256MB")
            local rx_str=$(echo "$net_io" | cut -d'/' -f1 | xargs)
            local tx_str=$(echo "$net_io" | cut -d'/' -f2 | xargs)

            # Convert to bytes
            local rx_bytes=$(parse_bytes "$rx_str")
            local tx_bytes=$(parse_bytes "$tx_str")

            # Get previous values from temp file
            local prev_rx=0
            local prev_tx=0
            if [ -f "$tmp_file" ]; then
                local prev_line=$(grep "^${name}|" "$tmp_file" 2>/dev/null)
                if [ -n "$prev_line" ]; then
                    prev_rx=$(echo "$prev_line" | cut -d'|' -f2)
                    prev_tx=$(echo "$prev_line" | cut -d'|' -f3)
                fi
            fi

            # Calculate per-second rate (average over interval)
            local rx_rate="--"
            local tx_rate="--"

            if [ "$cycle" -gt 0 ] && [ -n "$prev_rx" ] && [ "$prev_rx" != "0" ]; then
                local rx_diff=$(calc_int "$rx_bytes - $prev_rx")
                local tx_diff=$(calc_int "$tx_bytes - $prev_tx")

                # Avoid negative (container restart)
                [ "${rx_diff:0:1}" = "-" ] && rx_diff="0"
                [ "${tx_diff:0:1}" = "-" ] && tx_diff="0"

                # Calculate per-second average
                local rx_per_sec=$(calc_int "$rx_diff / $actual_interval")
                local tx_per_sec=$(calc_int "$tx_diff / $actual_interval")

                rx_rate=$(format_rate "$rx_per_sec")
                tx_rate=$(format_rate "$tx_per_sec")
            fi

            # Truncate container name if too long
            local display_name="$name"
            [ ${#display_name} -gt 24 ] && display_name="${display_name:0:21}..."

            # Color code based on activity
            local rx_color=$NC
            local tx_color=$NC
            if [ "$rx_rate" != "--" ] && [ "$rx_rate" != "0 B/s" ]; then
                rx_color=$GREEN
            fi
            if [ "$tx_rate" != "--" ] && [ "$tx_rate" != "0 B/s" ]; then
                tx_color=$CYAN
            fi

            printf "%-25s ${rx_color}%12s${NC} ${tx_color}%12s${NC} %10s %15s\n" \
                "$display_name" "$rx_rate" "$tx_rate" "$cpu" "$mem"

        done <<< "$stats_output"

        # Save current values to temp file for next iteration
        echo "$stats_output" | while IFS='|' read -r name net_io cpu mem; do
            [ -z "$name" ] && continue
            local rx_str=$(echo "$net_io" | cut -d'/' -f1 | xargs)
            local tx_str=$(echo "$net_io" | cut -d'/' -f2 | xargs)
            local rx_bytes=$(parse_bytes "$rx_str")
            local tx_bytes=$(parse_bytes "$tx_str")
            echo "${name}|${rx_bytes}|${tx_bytes}"
        done > "$tmp_file"

        # Save timestamp for next iteration
        echo "$start_time" > "$time_file"

        echo -e "\n${DIM}Containers: $(echo $all_containers | wc -w) | Next refresh in ${sample_interval}s${NC}"
        ((cycle++))

        # Sleep for the sample interval (minus time already spent collecting)
        local elapsed=$(($(date +%s) - start_time))
        local sleep_time=$((sample_interval - elapsed))
        [ "$sleep_time" -gt 0 ] && sleep "$sleep_time"
    done

    trap 'TUI_INT=1' INT
    rm -f "$tmp_file" "$time_file" 2>/dev/null
    echo -e "\n${DIM}Monitoring stopped${NC}"
    press_any_key
}

# Main display function (non-interactive)
show_status() {
    # docker system df takes ~0.7s; start it now so it overlaps the rest
    local df_file="" df_pid=""
    if [ "$VERBOSE" = true ]; then
        df_file=$(mktemp)
        docker system df -v --format '{{range .Volumes}}{{.Name}}|{{.Size}};{{end}}' > "$df_file" 2>/dev/null &
        df_pid=$!
    fi
    if [ "$SHOW_STATS" = true ]; then load_snapshot stats; else load_snapshot; fi

    echo -e "${BOLD}=== Docker Compose Stack Status ===${NC}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

    # Check watchtower status
    watchtower_container=$(docker ps --filter "name=watchtower" --format "{{.ID}}" 2>/dev/null)
    if [ -n "$watchtower_container" ]; then
        echo -e "${BOLD}${CYAN}Watchtower:${NC}"

        # Get uptime (using portable date parsing)
        started_raw=$(docker inspect --format='{{.State.StartedAt}}' "$watchtower_container" 2>/dev/null)
        if [ -n "$started_raw" ]; then
            started=$(date_to_epoch "$started_raw")
            if [ -n "$started" ] && [ "$started" != "0" ]; then
                uptime=$(format_uptime $started)
                echo -e "  Running for: $uptime"
            fi
        fi

        # Recent logs only: with debug logging on, the full log can be many MB.
        # 8 days covers daily and weekly schedules.
        wt_logs=$(docker logs --since 192h "$watchtower_container" 2>&1)

        next_run=$(watchtower_next_check "$watchtower_container" "$wt_logs")
        [ -n "$next_run" ] && echo -e "  Next check: $next_run"

        watchtower_last_session "$wt_logs"
        echo
    else
        echo -e "${YELLOW}⚠ Watchtower not running${NC}\n"
    fi

    local i n id now last tree pipe name
    local running_stacks=0 issue_stacks=0 stopped_stacks=0 c_up=0 c_bad=0 c_down=0
    local -a ids
    now=$(date +%s)
    for ((i = 0; i < ${#STACK_NAMES[@]}; i++)); do
        name=${STACK_NAMES[i]}
        ids=(${STACK_CIDS[i]})
        local count="${STACK_UP[i]} container"; [ "${STACK_UP[i]}" -ne 1 ] && count+="s"
        case "${STACK_STATUS[i]}" in
            stopped)
                stopped_stacks=$((stopped_stacks + 1))
                echo -e "${RED}✗${NC} ${BOLD}$name${NC} ${DIM}(stopped)${NC}\n"
                for id in "${ids[@]}"; do [ "${C_KIND[$id]}" = down ] && c_down=$((c_down + 1)); done
                continue
                ;;
            running)
                running_stacks=$((running_stacks + 1))
                echo -e "${GREEN}✓${NC} ${BOLD}$name${NC} ${DIM}($count)${NC}"
                ;;
            unhealthy)
                issue_stacks=$((issue_stacks + 1))
                echo -e "${YELLOW}⚠${NC} ${BOLD}$name${NC} ${YELLOW}(${STACK_UNHEALTHY[i]} unhealthy)${NC} ${DIM}($count)${NC}"
                ;;
            partial)
                issue_stacks=$((issue_stacks + 1))
                echo -e "${YELLOW}⚠${NC} ${BOLD}$name${NC} ${YELLOW}(${STACK_UP[i]}/${STACK_TOTAL[i]} running)${NC}"
                ;;
        esac

        last=$(( ${#ids[@]} - 1 ))
        for ((n = 0; n < ${#ids[@]}; n++)); do
            id=${ids[n]}
            tree="├─"; pipe="│ "
            [ $n -eq $last ] && { tree="└─"; pipe="  "; }
            case "${C_KIND[$id]}" in
                up)
                    c_up=$((c_up + 1))
                    [ "${C_HEALTH[$id]}" = unhealthy ] && c_bad=$((c_bad + 1))
                    ;;
                down) c_down=$((c_down + 1)) ;;
            esac
            container_dot "$id"; local dot=$REPLY
            container_summary "$id" "$now"
            echo -e "  ${DIM}${tree}${NC} ${C_SERVICE[$id]} ${dot} ${REPLY}"

            if [ "$SHOW_STATS" = true ] && [ -n "${C_CPU[$id]}" ]; then
                echo -e "  ${DIM}${pipe} CPU: ${C_CPU[$id]}  MEM: ${C_MEM[$id]}${NC}"
            fi
            if [ "$SHOW_PORTS" = true ] && [ -n "${C_PORTS[$id]}" ]; then
                echo -e "  ${DIM}${pipe} Ports: ${C_PORTS[$id]}${NC}"
            fi
            if [ "$SHOW_IMAGES" = true ] && [ -n "${C_IMAGE[$id]}" ]; then
                echo -e "  ${DIM}${pipe} Image: ${C_IMAGE[$id]}${NC}"
            fi
        done
        echo
    done

    # Summary
    echo -e "${BOLD}=== Summary ===${NC}"
    echo -e "Stacks: ${#STACK_NAMES[@]} total, ${GREEN}$running_stacks running${NC}, ${YELLOW}$issue_stacks with issues${NC}, ${RED}$stopped_stacks stopped${NC}"
    echo -e "Containers: ${GREEN}$c_up running${NC}, ${RED}$c_bad unhealthy${NC}, ${RED}$c_down stopped${NC}"

    # Docker system info
    if [ "$VERBOSE" = true ]; then
        echo -e "\n${BOLD}=== System Resources ===${NC}"
        df_info=$(df -h /var/lib/docker 2>/dev/null | tail -1)
        if [ -n "$df_info" ]; then
            used=$(echo "$df_info" | awk '{print $3}')
            avail=$(echo "$df_info" | awk '{print $4}')
            pcent=$(echo "$df_info" | awk '{print $5}')
            echo -e "Docker storage: $used used, $avail available ($pcent)"
        fi

        # Show volume usage
        echo -e "\n${BOLD}Top 5 volumes by size:${NC}"
        wait "$df_pid"
        # Sizes are like 88B, 5.039MB, 1.2GB (decimal units); convert to bytes
        # for a portable numeric sort (BSD sort lacks -h on older macOS)
        tr ';' '\n' < "$df_file" |
            awk -F'|' 'NF == 2 {
                size = $2; num = size + 0; unit = size; gsub(/[0-9.]/, "", unit)
                mult = 1
                if (unit == "kB" || unit == "KB") mult = 1e3
                else if (unit == "MB") mult = 1e6
                else if (unit == "GB") mult = 1e9
                else if (unit == "TB") mult = 1e12
                name = $1; if (length(name) == 64 && name ~ /^[0-9a-f]+$/) name = substr(name, 1, 12)
                printf "%.0f\t%s\t%s\n", num * mult, size, name
            }' |
            sort -t "$(printf '\t')" -k1,1 -n -r | head -5 |
            while IFS=$'\t' read -r _ size name; do
                printf "  ${DIM}%-10s %s${NC}\n" "$size" "$name"
            done
        rm -f "$df_file"
    fi

    if [ $issue_stacks -gt 0 ] || [ $stopped_stacks -gt 0 ]; then
        echo -e "\n${YELLOW}Tip: Run with -I for interactive mode or -v for detailed diagnostics${NC}"
    fi
}

# Network visualization function
show_network() {
    load_snapshot
    echo -e "${BOLD}=== Docker Network Visualization ===${NC}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${DIM}Base directory: $BASE_DIR${NC}\n"

    # Members of each network, in stack order: "id=ip" (or "id=via:<host>"
    # for containers that share another container's network)
    local -A members=()
    local -a nets=()
    local i id entry net ip host_id
    for ((i = 0; i < ${#STACK_NAMES[@]}; i++)); do
        for id in ${STACK_CIDS[i]}; do
            [ "${C_KIND[$id]}" = up ] || continue
            if [[ "${C_NETMODE[$id]}" == container:* ]]; then
                host_id="${C_ID_BY_FULL[${C_NETMODE[$id]#container:}]:-}"
                [ -n "$host_id" ] || continue
                for entry in ${C_NETS[$host_id]}; do
                    net="${entry%%=*}"
                    [ -n "${members[$net]+x}" ] || nets+=("$net")
                    members[$net]+="$id=via:${C_NAME[$host_id]} "
                done
                continue
            fi
            for entry in ${C_NETS[$id]}; do
                net="${entry%%=*}"; ip="${entry#*=}"
                [ -n "${members[$net]+x}" ] || nets+=("$net")
                members[$net]+="$id=$ip "
            done
        done
    done

    if [ ${#nets[@]} -eq 0 ]; then
        echo -e "${YELLOW}No networks found for stacks in $BASE_DIR${NC}"
        return
    fi

    # Driver and subnet of every network, in one call
    local -A drivers=() subnets=()
    local name driver subnet
    while IFS='|' read -r name driver subnet; do
        drivers[$name]="$driver"
        subnets[$name]="$subnet"
    done < <(docker network inspect --format '{{.Name}}|{{.Driver}}|{{range .IPAM.Config}}{{.Subnet}}{{end}}' "${nets[@]}" 2>/dev/null)

    # Custom networks first, then the built-in bridge/host/none
    local -a custom_networks=() system_networks=()
    for net in "${nets[@]}"; do
        if [[ "$net" == "bridge" || "$net" == "host" || "$net" == "none" ]]; then
            system_networks+=("$net")
        else
            custom_networks+=("$net")
        fi
    done

    local -A unique=()
    for net in "${custom_networks[@]}" "${system_networks[@]}"; do
        driver="${drivers[$net]}"
        local net_icon="🌐" net_color=$CYAN
        case "$driver" in
            bridge) net_icon="🔗" ;;
            host) net_icon="🏠"; net_color=$MAGENTA ;;
            overlay) net_icon="☁️" ;;
            macvlan) net_icon="🔌" ;;
        esac
        echo -e "${net_color}${BOLD}$net_icon $net${NC}"
        echo -e "  ${DIM}Driver: $driver${NC}"
        [ -n "${subnets[$net]}" ] && echo -e "  ${DIM}Subnet: ${subnets[$net]}${NC}"
        echo -e "  ${DIM}Containers:${NC}"

        local -a list=(${members[$net]})
        local n last=$(( ${#list[@]} - 1 ))
        for ((n = 0; n < ${#list[@]}; n++)); do
            id="${list[n]%%=*}"; ip="${list[n]#*=}"
            unique[$id]=1
            local tree="├─"; [ $n -eq $last ] && tree="└─"
            container_dot "$id"
            local line="  ${DIM}$tree${NC} $REPLY ${C_NAME[$id]}"
            if [[ "$ip" == via:* ]]; then
                line+=" ${YELLOW}→ via ${ip#via:}${NC}"
            elif [ -n "$ip" ]; then
                line+=" ${DIM}($ip)${NC}"
            fi
            line+=" ${BLUE}[${STACK_NAMES[${C_STACK[$id]}]}]${NC}"
            echo -e "$line"
        done
        echo
    done

    echo -e "${BOLD}=== Network Summary ===${NC}"
    echo -e "Networks: ${#nets[@]} total (${#custom_networks[@]} custom, ${#system_networks[@]} system)"
    echo -e "Containers: ${#unique[@]} connected to networks"
    echo -e "\n${DIM}Legend: 🔗 bridge  🏠 host  ☁️ overlay  🔌 macvlan  🌐 other${NC}"
    echo -e "${DIM}Containers on the same network can communicate directly${NC}"
}

# Watch mode: redraw the status every 5 seconds, in place
watch_status() {
    local out
    if [ -t 1 ]; then
        tui_start
        trap 'exit 0' INT
    fi
    while true; do
        out=$(show_status 2>&1)
        if [ -t 1 ]; then
            # Clear each line's leftovers instead of the whole screen: no flicker
            out="${out//$'\n'/$'\033[K\n'}"
            printf '\033[H%s\033[K\n\n\033[2m%s\033[0m\033[K\033[J' "$out" "Refreshing every 5s · Ctrl+C to quit"
        else
            printf '%s\n\n' "$out"
        fi
        sleep 5
    done
}

# Main execution
if [ -n "$IMPORT_MODE" ]; then
    import_cli
    exit $?
elif [ "$INTERACTIVE" = true ]; then
    # The TUI reads single keypresses; without a terminal it would spin forever
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "Error: interactive mode (-I) needs a terminal" >&2
        exit 1
    fi
    tui_start
    # Ctrl+C stops a live view (logs, stats) and returns to the menu; in a
    # menu it quits (see read_menu_key)
    trap 'TUI_INT=1' INT
    load_snapshot
    interactive_stack_menu
elif [ "$SHOW_NETWORK" = true ]; then
    show_network
elif [ "$WATCH_MODE" = true ]; then
    watch_status
else
    show_status
fi
