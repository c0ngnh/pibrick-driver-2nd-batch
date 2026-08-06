#!/bin/sh
# Fix black screen when opening Recent / task switcher on Plasma Mobile (Wayland)
# on Raspberry Pi 4/5/500+ with the V3D GPU driver.
#
# Root cause: KWin effects (mobiletaskswitcher, overview, tiling) fail when using
# desktop OpenGL on Pi; KWin must use OpenGL ES 2.0 (KWIN_COMPOSE=O2ES).
# See KDE bug 519099: https://bugs.kde.org/show_bug.cgi?id=519099
#
# Important: KWin is started by systemd (plasma-kwin_wayland.service), so variables
# in /etc/environment or ~/.profile are NOT enough. This script installs a
# systemd user drop-in that applies the fix every session.
#
# Usage:
#   ./fix-plasma-mobile-recent-black-screen.sh
#   ./fix-plasma-mobile-recent-black-screen.sh --enable-zink-fallback
#
# After running, log out and back in (or reboot).

set -e

ENABLE_ZINK=0
if [ "$1" = "--enable-zink-fallback" ]; then
    ENABLE_ZINK=1
fi

OVERRIDE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/plasma-kwin_wayland.service.d"
FIX_CONF="$OVERRIDE_DIR/pi-kwin-recent-fix.conf"
ZINK_CONF="$OVERRIDE_DIR/pi-kwin-zink-fallback.conf"
ZINK_DISABLED="$OVERRIDE_DIR/pi-kwin-zink-fallback.conf.disabled"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this script as the desktop user (not root)." >&2
    echo "Example: su - \$USER -c './fix-plasma-mobile-recent-black-screen.sh'" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; this fix requires systemd user sessions." >&2
    exit 1
fi

if [ ! -f /usr/lib/systemd/user/plasma-kwin_wayland.service ] \
    && [ ! -f /lib/systemd/user/plasma-kwin_wayland.service ]; then
    echo "plasma-kwin_wayland.service not found." >&2
    echo "Is KDE Plasma (kwin-wayland) installed?" >&2
    exit 1
fi

mkdir -p "$OVERRIDE_DIR"

cat > "$FIX_CONF" <<'EOF'
[Service]
# Fix black screen in mobile task switcher / overview on Raspberry Pi (KDE bug 519099)
Environment=KWIN_DRM_USE_MODIFIERS=0
Environment=KWIN_COMPOSE=O2ES
Environment=KWIN_PERSISTENT_VBO=1
Environment=KWIN_RENDER_BACKEND=gles
Environment=KWIN_OPENGL_INTERFACE=egl
EOF

cat > "$ZINK_DISABLED" <<'EOF'
# Optional fallback if OpenGL ES alone is not enough (higher CPU usage).
# Enable with: ./fix-plasma-mobile-recent-black-screen.sh --enable-zink-fallback
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=zink
EOF

if [ "$ENABLE_ZINK" = "1" ]; then
    cat > "$ZINK_CONF" <<'EOF'
[Service]
# Fallback when OpenGL ES alone is not enough (higher CPU usage).
Environment=MESA_LOADER_DRIVER_OVERRIDE=zink
EOF
    rm -f "$ZINK_DISABLED"
    echo "Enabled zink fallback (software Vulkan via Mesa)."
else
    rm -f "$ZINK_CONF"
    cat > "$ZINK_DISABLED" <<'EOF'
# Optional fallback if OpenGL ES alone is not enough (higher CPU usage).
# Enable with: ./fix-plasma-mobile-recent-black-screen.sh --enable-zink-fallback
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=zink
EOF
    echo "Zink fallback left disabled (use --enable-zink-fallback if needed)."
fi

systemctl --user daemon-reload

echo ""
echo "Installed: $FIX_CONF"
echo ""
echo "What this does:"
echo "  - Forces KWin to use OpenGL ES 2.0 instead of desktop OpenGL 3.x"
echo "  - Fixes black Recent / task switcher / overview on Pi Wayland sessions"
echo ""
echo "Next step: log out of Plasma Mobile and log back in, or reboot."
echo ""
echo "Verify after login (optional):"
echo "  qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation | grep -i 'Compositing Type'"
echo "  Expected: Compositing Type: OpenGL ES 2.0"
