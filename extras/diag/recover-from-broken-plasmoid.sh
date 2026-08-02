#!/bin/bash
# recover-from-broken-plasmoid.sh — restore top bar after pibrick-rotation-lock
# plasmoid breaks plasmashell.
#
# Run this on the Pi as the desktop user (the user that Plasma Mobile runs under).
# This script:
#   1. Records which Plasma Mobile panel config file is in use
#   2. Removes the pibrick-rotation-lock entry from that config
#   3. Stops the pibrick-rotation-ui.service (failsafe: keep it disabled for now)
#   4. Restarts plasmashell so the top bar reappears
#   5. Leaves the autorotation system service running (it manages rotation
#      via the accelerometer, the panel plasmoid is just a UI lock toggle)
#
# After recovery, you can use pibrick-autorotation-ctl.sh from a terminal:
#   pibrick-autorotation-ctl lock normal
#   pibrick-autorotation-ctl unlock
#
# The plumbing in /usr/lib/pibrick/autorotation-service/ is unaffected.
# We only disable the QML UI.

set -euo pipefail

DESK_USER="${SUDO_USER:-}"
[ -z "$DESK_USER" ] && DESK_USER="$(loginctl show-session \
    "$(loginctl | awk '/c[0-9]+/ {print $1; exit}')" -p User --value 2>/dev/null || true)"
[ -z "$DESK_USER" ] && DESK_USER="$(who | awk '{print $1}' | head -1)"
if [ -z "$DESK_USER" ] || [ "$DESK_USER" = "root" ]; then
    echo "ERROR: cannot determine desktop user. Run this as the user, not root."
    exit 1
fi

USER_HOME="$(getent passwd "$DESK_USER" | cut -d: -f6)"
PANEL_RC="$USER_HOME/.config/plasma-org.kde.plasma.mobileshell-appletsrc"
PLASMOID_DIR="$USER_HOME/.local/share/plasma/plasmoids/pibrick-rotation-lock"
PLASMOID_DIR_OLD="$USER_HOME/.local/share/kservices5/pibrick-rotation-lock"

echo "Desktop user: $DESK_USER"
echo "Home:         $USER_HOME"
echo "Panel config: $PANEL_RC"

# ── 1. Show before-state ──────────────────────────────────────────────────────
echo
echo "── BEFORE ──"
[ -f "$PANEL_RC" ] && grep -n "pibrick-rotation-lock" "$PANEL_RC" || echo "  (no panel config found)"

# ── 2. Remove the applet entry from the panel config ──────────────────────────
# The config contains sections like:
#   [Containments][3][Applets][101]
#   plugin=pibrick-rotation-lock
# We need to remove the entire [Containments][3][Applets][NN] block whose
# key is plugin=pibrick-rotation-lock.
if [ -f "$PANEL_RC" ]; then
    # Use python for safe ini manipulation
    sudo -u "$DESK_USER" python3 - <<PYEOF
import configparser, os, sys
p = "$PANEL_RC"
c = configparser.ConfigParser(strict=False, allow_no_value=True)
c.optionxform = str
c.read(p)

removed = []
for sec in list(c.sections()):
    if sec.startswith("[Containments][") and "[Applets][" in sec:
        # Check if this section has plugin=pibrick-rotation-lock
        if c.has_option(sec, "plugin") and c[sec]["plugin"] == "pibrick-rotation-lock":
            removed.append(sec)
            c.remove_section(sec)

with open(p, "w") as f:
    c.write(f, space_around_delimiters=False)

# Also strip any orphans: a section header followed by plugin=... with no
# other keys. configparser may leave them behind.
import re
with open(p, "r") as f:
    txt = f.read()

# Strip empty [..][Applets][NN] sections
txt = re.sub(r"^\[Containments\]\[\d+\]\[Applets\]\[\d+\]\s*\n(?:plugin=[^\n]*\n)?", "", txt, flags=re.MULTILINE)

with open(p, "w") as f:
    f.write(txt)

print(f"Removed {len(removed)} applet sections: {removed}")
PYEOF
fi

# ── 3. Stop the user-level pibrick-rotation-ui.service ────────────────────────
sudo -u "$DESK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$DESK_USER")" \
    systemctl --user stop pibrick-rotation-ui.service 2>/dev/null || true
sudo -u "$DESK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$DESK_USER")" \
    systemctl --user disable pibrick-rotation-ui.service 2>/dev/null || true
echo "  pibrick-rotation-ui.service stopped and disabled"

# ── 4. Stash the broken plasmoid (don't delete — keep for inspection) ─────────
if [ -d "$PLASMOID_DIR" ]; then
    mv "$PLASMOID_DIR" "${PLASMOID_DIR}.broken.$(date +%Y%m%d-%H%M%S)"
    echo "  Stashed broken plasmoid: ${PLASMOID_DIR}.broken.*"
fi
if [ -d "$PLASMOID_DIR_OLD" ]; then
    mv "$PLASMOID_DIR_OLD" "${PLASMOID_DIR_OLD}.broken.$(date +%Y%m%d-%H%M%S)"
fi

# ── 5. Restart plasmashell so the top bar returns ─────────────────────────────
echo "  Restarting plasmashell..."
sudo -u "$DESK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$DESK_USER")" \
    systemctl --user restart plasmashell.service 2>/dev/null || \
    sudo -u "$DESK_USER" pkill -f plasmashell 2>/dev/null || true

# ── 6. Show after-state ────────────────────────────────────────────────────────
echo
echo "── AFTER ──"
[ -f "$PANEL_RC" ] && grep -n "pibrick-rotation-lock" "$PANEL_RC" || echo "  (no pibrick-rotation-lock entries — good)"

echo
echo "Plasmashell restart issued. Wait ~5 seconds, then verify the top bar is back."
echo
echo "Optional sanity check:"
echo "  systemctl --user status plasmashell | head -10"
echo "  ls \$HOME/.local/share/plasma/plasmoids/"
echo
echo "The autorotation system service is still running (rotation still works)."
echo "Use the ctl script for lock toggle instead of the panel widget:"
echo "  pibrick-autorotation-ctl lock normal"
echo "  pibrick-autorotation-ctl unlock"
echo "  pibrick-autorotation-ctl status"
