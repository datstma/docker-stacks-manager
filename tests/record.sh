#!/usr/bin/env bash
#
# Re-record tests/fixtures from the demo stacks. Needs a real Docker.
# Run this after changing which docker commands the script calls.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

real_docker="$(command -v docker)"
./demo/demo.sh up >/dev/null 2>&1
# Give the different volumes different sizes so the size sort is exercised
docker exec web-app-worker-1 sh -c 'head -c 3000000 /dev/zero > /uploads/big; head -c 20000 /dev/zero > /cache/small'
# Wait until the healthcheck has passed
for _ in $(seq 1 30); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' web-app-frontend-1)" == healthy ]] && break
    sleep 1
done

rm -rf tests/fixtures && mkdir -p tests/fixtures
cd demo/stacks
for args in "" "-v" "-n"; do
    # shellcheck disable=SC2086
    DSM_FAKE_DOCKER=record DSM_REAL_DOCKER="$real_docker" PATH="$ROOT/tests/bin:$PATH" \
        "$ROOT/docker-stacks-manager.sh" $args > /dev/null
done
cd "$ROOT"
./demo/demo.sh down >/dev/null 2>&1
echo "Recorded $(ls tests/fixtures/*.out | wc -l | tr -d ' ') docker calls into tests/fixtures"
