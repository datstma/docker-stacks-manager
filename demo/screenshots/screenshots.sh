#!/usr/bin/env bash
#
# Re-create docs/images/ (README screenshots and the animated demo).
#
# Everything runs in containers against a throwaway Docker-in-Docker daemon,
# so nothing from your own Docker host shows up in the images:
#   - dsm-dind  the isolated Docker daemon running the demo stacks
#   - VHS       (github.com/charmbracelet/vhs) types into a real terminal
#               and records it, following screenshots.tape
#
# Needs Docker on the host (with --privileged allowed for the dind container).
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT="$PWD"
OUT="$ROOT/docs/images"
NET=dsm-shots
DIND=dsm-dind
STACKS=/home/you/docker-stacks   # the path shown in the screenshots

cleanup() {
    docker rm -f "$DIND" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

mounts=(
    -v "$ROOT/demo/stacks/web-app:$STACKS/web-app:ro"
    -v "$ROOT/demo/stacks/monitoring:$STACKS/monitoring:ro"
    -v "$ROOT/demo/stacks/backup:$STACKS/backup:ro"
    -v "$ROOT/demo/screenshots/watchtower:$STACKS/watchtower:ro"
)

echo "Starting an isolated Docker daemon..."
docker network create "$NET" >/dev/null
# containerd is started first and given all the time it needs: on some hosts
# (ZFS, no kernel modules) it boots slower than dockerd's 10s timeout
docker run -d --privileged --name "$DIND" --hostname homelab --network "$NET" \
    -e DOCKER_TLS_CERTDIR= --entrypoint sh docker:27-dind -c '
        containerd > /var/log/containerd.log 2>&1 &
        while [ ! -S /run/containerd/containerd.sock ]; do sleep 1; done
        exec dockerd-entrypoint.sh dockerd --containerd=/run/containerd/containerd.sock \
            --host=unix:///var/run/docker.sock --host=tcp://0.0.0.0:2375 --tls=false' >/dev/null

# Run docker inside the isolated daemon, with the stacks at $STACKS
in_dind() {
    docker run --rm --network "$NET" -e DOCKER_HOST="tcp://$DIND:2375" \
        "${mounts[@]}" docker:27-cli sh -c "$1"
}
ready=false
for _ in $(seq 1 60); do
    in_dind 'docker info' >/dev/null 2>&1 && { ready=true; break; }
    sleep 2
done
$ready || { echo "The isolated Docker daemon did not start:" >&2; docker logs --tail 20 "$DIND" >&2; exit 1; }

echo "Starting the demo stacks..."
in_dind "
    set -e
    cd $STACKS/watchtower && docker compose up -d --quiet-pull
    cd $STACKS/web-app && docker compose up -d --quiet-pull
    cd $STACKS/monitoring && docker compose up -d --quiet-pull && docker compose stop -t 1 alerts
    cd $STACKS/backup && docker compose create --quiet-pull
    docker exec web-app-worker-1 sh -c 'head -c 3000000 /dev/zero > /uploads/big; head -c 20000 /dev/zero > /cache/small'
    for i in \$(seq 1 30); do
        [ \"\$(docker inspect -f '{{.State.Health.Status}}' web-app-frontend-1)\" = healthy ] && break
        sleep 1
    done
    sleep 75   # let the uptimes tick past zero
" >/dev/null

echo "Recording with VHS..."
mkdir -p "$OUT"
# The VHS image has no docker CLI: borrow the (static) one from docker:cli
tools="$(mktemp -d)"
trap 'cleanup; rm -rf "$tools"' EXIT
cid=$(docker create docker:27-cli)
docker cp -q "$cid:/usr/local/bin/docker" "$tools/docker"
docker cp -q "$cid:/usr/local/libexec/docker/cli-plugins/docker-compose" "$tools/docker-compose"
docker rm "$cid" >/dev/null
docker run --rm --network "$NET" -e DOCKER_HOST="tcp://$DIND:2375" \
    "${mounts[@]}" \
    -v "$ROOT/docker-stacks-manager.sh:/usr/local/bin/dsm:ro" \
    -v "$tools/docker:/usr/local/bin/docker:ro" \
    -v "$tools/docker-compose:/usr/local/libexec/docker/cli-plugins/docker-compose:ro" \
    -v "$ROOT/demo/screenshots/screenshots.tape:/vhs/screenshots.tape:ro" \
    -v "$OUT:/vhs/out" \
    ghcr.io/charmbracelet/vhs:latest screenshots.tape

# VHS runs as root: hand the files back
docker run --rm -v "$OUT:/out" --entrypoint chown ghcr.io/charmbracelet/vhs:latest -R "$(id -u):$(id -g)" /out
ls -l "$OUT"
