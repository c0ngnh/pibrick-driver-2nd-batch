#!/bin/bash
#
# phosh-rotation-helper - Quick settings helper for Phosh rotation lock
#
# This script provides a simple way to toggle rotation lock on Phosh
# using gsettings (same as GNOME). It reads/writes the orientation lock
# state from /var/lib/pibrick/autorotation.lock.
#
# Usage:
#   phosh-rotation-helper get        - Get current lock state
#   phosh-rotation-helper lock       - Lock to current orientation
#   phosh-rotation-helper unlock    - Enable auto-rotation
#
# This script is meant to be called by phosh's shell integration or
# from a simple toggle button in Phosh's top bar.
#
set -euo pipefail

STATE_DIR="/var/lib/pibrick"
LOCK_FILE="$STATE_DIR/autorotation.lock"
LOCK_TYPE_FILE="$STATE_DIR/autorotation.lock.type"

log() { echo "phosh-rotation-helper: $*"; }

# Get current screen orientation using accelerometer or kwin info
get_current_orientation() {
    # Try to read from the autorotation service
    if [ -f /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh ]; then
        /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh \
            --current-orientation 2>/dev/null || echo "normal"
    else
        echo "normal"
    fi
}

# Lock rotation to a specific orientation
lock_rotation() {
    local orientation=${1:-$(get_current_orientation)}
    mkdir -p "$STATE_DIR"
    echo "$orientation" > "$LOCK_FILE"
    echo "manual" > "$LOCK_TYPE_FILE"
    log "Locked to: $orientation"
}

# Unlock rotation (enable auto-rotation)
unlock_rotation() {
    rm -f "$LOCK_FILE" "$LOCK_TYPE_FILE"
    log "Auto-rotation enabled"
}

# Get lock status
get_status() {
    if [ -f "$LOCK_FILE" ]; then
        local locked=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$locked" ]; then
            echo "locked:$locked"
        else
            echo "locked:unknown"
        fi
    else
        echo "unlocked"
    fi
}

# Apply rotation using wlr-randr or phoc D-Bus
apply_rotation() {
    local orientation=$1
    local user=$2
    local uid=$3
    local xdg_runtime="/run/user/$uid"

    # Get transform value
    local transform
    case "$orientation" in
        normal)   transform="normal" ;;
        left)    transform="90" ;;
        right)   transform="270" ;;
        inverted) transform="180" ;;
        *)       return 1 ;;
    esac

    # Try wlr-randr first
    if command -v wlr-randr >/dev/null 2>&1; then
        # Get primary output from phoc
        local output=""
        if command -v busctl >/dev/null 2>&1; then
            output=$(busctl --user get-property \
                sm.puri.phoc \
                /sm/puri/phoc \
                sm.puri.phoc.Manager \
                PrimaryOutput 2>/dev/null | sed 's/^s "//;s/"$//' || echo "")
        fi

        if [ -n "$output" ]; then
            sudo -u "$user" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                XDG_RUNTIME_DIR="$xdg_runtime" \
                wlr-randr --output "$output" --transform "$transform" 2>/dev/null || true
        else
            # Fallback: apply to all outputs
            sudo -u "$user" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                XDG_RUNTIME_DIR="$xdg_runtime" \
                wlr-randr 2>/dev/null | grep -E '^[^ ]+' | while read -r line; do
                    sudo -u "$user" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                        XDG_RUNTIME_DIR="$xdg_runtime" \
                        wlr-randr --output "$line" --transform "$transform" 2>/dev/null || true
                done
        fi
        return 0
    fi

    return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────

get_active_user() {
    local session
    session=$(loginctl list-sessions --no-legend 2>/dev/null | \
        awk '$3 != "" && $3 != "root" && $6 != "manager" {print $1; exit}')
    if [ -n "$session" ]; then
        loginctl show-session "$session" -p User --value 2>/dev/null && return 0
    fi
    who 2>/dev/null | awk '$1 != "root" {print $1; exit}'
}

case "${1:-}" in
    get|status)
        get_status
        ;;
    lock)
        local user uid
        user=$(get_active_user || echo "root")
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        local orientation
        orientation=$(get_current_orientation)
        lock_rotation "$orientation"

        # Apply rotation immediately
        apply_rotation "$orientation" "$user" "$uid"
        ;;
    unlock)
        unlock_rotation
        ;;
    lock-current)
        # Lock to current orientation
        local user uid
        user=$(get_active_user || echo "root")
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        local orientation
        orientation=$(get_current_orientation)
        lock_rotation "$orientation"

        # Apply rotation immediately
        apply_rotation "$orientation" "$user" "$uid"
        ;;
    --help|-h)
        echo "Usage: phosh-rotation-helper [get|lock|unlock|lock-current|--help]"
        ;;
    *)
        echo "phosh-rotation-helper: unknown argument: $1" >&2
        echo "Valid: get lock unlock lock-current --help" >&2
        exit 1
        ;;
esac
