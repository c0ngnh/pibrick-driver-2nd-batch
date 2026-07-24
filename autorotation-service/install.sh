#!/bin/bash
#
# pibrick-autorotation installer
#
# Installs the autorotation service for MMA8451Q accelerometer.
# Based on piBrick AOSP17 V6 by Sconioo.
#
# This script will automatically build the custom MMA8451Q kernel module
# if the kernel doesn't have CONFIG_MMA8452 enabled.
#
# Usage:
#   sudo ./install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

success() {
    echo -e "\033[0;32m[OK]\033[0m $*"
}

# Check for root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root (sudo)"
fi

info "Installing piBrick Autorotation Service..."
info "Based on piBrick AOSP17 V6 by Sconioo"

KERNEL_VERSION=$(uname -r)
KVER_DIR="/lib/modules/${KERNEL_VERSION}"
BUILD_DIR="${KVER_DIR}/build"
info "Kernel: $KERNEL_VERSION"

# ── Kernel Module Builder ────────────────────────────────────────────────────────

build_kernel_module() {
    info "Building custom MMA8451Q kernel module..."
    
    local MODULE_DIR="$SCRIPT_DIR/kernel-module"
    local MODULE_NAME="mma8451q"
    
    # Check if we have the source
    if [ ! -f "$MODULE_DIR/mma8451q.c" ]; then
        warn "Kernel module source not found at $MODULE_DIR/mma8451q.c"
        warn "Cannot build custom module"
        return 1
    fi
    
    # Ensure kernel headers are installed
    if [ ! -d "$BUILD_DIR" ]; then
        info "Kernel headers not found. Installing..."
        
        # Detect architecture and install appropriate headers
        local ARCH=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
        local headers_package=""
        
        case "$ARCH" in
            aarch64)
                # 64-bit ARM (CM5, CM4)
                if apt-cache show linux-headers-rpi-v8 &>/dev/null; then
                    headers_package="linux-headers-rpi-v8"
                elif apt-cache show "linux-headers-${KERNEL_VERSION}" &>/dev/null; then
                    headers_package="linux-headers-${KERNEL_VERSION}"
                fi
                ;;
            armv7l|armhf)
                # 32-bit ARM
                if apt-cache show linux-headers-armhf &>/dev/null; then
                    headers_package="linux-headers-armhf"
                elif apt-cache show "linux-headers-${KERNEL_VERSION}" &>/dev/null; then
                    headers_package="linux-headers-${KERNEL_VERSION}"
                fi
                ;;
            *)
                # Try generic package name
                if apt-cache show "linux-headers-${KERNEL_VERSION}" &>/dev/null; then
                    headers_package="linux-headers-${KERNEL_VERSION}"
                elif apt-cache show linux-headers-arm64 &>/dev/null; then
                    headers_package="linux-headers-arm64"
                fi
                ;;
        esac
        
        if [ -n "$headers_package" ]; then
            info "Installing: $headers_package"
            apt-get update && apt-get install -y "$headers_package" || {
                warn "Failed to install kernel headers"
                return 1
            }
        else
            warn "Could not determine correct headers package"
            warn "Try installing manually: sudo apt install linux-headers-\$(uname -r)"
            return 1
        fi
    fi
    
    # Verify Makefile exists
    if [ ! -f "${BUILD_DIR}/Makefile" ]; then
        error "Invalid kernel headers at $BUILD_DIR (no Makefile)"
        return 1
    fi
    
    # Build the module
    info "Compiling kernel module..."
    cd "$MODULE_DIR"
    
    # Clean previous build
    make clean 2>/dev/null || true
    
    # Build with external module Makefile
    if make -C "$BUILD_DIR" M="$(pwd)" modules 2>&1; then
        if [ -f "${MODULE_NAME}.ko" ]; then
            info "Module compiled successfully: ${MODULE_NAME}.ko"
            
            # Get module info
            modinfo "${MODULE_NAME}.ko" 2>/dev/null | head -5 || true
            
            # Install to kernel module directory
            info "Installing module to $KVER_DIR/extra/"
            mkdir -p "$KVER_DIR/extra"
            cp "${MODULE_NAME}.ko" "$KVER_DIR/extra/"
            
            # Update module dependencies
            depmod -a
            
            # Load the module
            info "Loading module..."
            if modprobe -v "${MODULE_NAME}" 2>&1; then
                success "MMA8451Q kernel module loaded successfully"
                
                # Verify IIO device appeared
                sleep 1
                if ls /sys/bus/iio/devices/ 2>/dev/null | grep -q .; then
                    info "IIO devices available:"
                    for dev in /sys/bus/iio/devices/iio:device*; do
                        [ -f "$dev/name" ] && info "  - $dev: $(cat "$dev/name")"
                    done
                fi
                return 0
            else
                warn "Module loaded but may have issues. Check dmesg."
                return 0  # Still consider it a success
            fi
        else
            error "Module file not created after build"
            return 1
        fi
    else
        error "Kernel module build failed"
        info "Check the output above for errors"
        return 1
    fi
}

# ── Check/Build Kernel Module ────────────────────────────────────────────────────

check_and_build_module() {
    info "Checking for MMA8451Q kernel driver..."
    
    local driver_found=0
    
    # Method 1: Check if already loaded
    if lsmod 2>/dev/null | grep -q "mma845"; then
        info "  mma845 driver is already loaded"
        driver_found=1
    fi
    
    # Method 2: Check kernel config
    if [ "$driver_found" = "0" ]; then
        for config_path in "/proc/config.gz" "/boot/config-$KERNEL_VERSION" "/boot/config.txt"; do
            if [ -f "$config_path" ]; then
                if zcat "$config_path" 2>/dev/null | grep -q "CONFIG_MMA8452=y"; then
                    info "  MMA8452 is built into kernel"
                    driver_found=1
                    break
                elif zcat "$config_path" 2>/dev/null | grep -q "CONFIG_MMA8452=m"; then
                    info "  MMA8452 available as module"
                    driver_found=1
                    # Try to load it
                    if modprobe mma8452 2>/dev/null; then
                        info "  mma8452 module loaded"
                    fi
                    break
                fi
            fi
        done
    fi
    
    # Method 3: Check for our custom module
    if [ "$driver_found" = "0" ]; then
        if [ -f "$KVER_DIR/extra/mma8451q.ko" ]; then
            info "  Custom mma8451q module found, loading..."
            if modprobe -v mma8451q 2>/dev/null; then
                info "  Custom module loaded successfully"
                driver_found=1
            fi
        fi
    fi
    
    # Method 4: Check if IIO device exists (driver may be loaded)
    if [ "$driver_found" = "0" ]; then
        if [ -d "/sys/bus/iio/devices/iio:device0" ]; then
            local name=$(cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null || echo "")
            if [[ "$name" == *"mma"* ]]; then
                info "  MMA845x device found in IIO subsystem"
                driver_found=1
            fi
        fi
    fi
    
    # If no driver found, build custom module
    if [ "$driver_found" = "0" ]; then
        warn "MMA8452 driver not available in kernel"
        warn "Building custom MMA8451Q kernel module..."
        echo ""
        
        if build_kernel_module; then
            success "Custom kernel module built and installed"
            return 0
        else
            warn "Failed to build custom kernel module"
            warn "Service will use userspace I2C fallback instead"
            return 1
        fi
    fi
    
    return 0
}

check_and_build_module

# ── Device Tree Overlay ─────────────────────────────────────────────────────────

info "Setting up device tree overlay..."
DTBO_DIR="/boot/firmware/overlays"
DTBO_NAME="pibrick-mma8451q"

if [ ! -f "$SCRIPT_DIR/dtb/mma8451q-overlay.dts" ]; then
    warn "Device tree source not found"
else
    # Check if dtc is available
    if ! command -v dtc >/dev/null 2>&1; then
        warn "dtc (device tree compiler) not found"
        warn "On Raspberry Pi OS: sudo apt install device-tree-compiler"
    else
        mkdir -p "$DTBO_DIR"
        
        # Compile the overlay
        if dtc -I dts -O dtb -o "$DTBO_DIR/$DTBO_NAME.dtbo" \
            -@ -b 0 -d /dev/null "$SCRIPT_DIR/dtb/mma8451q-overlay.dts" 2>/dev/null; then
            info "  Device tree overlay compiled: $DTBO_NAME.dtbo"
            
            # Add to config.txt if not already present
            if ! grep -q "dtoverlay=$DTBO_NAME" /boot/firmware/config.txt 2>/dev/null; then
                echo "dtoverlay=$DTBO_NAME" >> /boot/firmware/config.txt
                info "  Added dtoverlay=$DTBO_NAME to config.txt"
            else
                info "  Overlay already configured in config.txt"
            fi
        else
            warn "Failed to compile device tree overlay"
        fi
    fi
fi

# ── Install Service Files ───────────────────────────────────────────────────────

info "Installing autorotation service..."

# Create state directory
mkdir -p /var/lib/pibrick
chmod 755 /var/lib/pibrick

# Install main service script
install -m 755 "$SCRIPT_DIR/pibrick-autorotation.sh" /usr/local/bin/pibrick-autorotation.sh
install -m 755 "$SCRIPT_DIR/pibrick-autorotation.sh" /usr/local/bin/pibrick-autorotation  # Alias

# Install kscreen helper script for KDE Plasma rotation (optional, for reference)
cat > /usr/local/bin/pibrick-kscreen-helper.sh << 'HELPEREOF'
#!/bin/bash
# Wrapper for kscreen-doctor that preserves Wayland and D-Bus environment
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
exec kscreen-doctor "$@"
HELPEREOF
install -m 755 /usr/local/bin/pibrick-kscreen-helper.sh 2>/dev/null || chmod +x /usr/local/bin/pibrick-kscreen-helper.sh

# For KDE Plasma Mobile, create autostart entry (optional).
# Resolve the real desktop user so the .desktop file lands in the correct home.
autostart_home="/root"
if [ -n "${SUDO_USER:-}" ] && [ "$(id -un)" = "root" ]; then
	autostart_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
	autostart_home="${autostart_home:-/root}"
fi
if mkdir -p "$autostart_home/.config/autostart" 2>/dev/null; then
    cat > "$autostart_home/.config/autostart/pibrick-autorotation.desktop" << 'AUTOSTARTEOF'
[Desktop Entry]
Type=Application
Name=piBrick Autorotation
Exec=/usr/local/bin/pibrick-autorotation.sh
X-GNOME-Autostart-enabled=true
AUTOSTARTEOF
    info "Created autostart entry for KDE Plasma Mobile"
fi

# Install action scripts
mkdir -p /etc/pibrick/actions
install -m 755 "$SCRIPT_DIR/etc/pibrick/actions/autorotation-lock.sh" /etc/pibrick/actions/autorotation-lock.sh

# Install systemd service
install -m 644 "$SCRIPT_DIR/pibrick-autorotation.service" /etc/systemd/system/pibrick-autorotation.service

# Reload systemd
systemctl daemon-reload

# ── Enable and Start Service ────────────────────────────────────────────────────

info "Enabling autorotation service..."
systemctl enable pibrick-autorotation.service

info "Starting autorotation service..."
if systemctl restart pibrick-autorotation.service; then
    success "Autorotation service started"
else
    warn "Service failed to start - checking logs..."
    journalctl -u pibrick-autorotation -n 5 --no-pager || true
fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "=== piBrick Autorotation Service Installed ==="
echo ""

# Check driver status
if lsmod 2>/dev/null | grep -q "mma845"; then
    echo "Kernel Driver: mma8452 (built-in)"
elif [ -f "$KVER_DIR/extra/mma8451q.ko" ]; then
    echo "Kernel Driver: mma8451q (custom module)"
else
    echo "Kernel Driver: userspace I2C fallback"
fi

echo "Hardware: MMA8451Q accelerometer on I2C1 (address 0x1C)"
echo ""
echo "The service monitors device orientation and rotates the screen automatically."
echo ""
echo "Usage:"
echo "  autorotation-lock [normal|left|right|inverted]  Lock to specific orientation"
echo "  autorotation-lock auto                       Enable auto-rotation"
echo ""
echo "Service commands:"
echo "  sudo systemctl start pibrick-autorotation"
echo "  sudo systemctl stop pibrick-autorotation"
echo "  sudo systemctl restart pibrick-autorotation"
echo "  sudo pibrick-autorotation.sh --status       View status"
echo "  journalctl -u pibrick-autorotation -f       View logs"
echo ""

# Check if reboot needed
if [ -f "$DTBO_DIR/$DTBO_NAME.dtbo" ]; then
    echo "IMPORTANT: Reboot to load the device tree overlay for MMA8451Q!"
    echo ""
fi

# Final status
echo -n "Status: "
if systemctl is-active pibrick-autorotation.service 2>/dev/null; then
    echo "running"
else
    echo "stopped"
fi
