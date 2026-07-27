#!/bin/bash
#
# pibrick-autorotation uninstaller
#
# Removes the autorotation service and device tree overlay
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

# Check for root
if [ "$(id -u)" != "0" ]; then
    echo "autorotation-uninstall: this command modifies the system; please re-run with sudo:" >&2
    echo "  sudo $0" >&2
    exit 1
fi

info "Uninstalling piBrick Autorotation Service..."

# Stop and disable service
info "Stopping service..."
systemctl stop pibrick-autorotation.service 2>/dev/null || true
systemctl disable pibrick-autorotation.service 2>/dev/null || true

# Unload kernel module if loaded
KVER="$(uname -r)"
KVER_DIR="/lib/modules/$KVER"
if [ -f "$KVER_DIR/extra/mma8451q.ko" ]; then
    if lsmod 2>/dev/null | grep -q mma8451q; then
        modprobe -r mma8451q 2>/dev/null || true
    fi
    rm -f "$KVER_DIR/extra/mma8451q.ko"
    depmod -a 2>/dev/null || true
fi

# Remove systemd unit
info "Removing systemd service..."
rm -f /etc/systemd/system/pibrick-autorotation.service
systemctl daemon-reload

# Remove binaries
info "Removing binaries..."
rm -f /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh
rm -f /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh.bak* 2>/dev/null || true
rmdir /usr/lib/pibrick/autorotation-service 2>/dev/null || true

# Remove action scripts
info "Removing action scripts..."
rm -f /etc/pibrick/actions/autorotation-lock.sh

# Remove autostart desktop entry
info "Removing autostart entry..."
for home in /root /home/*; do
    rm -f "$home/.config/autostart/pibrick-autorotation.desktop" 2>/dev/null || true
done

# Remove device tree overlay
info "Removing device tree overlay..."
rm -f /boot/firmware/overlays/pibrick-mma8451q.dtbo 2>/dev/null || true

# Remove from config.txt
info "Cleaning up config.txt..."
sed -i '/dtoverlay=pibrick-mma8451q/d' /boot/firmware/config.txt 2>/dev/null || true

# Remove state files
info "Removing state files..."
rm -f /var/lib/pibrick/autorotation.lock
rm -f /var/lib/pibrick/autorotation.lock.type

info "Autorotation service uninstalled."
