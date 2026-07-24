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

# Remove systemd unit
info "Removing systemd service..."
rm -f /etc/systemd/system/pibrick-autorotation.service
systemctl daemon-reload

# Remove binaries
info "Removing binaries..."
rm -f /usr/local/bin/pibrick-autorotation.sh
rm -f /usr/local/bin/pibrick-autorotation
rm -f /usr/local/bin/pibrick-kscreen-helper.sh
rm -f /usr/local/bin/pibrick-kscreen-rotate.py

# Remove sudoers config
info "Removing sudoers configuration..."
rm -f /etc/sudoers.d/pibrick-kscreen

# Remove action scripts
info "Removing action scripts..."
rm -f /etc/pibrick/actions/autorotation-lock.sh

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

# Optionally unload driver
if lsmod 2>/dev/null | grep -q mma845; then
    warn "MMA8452 driver is still loaded"
    warn "To unload: sudo modprobe -r mma8452"
fi

info "Autorotation service uninstalled."
echo ""
echo "Note: Reboot recommended to fully remove the MMA8451Q device tree overlay."
