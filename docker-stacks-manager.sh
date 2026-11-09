#!/usr/bin/env bash
#
# Docker Stack Manager - Interactive TUI for Docker Compose stacks
# Runs on Linux, macOS (with bash 4+ from Homebrew) and Windows (WSL2, or Git Bash)
#
# Requirements:
#   - bash 4.0+ (for associative arrays)
#   - docker and docker compose
#   - Standard POSIX utilities: awk, sed, grep, cut, tr, wc, find, sort
#   - Optional: bc (for traffic stats - will use awk fallback if missing)
#

set -o pipefail

VERSION="1.0.0"
DSM_REPO="datstma/docker-stacks-manager"

# Base directory holding the stacks: -d/--dir, else $DSM_DIR, else the
# current working directory
BASE_DIR="${DSM_DIR:-$(pwd)}"

# ============================================================================
# Compatibility checks and fallbacks
# ============================================================================

# Check bash version (need 4.0+ for associative arrays)
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "Error: This script requires bash 4.0 or higher"
    echo "Current version: $BASH_VERSION"
    if [[ "$OSTYPE" == darwin* ]]; then
        echo "macOS ships bash 3.2. Install a newer one with: brew install bash"
        echo "then run this script again (it uses the first bash on your PATH)."
    fi
    exit 1
fi

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
    # Try GNU date first (Linux, WSL, Git Bash)
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

# Run docker with a TTY attached (docker exec -it ...).
# Git Bash's mintty terminal isn't a real Windows console, so docker can't
# attach to it without winpty. Windows Terminal (WT_SESSION) doesn't need it.
docker_tty() {
    if [[ -n "${MSYSTEM:-}" && -z "${WT_SESSION:-}" ]] && command -v winpty &>/dev/null; then
        winpty docker "$@"
    else
        docker "$@"
    fi
}

# Wait for any key press (not just Enter)
press_any_key() {
    local msg="${1:-Press any key to continue...}"
    echo -ne "${DIM}${msg}${NC}"
    read -rsn1
    echo
}

# ============================================================================
# Self-update (-U/--update)
# ============================================================================

# Print the real path of this script (or of $1), following symlinks; BSD has
# no readlink -f
self_path() {
    local path="${1:-${BASH_SOURCE[0]}}" dir link
    while [ -L "$path" ]; do
        dir="$(cd -P "$(dirname "$path")" && pwd)"
        link="$(readlink "$path")"
        [[ "$link" == /* ]] && path="$link" || path="$dir/$link"
    done
    echo "$(cd -P "$(dirname "$path")" && pwd)/$(basename "$path")"
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
            clock=$(TZ="${tz:-${TZ:-}}" date '+%H %M %S')
            read -r h m s <<< "$clock"
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
    local n="${1,,}"
    echo "${n//[^a-z0-9_-]/}"
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
    local i=0 file dir
    while IFS= read -r file; do
        dir="${file%/*}"
        STACK_DIRS[i]="$dir"
        STACK_NAMES[i]="${dir##*/}"
        STACK_CIDS[i]=""
        by_dir["$dir"]=$i
        by_project["$(compose_project_name "${dir##*/}")"]=$i
        i=$((i + 1))
    done < <(find_compose_files)

    local project wdir service id name state status idx ids=()
    while IFS='|' read -r project wdir service id name state status; do
        [ -z "$id" ] && continue
        idx=""
        [ -n "$wdir" ] && idx="${by_dir[$wdir]:-}"
        [ -z "$idx" ] && [ -n "$project" ] && idx="${by_project[$project]:-}"
        [ -z "$idx" ] && continue
        C_SERVICE[$id]="$service"
        C_NAME[$id]="$name"
        C_STATE[$id]="$state"
        C_STATUS[$id]="$status"
        C_STACK[$id]=$idx
        case "$status" in
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
    for i in "${!STACK_DIRS[@]}"; do
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
    for i in "${!STACK_DIRS[@]}"; do
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
    trap tui_end EXIT
}

tui_end() {
    if [ "$TUI_ACTIVE" = true ]; then
        printf '\033[?25h\033[?1049l'
        TUI_ACTIVE=false
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
    read -rsn1 answer
    echo
    [[ "$answer" == [yY] ]]
}

# Read one key for a menu. Sets KEY to: up, down, enter, esc, a character,
# "refresh" (no key within REFRESH_SECS) or "quit" (Ctrl+C).
read_menu_key() {
    local k rest rc
    TUI_INT=0
    read -rsn1 -t "$REFRESH_SECS" k
    rc=$?
    if [ "$TUI_INT" = 1 ]; then KEY=quit; return; fi
    if [ $rc -gt 128 ]; then KEY=refresh; return; fi
    case "$k" in
        $'\x1b')
            read -rsn2 -t 0.05 rest
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
        for i in "${!STACK_NAMES[@]}"; do
            if [ -z "$filter" ] || [[ "${STACK_NAMES[i],,}" == *"${filter,,}"* ]]; then
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
        frame+=("${CYAN}[L]ogs [R]estart [S]top [U]p [D]own [N]etwork [T]raffic${NC}")
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
            /)
                printf '\033[%d;1H\033[K\033[?25h/' "$rows"
                read -r filter
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
        for n in "${!ids[@]}"; do
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

        read -rsn1 action

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
                docker_tty exec -it "$container_id" bash 2>/dev/null || echo -e "${RED}Bash not available${NC}"
                press_any_key
                ;;
            7)
                view_start
                echo -e "${BOLD}${CYAN}=== Interactive Shell (sh): $service ===${NC}"
                echo -e "${YELLOW}Type 'exit' or press Ctrl+D to close shell${NC}\n"
                docker_tty exec -it "$container_id" sh 2>/dev/null || echo -e "${RED}Shell not available${NC}"
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
        IFS='|' read -ra port_list <<< "$ports"
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
    for i in "${!STACK_NAMES[@]}"; do
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
    for id in "${!C_KIND[@]}"; do
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
    for i in "${!STACK_NAMES[@]}"; do
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
        for n in "${!ids[@]}"; do
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
    for i in "${!STACK_NAMES[@]}"; do
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
        for n in "${!list[@]}"; do
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
if [ "$INTERACTIVE" = true ]; then
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
