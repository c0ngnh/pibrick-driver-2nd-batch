#!/bin/bash
#
# Autorotation lock toggle - disables/enables auto-rotation
#
# Usage:
#   autorotation-lock           Lock current orientation
#   autorotation-lock normal    Lock to normal orientation
#   autorotation-lock left      Lock to left (landscape)
#   autorotation-lock right     Lock to right (landscape)
#   autorotation-lock inverted  Lock to inverted
#   autorotation-lock auto      Unlock (enable auto-rotation)
#
set -euo pipefail

ORIENTATION_LOCK_DIR="/var/lib/pibrick"
ORIENTATION_LOCK_FILE="$ORIENTATION_LOCK_DIR/autorotation.lock"
LOCK_TYPE_FILE="$ORIENTATION_LOCK_DIR/autorotation.lock.type"

log() {
    echo "autorotation-lock: $*"
}

case "${1:-}" in
    normal|left|right|inverted)
        mkdir -p "$ORIENTATION_LOCK_DIR"
        echo "$1" > "$ORIENTATION_LOCK_FILE"
        echo "manual" > "$LOCK_TYPE_FILE"
        log "Locked orientation to: $1"
        log "To unlock: autorotation-lock auto"
        ;;
    auto|unlock|"")
        if [ -f "$ORIENTATION_LOCK_FILE" ]; then
            rm -f "$ORIENTATION_LOCK_FILE"
            rm -f "$LOCK_TYPE_FILE"
            log "Auto-rotation enabled"
        else
            log "Auto-rotation already enabled"
        fi
        ;;
    --help|-h)
        echo "Usage: autorotation-lock [normal|left|right|inverted|auto]"
        echo ""
        echo "Lock screen rotation to a specific orientation,"
        echo "or 'auto' to enable automatic rotation."
        ;;
    *)
        echo "Unknown orientation: $1" >&2
        echo "Valid options: normal, left, right, inverted, auto" >&2
        exit 1
        ;;
esac
