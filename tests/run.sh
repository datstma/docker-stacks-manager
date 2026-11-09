#!/usr/bin/env bash
#
# Portability tests. Needs only bash 4+ and the platform's own awk/sed/date/
# sort/find - no Docker: docker calls are answered from tests/fixtures.
# Run on each platform you want to support:  ./tests/run.sh
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
SCRIPT="$ROOT/docker-stacks-manager.sh"

failures=0
pass() { printf '  \033[0;32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       /'; failures=$((failures + 1)); }
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}
ESC=$'\033'
strip_ansi() { sed "s/${ESC}\[[0-9;?]*[a-zA-Z]//g"; }  # BSD sed has no \x1b
# Load single functions from the script without running it
load_fn() { eval "$(sed -n "/^$1() {/,/^}/p" "$SCRIPT")"; }
# The shell-compatibility helpers every other function may use
DSM_SHELL=bash NL=$'\n'
for fn in read_char read_array keys_of lower; do load_fn "$fn"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Platform: $(uname -s) $(uname -r), bash $BASH_VERSION"

# --------------------------------------------------------------------------
echo "Unit tests"

load_fn date_to_epoch
for tz in UTC Europe/Stockholm America/New_York Asia/Tokyo; do
    got=$(TZ=$tz date_to_epoch "2026-01-01T00:00:00.123456789Z")
    [[ "$got" == 1767225600 ]] && pass "date_to_epoch reads Docker timestamps as UTC (TZ=$tz)" \
        || fail "date_to_epoch reads Docker timestamps as UTC (TZ=$tz)" "expected 1767225600, got '$got'"
done
got=$(date_to_epoch "2026-01-01T00:00:00Z")
[[ "$got" == 1767225600 ]] && pass "date_to_epoch without fractional seconds" \
    || fail "date_to_epoch without fractional seconds" "expected 1767225600, got '$got'"

eval "$(sed -n '/^COMPOSE_FILENAMES=/p' "$SCRIPT")"
load_fn find_compose_files
mkdir -p "$TMP/stacks/a" "$TMP/stacks/b b" "$TMP/stacks/c" "$TMP/stacks/d/nested" "$TMP/stacks/e"
touch "$TMP/stacks/a/compose.yaml" "$TMP/stacks/b b/docker-compose.yml" \
      "$TMP/stacks/c/docker-compose.yml" "$TMP/stacks/c/compose.yml" \
      "$TMP/stacks/d/nested/compose.yaml" "$TMP/stacks/e/notes.txt"
got=$(BASE_DIR="$TMP/stacks" find_compose_files | sed "s|^$TMP/stacks/||")
expected=$'a/compose.yaml\nb b/docker-compose.yml\nc/compose.yml'
[[ "$got" == "$expected" ]] && pass "find_compose_files: all names, one per stack, preferred name wins" \
    || fail "find_compose_files: all names, one per stack, preferred name wins" "expected:"$'\n'"$expected"$'\n'"got:"$'\n'"$got"

load_fn version_gt
check "version_gt: newer minor" version_gt 1.10.0 1.9.3
check "version_gt: tag prefix and extra part" version_gt v1.0.1 1.0
not() { ! "$@"; }
check "version_gt: equal is not newer" not version_gt 1.0.0 1.0.0
check "version_gt: older is not newer" not version_gt 1.0.0 1.0.1

load_fn self_path
mkdir -p "$TMP/real dir" "$TMP/bin"
touch "$TMP/real dir/tool.sh"
ln -s "../real dir/tool.sh" "$TMP/bin/rel-link"
ln -s "$TMP/bin/rel-link" "$TMP/bin/abs-link"
got=$(self_path "$TMP/bin/abs-link")
expected="$(cd -P "$TMP/real dir" && pwd)/tool.sh"
[[ "$got" == "$expected" ]] && pass "self_path follows relative and absolute symlinks" \
    || fail "self_path follows relative and absolute symlinks" "expected '$expected', got '$got'"

# Watchtower: docker is replaced by a shell function returning canned answers
for fn in epoch_to_local format_duration watchtower_time_to_epoch watchtower_next_check watchtower_last_session; do
    load_fn "$fn"
done
GREEN="" YELLOW="" DIM="" NC=""
WT_ENV="" WT_FULL_LOGS=""
docker() {
    case "$1" in
        inspect) printf '%s\n' "$WT_ENV" ;;
        logs) printf '%s\n' "$WT_FULL_LOGS" ;;
    esac
}
expect() { # expect <description> <actual> <extended regex>
    if printf '%s\n' "$2" | grep -qE -- "$3"; then pass "$1"
    else fail "$1" "expected to match: $3"$'\n'"got: '$2'"; fi
}

got=$(watchtower_next_check wt 'time="x" level=debug msg="Scheduled next run: 2099-01-01 04:00:00 +0100 CET"')
expect "watchtower: uses logged next run when in the future" "$got" '^2099-01-01 04:00 CET$'

WT_ENV=$'WATCHTOWER_SCHEDULE=0 0 4 * * *\nTZ=UTC'
got=$(TZ=UTC watchtower_next_check wt 'msg="Scheduled next run: 2020-01-01 04:00:00 +0100 CET"')
expect "watchtower: stale logged run ignored, daily cron resolved" "$got" '^[0-9]{4}-[0-9]{2}-[0-9]{2} 04:00 UTC \(daily\)$'

WT_ENV=$'WATCHTOWER_SCHEDULE="0 30 4 * * *"\nTZ=Asia/Tokyo'
got=$(TZ=America/New_York watchtower_next_check wt "")
expect "watchtower: daily cron shown in the container's time zone" "$got" '^[0-9]{4}-[0-9]{2}-[0-9]{2} 04:30 JST \(daily\)$'

WT_ENV='WATCHTOWER_SCHEDULE=0 */5 * * * *'
got=$(watchtower_next_check wt "")
expect "watchtower: other cron schedules shown as-is" "$got" '^schedule: 0 \*/5 \* \* \* \*$'

WT_ENV='WATCHTOWER_POLL_INTERVAL=3600'
WT_FULL_LOGS='time="2020-01-01T00:00:00Z" level=info msg="Scheduling first run: 2020-01-01 00:00:00 +0000 UTC"'
got=$(TZ=UTC watchtower_next_check wt "")
expect "watchtower: poll interval counted from first run" "$got" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:00 UTC \(every 1h\)$'

WT_ENV="" WT_FULL_LOGS=""
got=$(watchtower_next_check wt "")
expect "watchtower: default 24h poll interval" "$got" '^every 24h$'

session_logs='time="2026-11-07T04:00:00+01:00" level=info msg="Session done" Failed=0 Scanned=3 Updated=0 notify=no
time="2026-11-08T04:01:19+01:00" level=info msg="Unable to update container \"/app-db\": Error response from daemon: failed to resolve reference"
time="2026-11-08T04:01:24+01:00" level=info msg="Found new example/web:latest image (44a82caf5b86)"
time="2026-11-08T04:01:53+01:00" level=info msg="Stopping /web (0a5399da2f5a) with SIGTERM"
time="2026-11-08T04:02:08+01:00" level=info msg="Creating /web"
time="2026-11-08T04:02:09+01:00" level=info msg="Creating /web-worker"
time="2026-11-08T04:02:12+01:00" level=info msg="Session done" Failed=0 Scanned=3 Updated=2 notify=no
time="2026-11-08T04:02:12+01:00" level=debug msg="Scheduled next run: 2026-11-09 04:00:00 +0100 CET"'
got=$(watchtower_last_session "$session_logs")
expect "watchtower: last session time and counts" "$got" 'Last check: 2026-11-08 04:02 \(3 scanned, 2 updated\)'
expect "watchtower: new images listed" "$got" 'New images: example/web:latest$'
expect "watchtower: recreated containers listed" "$got" 'Recreated: web, web-worker$'
expect "watchtower: unreachable containers listed" "$got" 'Could not check: app-db '
got=$(watchtower_last_session "$(printf '%s\n' "$session_logs" | head -1)")
expect "watchtower: quiet session says no updates" "$got" 'No updates needed'
unset -f docker

# Snapshot: classification and stack matching, with canned docker output
for fn in compose_project_name load_snapshot stack_badge container_dot container_summary format_uptime; do
    load_fn "$fn"
done
eval "$(sed -n '/^# Per stack (index/,/^SNAPSHOT_TIME=/p' "$SCRIPT")"   # the snapshot's arrays
GREEN="" YELLOW="" RED="" CYAN="" DIM="" NC=""
mkdir -p "$TMP/snap/app" "$TMP/snap/My Stack" "$TMP/snap/jobs" "$TMP/snap/empty"
for d in app "My Stack" jobs empty; do touch "$TMP/snap/$d/compose.yaml"; done
PS_OUT="app|$TMP/snap/app|web|aaaaaaaaaaa1|app-web-1|running|Up 2 hours (healthy)
app|$TMP/snap/app|db|aaaaaaaaaaa2|app-db-1|running|Up 2 hours (unhealthy)
mystack|/somewhere/else/My Stack|api|bbbbbbbbbbb1|mystack-api-1|running|Up 5 minutes
mystack|/somewhere/else/My Stack|cron|bbbbbbbbbbb2|mystack-cron-1|exited|Exited (1) 1 hour ago
jobs|$TMP/snap/jobs|seed|ccccccccccc1|jobs-seed-1|exited|Exited (0) 3 days ago
other|/not/a/stack/here|x|ddddddddddd1|other-x-1|running|Up 1 minute"
INSPECT_OUT="aaaaaaaaaaa1ffff|2026-01-01T00:00:00Z|0|true|nginx:1|bridge|0|unless-stopped|80/tcp -> 8080 |app_default=172.20.0.2 
aaaaaaaaaaa2ffff|2026-01-01T00:00:00Z|3||postgres:16|bridge|0|unless-stopped||app_default=172.20.0.3 
bbbbbbbbbbb1ffff|2026-01-01T00:00:00Z|0||api:1|container:aaaaaaaaaaa1ffff|0|always||
bbbbbbbbbbb2ffff|0001-01-01T00:00:00Z|0||cron:1|bridge|1|unless-stopped||
ccccccccccc1ffff|0001-01-01T00:00:00Z|0||seed:1|bridge|0|no||"
docker() {
    case "$1" in
        ps) printf '%s\n' "$PS_OUT" ;;
        inspect) printf '%s\n' "$INSPECT_OUT" ;;
    esac
}
BASE_DIR="$TMP/snap" load_snapshot
idx() { local i; for i in "${!STACK_NAMES[@]}"; do [ "${STACK_NAMES[i]}" = "$1" ] && echo "$i"; done; }
a=$(idx app) m=$(idx "My Stack") j=$(idx jobs) e=$(idx empty)
expect "snapshot: matched by working directory" "${STACK_CIDS[a]}" '^aaaaaaaaaaa2 aaaaaaaaaaa1 $'
expect "snapshot: matched by project name when the directory differs" "${STACK_CIDS[m]}" 'bbbbbbbbbbb1 bbbbbbbbbbb2'
expect "snapshot: containers outside the stacks are ignored" "${C_STATE[ddddddddddd1]:-none}" '^none$'
expect "snapshot: running + unhealthy -> unhealthy stack" "${STACK_STATUS[a]} ${STACK_UP[a]}/${STACK_TOTAL[a]} ${STACK_UNHEALTHY[a]}" '^unhealthy 2/2 1$'
expect "snapshot: crashed service -> partial stack" "${STACK_STATUS[m]} ${STACK_UP[m]}/${STACK_TOTAL[m]}" '^partial 1/2$'
expect "snapshot: exit 0 with restart no -> done" "${C_KIND[ccccccccccc1]}" '^done$'
expect "snapshot: exit 1 -> down" "${C_KIND[bbbbbbbbbbb2]}" '^down$'
expect "snapshot: only finished jobs -> stopped stack" "${STACK_STATUS[j]}" '^stopped$'
expect "snapshot: no containers -> stopped stack" "${STACK_STATUS[e]} ${STACK_TOTAL[e]}" '^stopped 0$'
expect "snapshot: started time parsed" "${C_STARTED[aaaaaaaaaaa1]}" '^1767225600$'
expect "snapshot: shared network resolved to host" "${C_ID_BY_FULL[aaaaaaaaaaa1ffff]}" '^aaaaaaaaaaa1$'
expect "snapshot: ports and networks" "${C_PORTS[aaaaaaaaaaa1]}|${C_NETS[aaaaaaaaaaa1]}" '^80/tcp -> 8080\|app_default=172.20.0.2$'
stack_badge "$m"
expect "badge: partial" "$REPLY" '^◐ 1/2 running$'
container_summary aaaaaaaaaaa2 1767232800
expect "summary: uptime, unhealthy and restarts" "$REPLY" '^2h 0m unhealthy ↻3$'
container_summary aaaaaaaaaaa1 1767232800
expect "summary: watchtower badge" "$REPLY" '\[auto\]$'
unset -f docker

# --------------------------------------------------------------------------
echo "Import (docker run commands and containers -> compose)"

eval "$(sed -n '/^declare -A SP=/p' "$SCRIPT")"
for fn in sp_reset sp_add sp_has sp_add_once sp_warn shell_split run_short_opt run_option_kind \
          run_apply spec_add_volume spec_add_mount spec_add_network run_to_spec convert_command \
          ns_to_duration bytes_to_size inspect_to_spec spec_finish yaml_q yaml_flow spec_to_compose; do
    load_fn "$fn"
done
VERSION=test

shell_split $'docker run -e "A=b c" -e \'D=$E\' \\\n  --name x\\ y img # comment'
expect "shell_split: quotes, escapes, continuation, comment" "$(printf '[%s]' "${TOKS[@]}")" \
    '^\[docker\]\[run\]\[-e\]\[A=b c\]\[-e\]\[D=\$E\]\[--name\]\[x y\]\[img\]$'
check "shell_split: unclosed quote is an error" not shell_split 'docker run "oops'

compose_of() { # compose_of <docker run command>  -> $TMP/conv.yaml
    convert_command "$1" && spec_to_compose > "$TMP/conv.yaml"
}
yhas() { grep -qF -- "$1" "$TMP/conv.yaml"; }
compose_of 'sudo docker run -dit --name=Web_1 --restart unless-stopped -p 8080:80 -p127.0.0.1:8443:443 \
  -v /srv/html:/usr/share/nginx/html:ro -v cache:/var/cache --mount type=tmpfs,target=/tmp,tmpfs-size=64m \
  -e TZ=Europe/Stockholm --env "MSG=hello \"world\"" --network proxy --ip 172.20.0.5 --network-alias www \
  --ulimit nofile=1024:2048 --health-cmd "curl -f http://localhost || exit 1" --gpus all --rm \
  nginx:1.27 nginx -g "daemon off;" | tee log'
check "convert: service named after the container" yhas "  web_1:"
check "convert: image and container_name" bash -c "grep -qF 'image: \"nginx:1.27\"' '$TMP/conv.yaml' && grep -qF 'container_name: \"Web_1\"' '$TMP/conv.yaml'"
check "convert: command as a list" yhas 'command: ["nginx", "-g", "daemon off;"]'
check "convert: ports, also -pVALUE" bash -c "grep -qF -- '- \"8080:80\"' '$TMP/conv.yaml' && grep -qF -- '- \"127.0.0.1:8443:443\"' '$TMP/conv.yaml'"
check "convert: quotes in values escaped" yhas '- "MSG=hello \"world\""'
check "convert: named volume declared external" bash -c "grep -A1 '^  \"cache\":' '$TMP/conv.yaml' | grep -q 'external: true'"
check "convert: --mount tmpfs" yhas '- "/tmp:size=64m"'
check "convert: network with ip and alias" bash -c "grep -qF 'ipv4_address: \"172.20.0.5\"' '$TMP/conv.yaml' && grep -qF 'aliases: [\"www\"]' '$TMP/conv.yaml'"
check "convert: combined short flags (-dit)" bash -c "grep -q 'tty: true' '$TMP/conv.yaml' && grep -q 'stdin_open: true' '$TMP/conv.yaml'"
check "convert: ulimits soft/hard" bash -c "grep -A2 'nofile:' '$TMP/conv.yaml' | grep -q 'hard: 2048'"
check "convert: healthcheck as CMD-SHELL" yhas 'test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]'
check "convert: GPUs" yhas 'count: all'
check "convert: notes for --rm and the pipe" bash -c "grep -q '^#   - --rm' '$TMP/conv.yaml' && grep -q 'Stopped at \"|\"' '$TMP/conv.yaml'"
compose_of 'docker run -e PASS=$SECRET alpine'
check "convert: \$VARIABLES left for compose, with a note" bash -c "grep -qF -- '- \"PASS=\$SECRET\"' '$TMP/conv.yaml' && grep -q 'Compose fills in' '$TMP/conv.yaml'"
check "convert: service named after the image" yhas "  alpine:"
convert_command 'docker ps -a'; rc=$?
expect "convert: not a docker run command" "$rc $REPLY" '^1 not a docker run command$'
convert_command 'docker run -d -p 80:80'; rc=$?
expect "convert: no image" "$rc $REPLY" '^1 no image in the command$'

# Containers: docker inspect answered from tests/import (recorded from a test daemon)
docker() {
    local id
    case "$1 $2" in
        "inspect --type") cat "$ROOT/tests/import/${*: -1}.container" 2>/dev/null || return 1 ;;
        "image inspect")
            id=$(grep -l "^imageid"$'\t'"${*: -1}\$" "$ROOT"/tests/import/*.container | head -1)
            cat "${id%.container}.image" ;;
    esac
}
import_of() { inspect_to_spec "$1" && spec_to_compose > "$TMP/conv.yaml"; }
import_of web
check "import: image defaults left out (PATH, image labels)" bash -c "! grep -qE 'PATH=|maintainer' '$TMP/conv.yaml'"
check "import: \$ doubled so compose keeps it literal" yhas '- "PRICE=$$5"'
check "import: restart policy and ports" bash -c "grep -qF 'restart: \"unless-stopped\"' '$TMP/conv.yaml' && grep -qF -- '- \"127.0.0.1:8443:443\"' '$TMP/conv.yaml'"
check "import: existing volume kept as external, bind mount read-only" bash -c "grep -A1 '^  \"webdata\":' '$TMP/conv.yaml' | grep -q 'external: true' && grep -qF -- '- \"/srv/html:/srv:ro\"' '$TMP/conv.yaml'"
check "import: static IP and alias, not the container's own names" bash -c "grep -qF 'ipv4_address: \"172.30.0.50\"' '$TMP/conv.yaml' && grep -qF 'aliases: [\"www\"]' '$TMP/conv.yaml'"
check "import: limits" bash -c "grep -qF 'mem_limit: \"256m\"' '$TMP/conv.yaml' && grep -q '^    cpus: 0.5$' '$TMP/conv.yaml'"
check "import: healthcheck with interval" bash -c "grep -qF 'test: [\"CMD-SHELL\", \"wget -qO- localhost || exit 1\"]' '$TMP/conv.yaml' && grep -qF 'interval: \"30s\"' '$TMP/conv.yaml'"
check "import: watchtower label kept" yhas '- "com.centurylinklabs.watchtower.enable=true"'
check "import: no hostname (the default one)" bash -c "! grep -q 'hostname:' '$TMP/conv.yaml'"
import_of job
check "import: entrypoint and command together" bash -c "grep -qF 'entrypoint: [\"sh\"]' '$TMP/conv.yaml' && grep -qF 'command: [\"-c\", \"echo hi > /data/x; sleep 3600\"]' '$TMP/conv.yaml'"
import_of anon
check "import: anonymous volume kept by its ID" bash -c "grep -qE -- '- \"[0-9a-f]{64}:/data\"' '$TMP/conv.yaml' && grep -q 'anonymous volume at /data' '$TMP/conv.yaml'"
import_of managed; rc=$?
expect "import: refuses a container compose already manages" "$rc $REPLY" '^1 .* is already part of the compose stack conv1$'
import_of nosuch; rc=$?
expect "import: missing container" "$rc $REPLY" '^1 no such container: nosuch$'
unset -f docker

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------

run() { # run <name> [args...]  -> $TMP/<name>.out / .err / .missing
    local name="$1"; shift
    ( cd "$ROOT/demo/stacks" &&
      PATH="$ROOT/tests/bin:$PATH" DSM_FAKE_DOCKER=replay DSM_FAKE_MISSING="$TMP/$name.missing" \
      DSM_SHELL="$E2E_SHELL" "$SCRIPT" "$@" ) > "$TMP/$name.raw" 2> "$TMP/$name.err" < /dev/null
    echo $? > "$TMP/$name.rc"
    strip_ansi < "$TMP/$name.raw" > "$TMP/$name.out"
}
has() { grep -qF -- "$2" "$TMP/$1.out"; }
clean_run() { # exit 0, nothing on stderr, every docker call had a fixture
    local name="$1" problems=""
    [[ "$(cat "$TMP/$name.rc")" == 0 ]] || problems+="exit code $(cat "$TMP/$name.rc")"$'\n'
    [[ -s "$TMP/$name.err" ]] && problems+="stderr:"$'\n'"$(cat "$TMP/$name.err")"$'\n'
    [[ -s "$TMP/$name.missing" ]] && problems+="unrecorded docker calls (re-run tests/record.sh):"$'\n'"$(cat "$TMP/$name.missing")"$'\n'
    [[ -z "$problems" ]] && pass "$name: runs cleanly" || fail "$name: runs cleanly" "$problems"
}

# Under bash, and under zsh when it is installed (macOS always has it). With
# DSM_SHELL=zsh the script hands itself over to zsh, as it does on bash 3.2.
e2e_shells=(bash)
command -v zsh >/dev/null 2>&1 && e2e_shells+=(zsh)
for E2E_SHELL in "${e2e_shells[@]}"; do
    echo "End-to-end under $E2E_SHELL (recorded docker output)"
    run status
    clean_run status
    check "status: stopped stack" has status "✗ backup (stopped)"
    check "status: partial stack shows running/total" has status "⚠ monitoring (1/2 running)"
    check "status: stopped service shows Docker's status" grep -qE 'alerts ● Exited \(137\)' "$TMP/status.out"
    check "status: healthy stack counts only long-running services" has status "✓ web-app (3 containers)"
    check "status: finished one-shot job shown as done" grep -qE 'migrate ✓ done \(Exited \(0\)' "$TMP/status.out"
    check "status: last container uses └─" grep -qE '└─ worker ●' "$TMP/status.out"
    check "status: watchtower label shown" grep -qE 'frontend ● .*\[auto\]' "$TMP/status.out"
    check "status: summary counts" has status "Stacks: 3 total, 1 running, 1 with issues, 1 stopped"
    check "status: container counts" has status "Containers: 4 running, 0 unhealthy, 2 stopped"
    check "status: uptimes are sane" bash -c "! grep -E '[├└]─ [a-z-]+ ● [0-9]' '$TMP/status.out' | grep -vqE '● ([0-9]+d [0-9]+h|[0-9]+h [0-9]+m|[0-9]+m)( |$)'"
    check "status: no screen-clearing codes in plain output" bash -c "! grep -q \$'\033\\[2J' '$TMP/status.raw'"

    run verbose -v
    clean_run verbose
    check "verbose: CPU and memory from one docker stats call" grep -qE 'CPU: [0-9.]+%  MEM: [0-9.]+[KMG]iB' "$TMP/verbose.out"
    check "verbose: ports shown" has verbose "Ports: 8080/tcp -> 18080"
    check "verbose: image shown" has verbose "Image: busybox:1.36"
    check "verbose: volumes sorted largest first" \
        bash -c "grep -A2 'Top 5 volumes' '$TMP/verbose.out' | tail -2 | awk '{print \$2}' | tr '\n' ' ' | grep -qx 'web-app_uploads web-app_cache '"

    run network -n
    clean_run network
    check "network: custom network listed" has network "web-app_app-net"
    check "network: container with IP" grep -qE 'web-app-frontend-1 \([0-9.]+\) \[web-app\]' "$TMP/network.out"
    check "network: shared-network container shown via its host" has network "web-app-sidecar-1 → via web-app-frontend-1 [web-app]"

    run help -h
    clean_run help
    check "help: lists interactive flag" has help "-I, --interactive"

    run version --version
    check "version: prints the script's version" grep -qE '^docker-stacks-manager [0-9]+\.[0-9]+\.[0-9]+$' "$TMP/version.out"

    run bad_dir -d /nonexistent/stacks
    check "--dir: missing directory is an error" grep -q "stacks directory not found: /nonexistent/stacks" "$TMP/bad_dir.err"

    run convert --print --convert docker run -d --name app -p 8080:80 nginx:1.27
    check "--convert --print: prints the compose file" bash -c "grep -qF 'container_name: \"app\"' '$TMP/convert.out' && grep -qF -- '- \"8080:80\"' '$TMP/convert.out'"

    run interactive -I
    check "interactive: refuses without a terminal" grep -q "needs a terminal" "$TMP/interactive.err"

    run import_web --import web --print
    check "--import --print: compose file from a container" bash -c "grep -qF 'container_name: \"web\"' '$TMP/import_web.out' && grep -qF -- '- \"PRICE=\$\$5\"' '$TMP/import_web.out'"
    cp "$TMP/import_web.out" "$TMP/import_web.$E2E_SHELL"
    run convert_cmd --print --convert 'docker run -d --name app -e "A=b c" -v data:/d nginx:1.27'
    cp "$TMP/convert_cmd.out" "$TMP/convert_cmd.$E2E_SHELL"
done
if [[ ${#e2e_shells[@]} -gt 1 ]]; then
    check "zsh: import output identical to bash" cmp -s "$TMP/import_web.bash" "$TMP/import_web.zsh"
    check "zsh: convert output identical to bash" cmp -s "$TMP/convert_cmd.bash" "$TMP/convert_cmd.zsh"
else
    echo "  (zsh not installed: skipped the zsh run)"
fi

# --------------------------------------------------------------------------
echo
if [[ $failures -eq 0 ]]; then
    echo "All tests passed"
else
    echo "$failures test(s) failed"
    exit 1
fi
