#!/bin/bash
#
# autorotation-lock — lock/unlock screen auto-rotation for piBrick
#
# Integrates with the native KDE Plasma Mobile quick settings by toggling
# the "autoRotation" field in ~/.config/kwinoutputconfig.json.
#
# For Phosh, this uses wlr-randr or phoc D-Bus interface directly.
#
# For manual rotation locks (normal/left/right/inverted), also writes to
# /var/lib/pibrick/autorotation.lock so pibrick-autorotation.sh can
# apply the physical transform.
#
# Usage:
#   autorotation-lock normal        Lock to portrait
#   autorotation-lock left         Lock to landscape (CCW)
#   autorotation-lock right        Lock to landscape (CW)
#   autorotation-lock inverted     Lock to portrait (inverted)
#   autorotation-lock auto         Enable auto-rotation (native quick setting)
#
set -euo pipefail

# Source shared desktop detection library
LIB_FILE="/usr/lib/pibrick/lib-desktop-detection.sh"
if [ -f "$LIB_FILE" ]; then
    # shellcheck source=/dev/null
    source "$LIB_FILE"
else
    # Inline fallback if library not installed yet (development)
    is_kde() {
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"kde"* ]] || \
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] || \
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] || \
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"Plasma"* ]] || \
        command -v kscreen-doctor >/dev/null 2>&1
    }
    is_phosh() {
        [ -n "${PHOSH:-}" ] && return 0
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"phosh"* ]] && return 0
        command -v phoc >/dev/null 2>&1 && return 0
        [ -d "/usr/share/phosh" ] && return 0
        [ -f "/usr/share/xsessions/phosh.desktop" ] && return 0
        return 1
    }
    get_active_user() {
        local session
        session=$(loginctl list-sessions --no-legend 2>/dev/null | \
            awk '$3 != "" && $3 != "root" && $6 != "manager" {print $1; exit}')
        if [ -n "$session" ]; then
            loginctl show-session "$session" -p User --value 2>/dev/null && return 0
        fi
        who 2>/dev/null | awk '$1 != "root" {print $1; exit}'
    }
    get_phoc_primary_output() {
        local user="${1:-$(get_active_user)}"
        local uid="${2:-$(id -u "$user" 2>/dev/null || echo "1000")}"
        if command -v busctl >/dev/null 2>&1; then
            busctl --user --machine="$user" get-property \
                sm.puri.phoc \
                /sm/puri/phoc \
                sm.puri.phoc.Manager \
                PrimaryOutput 2>/dev/null | sed 's/^s "//;s/"$//' || echo ""
        fi
    }
fi

STATE_DIR="/var/lib/pibrick"
LOCK_FILE="$STATE_DIR/autorotation.lock"
LOCK_TYPE_FILE="$STATE_DIR/autorotation.lock.type"
KWIN_CONFIG="$HOME/.config/kwinoutputconfig.json"
VALID_ORIS="normal left right inverted"

# ── KDE Plasma Helpers ────────────────────────────────────────────────────────

# Read current autoRotation value from kwinoutputconfig.json
get_auto_rotation_state() {
    python3 -c "
import json, sys
try:
    with open('$KWIN_CONFIG') as f:
        d = json.load(f)
    for o in d[0]['data']:
        print(o.get('autoRotation', 'Unknown'))
        sys.exit(0)
except Exception as e:
    print('Error:', e, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || echo "Unknown"
}

# Write autoRotation to kwinoutputconfig.json and tell KWin to reload
set_auto_rotation_kde() {
    local value="$1"
    python3 << EOF
import json, subprocess, sys

config_path = "$KWIN_CONFIG"
try:
    with open(config_path) as f:
        d = json.load(f)
    changed = False
    for o in d[0]["data"]:
        if o.get("autoRotation") != "$value":
            o["autoRotation"] = "$value"
            changed = True
    if changed:
        with open(config_path, "w") as f:
            json.dump(d, f)
        # Tell KWin to reload its output config
        subprocess.run(["qdbus6", "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"],
                       capture_output=True)
        print("autoRotation set to $value")
    else:
        print("autoRotation already $value")
except Exception as e:
    print("Error:", e, file=sys.stderr)
    sys.exit(1)
EOF
}

# ── Phosh Helpers ─────────────────────────────────────────────────────────────

# Get the primary output from phoc
get_phoc_primary_output() {
    local user=$1
    local uid=$2

    if command -v busctl >/dev/null 2>&1; then
        busctl --user get-property \
            sm.puri.phoc \
            /sm/puri/phoc \
            sm.puri.phoc.Manager \
            PrimaryOutput 2>/dev/null | sed 's/^s "//;s/"$//' || echo ""
    fi
}

# Apply rotation on Phosh using wlr-randr
apply_phosh_rotation() {
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

    # Try wlr-randr first (preferred method)
    if command -v wlr-randr >/dev/null 2>&1; then
        # Get primary output from phoc
        local output
        output=$(get_phoc_primary_output "$user" "$uid")

        if [ -n "$output" ]; then
            sudo -u "$user" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                XDG_RUNTIME_DIR="$xdg_runtime" \
                wlr-randr --output "$output" --transform "$transform" 2>/dev/null || true
        else
            # Fallback: apply to all outputs
            # Use process substitution instead of pipeline to avoid subshell variable loss
            while read -r line; do
                sudo -u "$user" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                    XDG_RUNTIME_DIR="$xdg_runtime" \
                    wlr-randr --output "$line" --transform "$transform" 2>/dev/null || true
            done < <(wlr-randr 2>/dev/null | grep -E '^[^ ]+')
        fi
        return 0
    fi

    # Try phoc D-Bus interface
    if command -v busctl >/dev/null 2>&1; then
        local phoc_rot
        case "$orientation" in
            normal)   phoc_rot=0 ;;
            left)    phoc_rot=90 ;;
            right)   phoc_rot=270 ;;
            inverted) phoc_rot=180 ;;
        esac

        # Get primary output and rotate it
        local output
        output=$(get_phoc_primary_output "$user" "$uid")

        if [ -n "$output" ]; then
            busctl --user call \
                sm.puri.phoc \
                /sm/puri/phoc \
                sm.puri.phoc.Manager \
                RotateOutput "sui" "$output" 1 "$phoc_rot" 2>/dev/null || true
        fi
        return 0
    fi

    return 1
}

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "autorotation-lock: $*"; }

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    normal|left|right|inverted)
        if is_phosh; then
            # Phosh: Apply rotation directly using wlr-randr or phoc D-Bus
            user=$(get_active_user)
            uid=$(id -u "$user" 2>/dev/null || echo "1000")

            if ! apply_phosh_rotation "$1" "$user" "$uid"; then
                log "Warning: Could not apply rotation on Phosh (wlr-randr or phoc D-Bus required)"
            fi
        else
            # KDE Plasma: Disable KWin auto-rotation (native quick setting → "Disabled")
            set_auto_rotation_kde "Disabled"
        fi

        # Record the desired orientation for the physical transform
        mkdir -p "$STATE_DIR"
        echo "$1" > "$LOCK_FILE"
        echo "manual" > "$LOCK_TYPE_FILE"

        # Apply the physical transform immediately
        /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh \
            --apply-rotation "$1" 2>/dev/null || true

        log "Locked to: $1"
        ;;

    lock-current)
        # Detect the orientation the screen is currently in and lock to it.
        # Used by the Plasma Mobile Quick Drawer entry so a single tap leaves
        # the screen exactly where the user is looking at it.
        current_ori=$(/usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh \
            --current-orientation 2>/dev/null || echo "normal")
        # Recurse with the detected orientation.
        "$0" "$current_ori"
        ;;

    auto|"")
        if is_phosh; then
            # Phosh: No native auto-rotation control needed, just remove lock
            rm -f "$LOCK_FILE" "$LOCK_TYPE_FILE"
            log "Auto-rotation enabled"
        else
            # KDE Plasma: Re-enable KWin auto-rotation (native quick setting → "InTabletMode")
            set_auto_rotation_kde "InTabletMode"

            # Remove manual lock so pibrick-autorotation.sh resumes auto-rotation
            rm -f "$LOCK_FILE" "$LOCK_TYPE_FILE"

            log "Auto-rotation enabled"
        fi
        ;;

    --status)
        if is_phosh; then
            if [ -f "$LOCK_FILE" ]; then
                echo "Locked: $(cat "$LOCK_FILE")"
            else
                echo "Auto-rotation: enabled"
            fi
        else
            state=$(get_auto_rotation_state)
            if [ "$state" = "Disabled" ]; then
                locked=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
                if [ -n "$locked" ]; then
                    echo "Locked: $locked"
                else
                    echo "Locked (orientation unknown)"
                fi
            else
                echo "Auto-rotation: $state"
            fi
        fi
        ;;

    --help|-h)
        echo "Usage: autorotation-lock [normal|left|right|inverted|lock-current|auto|--status]"
        ;;
    *)
        echo "autorotation-lock: unknown argument: $1" >&2
        echo "Valid: normal left right inverted lock-current auto --status" >&2
        exit 1
        ;;
esac
