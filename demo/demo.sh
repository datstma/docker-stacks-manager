#!/usr/bin/env bash
#
# Spin up a few throwaway stacks so you can try docker-stacks-manager
# (or record screenshots) without touching your real setup.
#
#   ./demo/demo.sh up     # start the demo stacks
#   ./demo/demo.sh run    # status overview of the demo stacks
#   ./demo/demo.sh run -I # ...or any other options, e.g. the TUI
#   ./demo/demo.sh down   # remove everything again
#
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="$DEMO_DIR/stacks"
MANAGER="$DEMO_DIR/../docker-stacks-manager.sh"

case "${1:-}" in
    up)
        (cd "$STACKS_DIR/web-app" && docker compose up -d)
        (cd "$STACKS_DIR/monitoring" && docker compose up -d && docker compose stop -t 1 alerts)
        # Create but don't start, so it shows as stopped
        (cd "$STACKS_DIR/backup" && docker compose create)
        ;;
    run)
        shift
        cd "$STACKS_DIR" && exec "$MANAGER" "$@"
        ;;
    down)
        for stack in web-app monitoring backup; do
            (cd "$STACKS_DIR/$stack" && docker compose down --volumes)
        done
        ;;
    *)
        echo "Usage: $0 {up|run [options]|down}" >&2
        exit 1
        ;;
esac
