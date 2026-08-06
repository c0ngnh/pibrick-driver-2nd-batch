#!/bin/bash
# fix-sddm-pi5-kde-mobile.sh
#
# Fix SDDM not booting to GUI on Raspberry Pi 5 + KDE Plasma Mobile (Debian/Raspbian).
#
# Symptoms after fresh install:
#   - Black screen at boot, no login greeter
#   - journalctl -u sddm: "Failed to read display number from pipe"
#   - /var/log/Xorg.0.log: "Cannot run in framebuffer mode... specify busIDs"
#   - Or greeter flashes and disappears: "kwin: Unknown option 'no-effects'"
#
# Cause:
#   Pi 5 has two DRM devices (v3d + vc4). SDDM's default X11 greeter fails.
#   Use Wayland greeter with kwin_wayland. Do NOT pass --no-effects (removed in KWin 6.3).
#
# Usage (after installing plasma-mobile-core):
#   chmod +x fix-sddm-pi5-kde-mobile.sh
#   sudo ./fix-sddm-pi5-kde-mobile.sh
#
# Then reboot if greeter does not appear:
#   sudo reboot
#
# At login: choose session "Plasma Mobile" (not Plasma Desktop).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

echo "=============================================="
echo " SDDM fix for Pi 5 + KDE Plasma Mobile"
echo "=============================================="

# --- optional deps (safe if already installed) ---
echo ""
echo "[1/5] Installing Wayland greeter dependencies..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  kwin-wayland \
  qt6-wayland \
  libqt6waylandclient6 \
  sddm-theme-breeze \
  sddm-theme-debian-breeze \
  2>/dev/null || true

# --- SDDM: Wayland greeter ---
echo ""
echo "[2/5] Writing /etc/sddm.conf.d/wayland.conf ..."
mkdir -p /etc/sddm.conf.d

cat >/etc/sddm.conf.d/wayland.conf <<'EOF'
[General]
# Pi 5: X11 greeter fails (dual DRM). Use Wayland.
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
# KWin 6.3+: do not use --no-effects (option removed; greeter exits immediately)
CompositorCommand=kwin_wayland --drm --no-global-shortcuts --no-lockscreen

[Users]
MaximumUid=60000

[Theme]
Current=breeze
EOF

# --- Xorg fallback (apps / troubleshooting; card1 = vc4-drm display on Pi 5) ---
echo ""
echo "[3/5] Writing Xorg fallback for Pi 5 KMS (card1)..."
mkdir -p /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/99-rpi5-kms.conf <<'EOF'
Section "Device"
    Identifier "Pi5KMS"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection
EOF

# --- enable graphical boot ---
echo ""
echo "[4/5] Enabling graphical target and SDDM..."
systemctl set-default graphical.target
systemctl enable sddm

# --- restart and verify ---
echo ""
echo "[5/5] Restarting SDDM..."
systemctl restart sddm
sleep 6

echo ""
echo "=== SDDM service ==="
systemctl is-active sddm && echo "sddm: active" || echo "sddm: FAILED"

echo ""
echo "=== Recent SDDM log ==="
journalctl -u sddm -b 0 --no-pager | tail -15

echo ""
echo "=== Greeter processes (expect kwin_wayland + sddm-greeter-qt6) ==="
ps aux | grep -E '[k]win_wayland|[s]ddm-greeter' || echo "(none yet — try: sudo reboot)"

if journalctl -u sddm -b 0 --no-pager | grep -q "no-effects"; then
  echo ""
  echo "WARNING: Log still mentions --no-effects. Check for overrides in /etc/sddm.conf.d/"
fi

if journalctl -u sddm -b 0 --no-pager | grep -q "Failed to read display number"; then
  echo ""
  echo "WARNING: X11 greeter may still be in use. Confirm DisplayServer=wayland in wayland.conf"
fi

echo ""
echo "=============================================="
echo " Done."
echo " - If no login screen: sudo reboot"
echo " - At login select: Plasma Mobile"
echo " - Verify: journalctl -u sddm -f"
echo "=============================================="
