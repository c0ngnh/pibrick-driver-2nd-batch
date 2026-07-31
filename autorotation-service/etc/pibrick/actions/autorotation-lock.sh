#!/bin/bash
#
# autorotation-lock — lock/unlock screen auto-rotation for piBrick
#
# Integrates with the native KDE Plasma Mobile quick settings by toggling
# the "autoRotation" field in ~/.config/kwinoutputconfig.json.
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

STATE_DIR="/var/lib/pibrick"
LOCK_FILE="$STATE_DIR/autorotation.lock"
LOCK_TYPE_FILE="$STATE_DIR/autorotation.lock.type"
KWIN_CONFIG="$HOME/.config/kwinoutputconfig.json"
VALID_ORIS="normal left right inverted"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "autorotation-lock: $*"; }

# Read current autoRotation value from kwinoutputconfig.json
get_auto_rotation_state() {
    python3 -c "
import json, sys
try:
    d = json.load(open('$KWIN_CONFIG'))
    for o in d[0]['data']:
        print(o.get('autoRotation', 'Unknown'))
        sys.exit(0)
except Exception as e:
    print('Error:', e, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || echo "Unknown"
}

# Write autoRotation to kwinoutputconfig.json and tell KWin to reload
set_auto_rotation() {
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

# ── Main ───────────────────────────────────────────────────────────────────────

case "${1:-}" in
    normal|left|right|inverted)
        # 1. Disable KWin auto-rotation (native quick setting → "Disabled")
        set_auto_rotation "Disabled"

        # 2. Record the desired orientation for the physical transform
        mkdir -p "$STATE_DIR"
        echo "$1" > "$LOCK_FILE"
        echo "manual" > "$LOCK_TYPE_FILE"

        # 3. Apply the physical transform immediately
        #    pibrick-autorotation.sh also does this on orientation change,
        #    but calling it here ensures instant response.
        /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh \
            --apply-rotation "$1" 2>/dev/null || true

        log "Locked to: $1"
        ;;

    auto|"")
        # 1. Re-enable KWin auto-rotation (native quick setting → "InTabletMode")
        set_auto_rotation "InTabletMode"

        # 2. Remove manual lock so pibrick-autorotation.sh resumes auto-rotation
        rm -f "$LOCK_FILE" "$LOCK_TYPE_FILE"

        log "Auto-rotation enabled"
        ;;

    --status)
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
        ;;

    --help|-h)
        echo "Usage: autorotation-lock [normal|left|right|inverted|auto|--status]"
        ;;
    *)
        echo "autorotation-lock: unknown argument: $1" >&2
        echo "Valid: normal left right inverted auto --status" >&2
        exit 1
        ;;
esac
