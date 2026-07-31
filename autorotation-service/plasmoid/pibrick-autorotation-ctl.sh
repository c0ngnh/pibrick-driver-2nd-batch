#!/bin/bash
# pibrick-autorotation-ctl — control piBrick auto-rotation lock state
# Used by the KDE Plasma Mobile plasmoid to avoid D-Bus from QML.
#
# Usage:
#   pibrick-autorotation-ctl lock   <normal|left|right|inverted>
#   pibrick-autorotation-ctl unlock
#   pibrick-autorotation-ctl status
#   pibrick-autorotation-ctl enabled <0|1>
#
# Exit codes: 0 = success, 1 = error, 2 = D-Bus service unavailable

set -euo pipefail

# Use /var/lib/pibrick for system-wide state (matches pibrick-autorotation.service)
STATE_DIR="/var/lib/pibrick"
LOCK_FILE="${STATE_DIR}/autorotation.lock"
LOCK_TYPE_FILE="${STATE_DIR}/autorotation.lock.type"
ENABLED_FILE="${STATE_DIR}/autorotation.enabled"

# Also update kwinoutputconfig.json for native KDE Plasma quick settings integration
KWIN_CONFIG="$HOME/.config/kwinoutputconfig.json"

VALID_ORIS="normal left right inverted"

log()  { echo "[pibrick-autorotation-ctl] $*" >&2; }
die()  { echo "[pibrick-autorotation-ctl] ERROR: $*" >&2; exit 1; }

# ── File-based lock (also updates kwinoutputconfig.json) ────────────────────────
file_lock() {
    local ori=$1
    mkdir -p "$STATE_DIR"
    echo "$ori" > "$LOCK_FILE"
    echo "manual" > "$LOCK_TYPE_FILE"
    log "Locked to: $ori (file)"
}

file_unlock() {
    rm -f "$LOCK_FILE" "$LOCK_TYPE_FILE"
    log "Unlocked (file)"
}

file_status() {
    if [ -s "$LOCK_FILE" ]; then
        local ori=$(cat "$LOCK_FILE")
        echo "locked:$ori"
    else
        echo "unlocked"
    fi
}

file_enabled() {
    local val=${1:-}
    if [ -n "$val" ]; then
        if [ "$val" = "1" ] || [ "$val" = "true" ]; then
            mkdir -p "$STATE_DIR"
            touch "$ENABLED_FILE"
        else
            rm -f "$ENABLED_FILE"
        fi
    fi
    [ -f "$ENABLED_FILE" ] && echo "enabled" || echo "disabled"
}

# ── D-Bus ─────────────────────────────────────────────────────────────────────
dbus_call() {
    local method=$1; shift
    qdbus \
        --literal \
        com.pibrick.Autorotation \
        /com/pibrick/Autorotation \
        com.pibrick.Autorotation."$method" \
        "$@" 2>/dev/null || return 1
}

dbus_lock() {
    local ori=$1
    # Try D-Bus first
    if dbus_call LockOrientation "$ori"; then
        log "Locked via D-Bus: $ori"
        return 0
    fi
    # D-Bus unavailable — use autorotation-lock which handles kwin config
    /usr/bin/autorotation-lock "$ori" && log "Locked via autorotation-lock: $ori" && return 0
    # Final fallback: direct file
    file_lock "$ori"
}

dbus_unlock() {
    # Try D-Bus first
    if dbus_call UnlockOrientation; then
        log "Unlocked via D-Bus"
        return 0
    fi
    # D-Bus unavailable — use autorotation-lock which handles kwin config
    /usr/bin/autorotation-lock auto && log "Unlocked via autorotation-lock" && return 0
    file_unlock
}

dbus_status() {
    local result
    result=$(dbus_call GetStatus 2>/dev/null) && {
        echo "$result"
        return 0
    }
    file_status
}

dbus_enabled() {
    local val=${1:-}
    if [ -n "$val" ]; then
        dbus_call SetEnabled "$val" >/dev/null 2>&1 || file_enabled "$val"
    else
        dbus_call IsEnabled 2>/dev/null || file_enabled
    fi
}

# ── CLI ──────────────────────────────────────────────────────────────────────
cmd=${1:-}
case "$cmd" in
    lock)
        ori=${2:-}
        if ! [[ " $VALID_ORIS " =~ " $ori " ]]; then
            die "Usage: $0 lock <normal|left|right|inverted>"
        fi
        dbus_lock "$ori" || file_lock "$ori"
        ;;

    unlock)
        dbus_unlock || file_unlock
        ;;

    status)
        dbus_status || file_status
        ;;

    enabled)
        dbus_enabled "${2:-}" || file_enabled "${2:-}"
        ;;

    *)
        echo "Usage: $0 {lock|unlock|status|enabled} [args...]"
        echo "  lock <normal|left|right|inverted>   Lock auto-rotation"
        echo "  unlock                                Enable auto-rotation"
        echo "  status                                Show lock state"
        echo "  enabled [0|1]                        Enable/disable service"
        exit 0
        ;;
esac
