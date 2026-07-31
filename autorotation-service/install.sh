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

# Copy src to dst only when they differ (avoids "same file" errors from cp/install).
# Preserves permissions and ownership like cp -p.
safe_cp() {
    local src="$1" dst="$2"
    [ -f "$src" ] || { error "safe_cp: source not found: $src"; return 1; }
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    cp -p "$src" "$dst"
}

# Check for root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root (sudo)"
    exit 1
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
            
            success "Kernel module installed: $KVER_DIR/extra/${MODULE_NAME}.ko"
            return 0
        else
            warn "Build completed but .ko file not found"
            return 1
        fi
    else
        warn "Failed to compile kernel module"
        return 1
    fi
}

# ── Check for MMA8451Q driver ─────────────────────────────────────────────────

check_mma8451q_driver() {
    info "Checking for MMA8451Q kernel driver..."
    
    # Check if built-in driver exists
    if [ -f "$KVER_DIR/extra/mma8451q.ko" ]; then
        info "  Custom mma8451q module found, loading..."
        modprobe mma8451q 2>/dev/null && info "  Custom module loaded successfully" || warn "  Could not load custom module"
        return 0
    fi
    
    # Check if mma8452 (generic) is available
    if modprobe mma8452 2>/dev/null; then
        info "  Using built-in mma8452 driver"
        return 0
    fi
    
    # Check if the module is already loaded
    if lsmod | grep -q "mma845"; then
        info "  MMA845 driver already loaded"
        return 0
    fi
    
    # Try to build and load custom module
    if [ -f "$SCRIPT_DIR/kernel-module/mma8451q.c" ]; then
        if build_kernel_module; then
            modprobe mma8451q 2>/dev/null || true
            return 0
        fi
    fi
    
    warn "No MMA8451Q driver available - will use userspace I2C fallback"
    return 1
}

check_mma8451q_driver

# ── Device Tree Overlay Setup ────────────────────────────────────────────────────

setup_device_tree() {
    info "Setting up device tree overlay..."
    
    local DTB_DIR="$SCRIPT_DIR/dtb"
    local OVERLAY="pibrick-mma8451q"
    
    # Find the overlay source file (different naming conventions)
    local overlay_src=""
    for src_file in "$DTB_DIR/${OVERLAY}.dts" "$DTB_DIR/mma8451q-overlay.dts" "$DTB_DIR/mma8451q.dts"; do
        if [ -f "$src_file" ]; then
            overlay_src="$src_file"
            break
        fi
    done
    
    # Check if we have the overlay source
    if [ -n "$overlay_src" ]; then
        info "  Found overlay source: $overlay_src"
        info "  Compiling device tree overlay..."
        
        # Compile the overlay with sudo (needs root for /boot)
        if sudo dtc -@ -I dts -O dtb -o "/boot/firmware/overlays/${OVERLAY}.dtbo" "$overlay_src" 2>/dev/null; then
            info "  Device tree overlay compiled: ${OVERLAY}.dtbo"
        else
            warn "  Could not compile device tree overlay"
        fi
    else
        warn "  No overlay source found in $DTB_DIR"
    fi
    
    # Check if overlay is in config.txt
    if [ -f /boot/firmware/config.txt ]; then
        if grep -q "^dtoverlay=${OVERLAY}" /boot/firmware/config.txt 2>/dev/null; then
            info "  Overlay already configured in config.txt"
        else
            info "  Adding overlay to config.txt..."
            echo "dtoverlay=${OVERLAY}" | sudo tee -a /boot/firmware/config.txt > /dev/null
            info "  Overlay added - reboot may be required"
        fi
    elif [ -f /boot/config.txt ]; then
        if grep -q "^dtoverlay=${OVERLAY}" /boot/config.txt 2>/dev/null; then
            info "  Overlay already configured in config.txt"
        else
            info "  Adding overlay to config.txt..."
            echo "dtoverlay=${OVERLAY}" | sudo tee -a /boot/config.txt > /dev/null
            info "  Overlay added - reboot may be required"
        fi
    fi
}

setup_device_tree

# ── I2C Device Setup ─────────────────────────────────────────────────────────────
# Some devices need the MMA8451Q to be added manually to I2C bus

setup_i2c_device() {
    info "Setting up I2C accelerometer device..."
    
    # Check if IIO device already exists
    if [ -d "/sys/bus/iio/devices/iio:device0" ]; then
        local device_name
        device_name=$(cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null || echo "")
        if [[ "$device_name" == *"mma"* ]] || [[ "$device_name" == *"accel"* ]]; then
            info "  Accelerometer already detected: $device_name"
            return 0
        fi
    fi
    
    # Check if device is present on I2C bus (address 0x1C)
    if [ -d "/sys/bus/i2c/devices/1-001c" ]; then
        info "  Device already registered on I2C bus"
        return 0
    fi
    
    # Try to add the device manually
    if [ -e "/sys/bus/i2c/devices/i2c-1/new_device" ]; then
        info "  Adding MMA8451Q to I2C bus..."
        if echo 'mma8451q 0x1c' | sudo tee /sys/bus/i2c/devices/i2c-1/new_device > /dev/null 2>&1; then
            sleep 2
            if [ -d "/sys/bus/iio/devices/iio:device0" ]; then
                local device_name
                device_name=$(cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null || echo "unknown")
                info "  ✓ Accelerometer detected: $device_name"
                
                # Make this persistent across reboots
                if [ -n "${SUDO_USER:-}" ]; then
                    local user_home
                    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
                    mkdir -p "$user_home/.config/autostart"
                    cat > "$user_home/.config/autostart/pibrick-i2c-setup.desktop" << 'I2CAUTOSTART'
[Desktop Entry]
Type=Application
Name=piBrick I2C Setup
Exec=/usr/bin/bash -c 'echo mma8451q 0x1c > /sys/bus/i2c/devices/i2c-1/new_device 2>/dev/null || true'
X-GNOME-Autostart-enabled=true
I2CAUTOSTART
                    chown "$SUDO_USER:$SUDO_USER" "$user_home/.config/autostart/pibrick-i2c-setup.desktop"
                    info "  Created autostart entry for I2C device"
                fi
                return 0
            fi
        fi
    fi
    
    warn "  Could not add I2C device - will retry after reboot"
}

setup_i2c_device

# ── Install Service Files ───────────────────────────────────────────────────────

info "Installing autorotation service..."

# Create state directory
mkdir -p /var/lib/pibrick
chmod 755 /var/lib/pibrick

# Install main service script
safe_cp "$SCRIPT_DIR/pibrick-autorotation.sh" /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh

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
Exec=/usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh
X-GNOME-Autostart-enabled=true
AUTOSTARTEOF
    info "Created autostart entry for KDE Plasma Mobile"
fi

# Install action scripts
mkdir -p /etc/pibrick/actions
safe_cp "$SCRIPT_DIR/etc/pibrick/actions/autorotation-lock.sh" /etc/pibrick/actions/autorotation-lock.sh

# Install autorotation-lock as a system-wide executable (used by the native Plasma
# Mobile quick setting or any other UI that needs to toggle rotation).
safe_cp "$SCRIPT_DIR/etc/pibrick/actions/autorotation-lock.sh" /usr/bin/autorotation-lock
chmod +x /usr/bin/autorotation-lock
info "Installed autorotation-lock to /usr/bin"

# ── Install Python services ─────────────────────────────────────────────────────
install_python_services() {
    info "Installing Python services..."

    # Install rotation UI daemon (provides HTTP API for QML plasmoid)
    safe_cp "$SCRIPT_DIR/plasmoid/pibrick-rotation-ui.py" /usr/lib/pibrick/autorotation-service/pibrick-rotation-ui.py
    info "  pibrick-rotation-ui.py installed"

    # Install D-Bus service (provides IPC interface)
    safe_cp "$SCRIPT_DIR/pibrick-autorotation-dbus.py" /usr/lib/pibrick/autorotation-service/pibrick-autorotation-dbus.py
    info "  pibrick-autorotation-dbus.py installed"

    # Install pibrick-autorotation-ctl (plasmoid control script)
    if [ -f "$SCRIPT_DIR/plasmoid/pibrick-autorotation-ctl.sh" ]; then
        safe_cp "$SCRIPT_DIR/plasmoid/pibrick-autorotation-ctl.sh" /usr/bin/pibrick-autorotation-ctl
        chmod +x /usr/bin/pibrick-autorotation-ctl
        info "  pibrick-autorotation-ctl installed"
    fi
}
install_python_services

# ── Install user systemd services ──────────────────────────────────────────────
install_user_services() {
    local user_home=""
    
    if [ -z "${SUDO_USER:-}" ]; then
        info "  No SUDO_USER set, skipping user services"
        return 0
    fi
    
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -z "$user_home" ]; then
        info "  Could not determine user home, skipping user services"
        return 0
    fi
    
    local user_systemd_dir="$user_home/.config/systemd/user"
    
    mkdir -p "$user_systemd_dir"
    mkdir -p "$user_systemd_dir/default.target.wants"
    
    # Create the user service file
    cat > "$user_systemd_dir/pibrick-rotation-ui.service" << 'EOF'
[Unit]
Description=piBrick Rotation Lock UI daemon
PartOf=graphical-session.target
After=graphical-session.target
BindsTo=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/lib/pibrick/autorotation-service/pibrick-rotation-ui.py
Restart=on-failure
RestartSec=2
Environment=DISPLAY=:0

[Install]
WantedBy=graphical-session.target
EOF
    
    chmod 644 "$user_systemd_dir/pibrick-rotation-ui.service"
    chown "$SUDO_USER:$SUDO_USER" "$user_systemd_dir/pibrick-rotation-ui.service"
    
    # Enable and start the user service
    sudo -u "$SUDO_USER" systemctl --user daemon-reload 2>/dev/null || true
    sudo -u "$SUDO_USER" systemctl --user enable pibrick-rotation-ui.service 2>/dev/null || true
    sudo -u "$SUDO_USER" systemctl --user start pibrick-rotation-ui.service 2>/dev/null || true
    
    info "  pibrick-rotation-ui.service installed and enabled (user)"
}
install_user_services

# ── Install D-Bus service for session activation ────────────────────────────────
install_dbus_service() {
    local user_home=""
    
    if [ -z "${SUDO_USER:-}" ]; then
        info "  No SUDO_USER set, skipping D-Bus service"
        return 0
    fi
    
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -z "$user_home" ]; then
        info "  Could not determine user home, skipping D-Bus service"
        return 0
    fi
    
    local dbus_service_dir="$user_home/.local/share/dbus-1/services"
    
    mkdir -p "$dbus_service_dir"
    
    cat > "$dbus_service_dir/com.pibrick.Autorotation.service" << 'EOF'
[D-BUS Service]
Name=com.pibrick.Autorotation
Exec=/usr/bin/python3 /usr/lib/pibrick/autorotation-service/pibrick-autorotation-dbus.py
User=%u
EOF
    
    chmod 644 "$dbus_service_dir/com.pibrick.Autorotation.service"
    chown "$SUDO_USER:$SUDO_USER" "$dbus_service_dir/com.pibrick.Autorotation.service"
    
    info "  D-Bus session service installed"
}
install_dbus_service

# ── Install Plasmoid ───────────────────────────────────────────────────────────
install_plasmoid() {
    local user_home=""
    
    if [ -z "${SUDO_USER:-}" ]; then
        info "  No SUDO_USER set, skipping plasmoid"
        return 0
    fi
    
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -z "$user_home" ]; then
        info "  Could not determine user home, skipping plasmoid"
        return 0
    fi
    
    info "Installing plasmoid..."
    
    # Install to kservices5
    local plasmoid_dir="$user_home/.local/share/kservices5/pibrick-rotation-lock"
    rm -rf "$plasmoid_dir" 2>/dev/null || true
    
    if [ -d "$SCRIPT_DIR/plasmoid" ]; then
        # Create parent directory if it doesn't exist
        mkdir -p "$user_home/.local/share/kservices5"
        cp -r "$SCRIPT_DIR/plasmoid" "$plasmoid_dir"
        # Remove old metadata.desktop if present (Plasma 6 uses metadata.json)
        rm -f "$plasmoid_dir/metadata/metadata.desktop" 2>/dev/null || true
        chown -R "$SUDO_USER:$SUDO_USER" "$plasmoid_dir"
        info "  Plasmoid installed to kservices5"
    fi
    
    # Install to plasma plasmoids
    local plasma_plasmoid_dir="$user_home/.local/share/plasma/plasmoids/pibrick-rotation-lock"
    # Create parent directories if they don't exist
    mkdir -p "$user_home/.local/share/plasma/plasmoids"
    if [ -d "$SCRIPT_DIR/plasmoid" ]; then
        rm -rf "$plasma_plasmoid_dir" 2>/dev/null || true
        cp -r "$SCRIPT_DIR/plasmoid" "$plasma_plasmoid_dir"
        # Remove old metadata.desktop if present (Plasma 6 uses metadata.json)
        rm -f "$plasma_plasmoid_dir/metadata/metadata.desktop" 2>/dev/null || true
        chown -R "$SUDO_USER:$SUDO_USER" "$plasma_plasmoid_dir"
        info "  Plasmoid installed to plasma/plasmoids"
    fi
}
install_plasmoid

# ── Install Plasmoid to System Location ─────────────────────────────────────────
install_system_plasmoid() {
    info "Installing plasmoid to system location..."
    if [ -d "$SCRIPT_DIR/plasmoid" ]; then
        local system_plasmoid_dir="/usr/share/plasma/plasmoids/pibrick-rotation-lock"
        rm -rf "$system_plasmoid_dir" 2>/dev/null || true
        cp -r "$SCRIPT_DIR/plasmoid" "$system_plasmoid_dir"
        # Remove old metadata.desktop if present (Plasma 6 uses metadata.json)
        rm -f "$system_plasmoid_dir/metadata/metadata.desktop" 2>/dev/null || true
        info "  Plasmoid installed to system location"
    fi
}
install_system_plasmoid

# ── Build & install the piBrick Quick-Setting QML extension plugin ───────────────
# Defined BEFORE install_quicksetting() below so the helper is visible in the
# function table when install_quicksetting() runs. (Bash resolves function
# names at call time from the table as-built by the parser; a forward
# reference to a function defined later in the file is a "command not found"
# error.)
#
# Compiles plugin-src/{plugin.cpp,util.h,util.cpp} into a Qt6 QML plugin shared
# library and drops it next to a qmldir at
#   /usr/lib/qt6/qml/<qml-uri>/
# so the tile's QML can `import <qml-uri> 1.0` and get a bindable
# PibrickAutorotationUtil singleton.
#
# Args: $1 = quicksetting plugin id (e.g. org.kde.plasma.quicksetting.pibrick-autorotation)
# Returns 0 on success (built or skipped because already up-to-date), 1 on failure.
build_quicksetting_plugin() {
    local qs_id="$1"
    local src_dir="$SCRIPT_DIR/quicksetting/plugin-src"

    # QML module URIs may not contain hyphens (Qt's QML grammar restricts
    # identifiers to [A-Za-z0-9_.]). The KPackage Id above may have a hyphen
    # because it is just a directory name; the QML URI we register and import
    # must replace it with an underscore.
    local qml_uri="${qs_id//-/_}"
    local qml_install_root="/usr/lib/qt6/qml/$qml_uri"
    local out_so="$qml_install_root/libpibrick-autorotation-plugin.so"

    if [ ! -d "$src_dir" ]; then
        warn "  plugin-src/ not present; skipping plugin build"
        return 1
    fi

    # ── 1. Toolchain detection ───────────────────────────────────────────────
    local cxx=""
    for candidate in g++ c++; do
        if command -v "$candidate" >/dev/null 2>&1; then
            cxx="$candidate"
            break
        fi
    done
    if [ -z "$cxx" ]; then
        warn "  C++ compiler not found (g++/c++). Attempting apt-get install..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                g++ \
                qt6-base-dev \
                qt6-declarative-dev \
                >/dev/null 2>&1 || {
                warn "  apt-get install g++ qt6-base-dev failed."
                warn "  Install manually with:"
                warn "    sudo apt install g++ qt6-base-dev qt6-declarative-dev"
                return 1
            }
        else
            warn "  No C++ compiler and no apt-get available. Aborting plugin build."
            return 1
        fi
        cxx=g++
    fi

    local moc=""
    # On Debian, moc lives at /usr/lib/qt6/libexec/moc but is NOT on PATH
    # (no /usr/bin/moc-qt6 symlink). Check PATH first, then fall back to
    # the known Debian layout, then look up the path via dpkg.
    for candidate in moc-qt6 moc "/usr/lib/qt6/libexec/moc"; do
        if [ -x "$candidate" ]; then
            moc="$candidate"
            break
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            moc="$(command -v "$candidate")"
            break
        fi
    done
    if [ -z "$moc" ] && command -v dpkg >/dev/null 2>&1; then
        local dpkg_moc
        dpkg_moc=$(dpkg -L qt6-base-dev-tools 2>/dev/null | grep -E '/moc$' | head -1 || true)
        if [ -x "$dpkg_moc" ]; then
            moc="$dpkg_moc"
        fi
    fi
    if [ -z "$moc" ]; then
        warn "  Qt6 moc not found. Attempting apt-get install qt6-base-dev qt6-declarative-dev..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                qt6-base-dev \
                qt6-declarative-dev \
                >/dev/null 2>&1 || {
                warn "  Could not install qt6-base-dev / qt6-declarative-dev. Aborting plugin build."
                return 1
            }
            # After install, re-scan: Debian package may install moc-qt6
            # and/or drop moc into /usr/lib/qt6/libexec/.
            for candidate in moc-qt6 moc "/usr/lib/qt6/libexec/moc"; do
                if [ -x "$candidate" ]; then
                    moc="$candidate"
                    break
                fi
                if command -v "$candidate" >/dev/null 2>&1; then
                    moc="$(command -v "$candidate")"
                    break
                fi
            done
        else
            warn "  No Qt6 moc available. Aborting plugin build."
            return 1
        fi
    fi
    if [ -z "$moc" ]; then
        warn "  Qt6 moc still not found after install. Aborting plugin build."
        return 1
    fi

    # Resolve the multiarch path once, up front. We need it for both the
    # QtQml-headers check below and the include flags later.
    local multiarch=""
    if command -v gcc >/dev/null 2>&1; then
        multiarch=$(gcc -print-multiarch 2>/dev/null || true)
    fi
    if [ -z "$multiarch" ] && command -v dpkg >/dev/null 2>&1; then
        local dpkg_arch
        dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
        [ -n "$dpkg_arch" ] && multiarch="${dpkg_arch}-linux-gnu"
    fi
    # Last resort: scan /usr/include/*/qt6 — covers Arch, NixOS, layouts we
    # don't know about in advance.
    local qt6_root=""
    if [ -n "$multiarch" ] && [ -d "/usr/include/${multiarch}/qt6" ]; then
        qt6_root="/usr/include/${multiarch}/qt6"
    else
        local found
        found=$(find /usr/include -maxdepth 2 -type d -name qt6 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            qt6_root="$found"
            multiarch=$(basename "$(dirname "$found")")
        fi
    fi

    # Also make sure the QtQml headers are present. qt6-base-dev alone is
    # not sufficient — we need qt6-declarative-dev for QQmlEngine /
    # QQmlExtensionPlugin.
    if [ -z "$qt6_root" ] || [ ! -d "${qt6_root}/QtQml" ]; then
        warn "  QtQml headers missing. Attempting apt-get install qt6-declarative-dev..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                qt6-declarative-dev \
                >/dev/null 2>&1 || {
                warn "  Could not install qt6-declarative-dev. Aborting plugin build."
                return 1
            }
            # Re-resolve qt6_root after the install.
            if [ -n "$multiarch" ] && [ -d "/usr/include/${multiarch}/qt6" ]; then
                qt6_root="/usr/include/${multiarch}/qt6"
            elif [ -d /usr/include/qt6 ]; then
                qt6_root=/usr/include/qt6
            fi
        fi
    fi

    # ── 2. Qt6 include / link flags via pkg-config ───────────────────────────
    # `pkg-config --cflags Qt6Core Qt6Qml` gives e.g. -I/usr/include/x86_64-linux-gnu/qt6
    # `pkg-config --libs` gives -lQt6Core -lQt6Qml. We prefer pkg-config when present
    # because the include path is multiarch on Debian and not always /usr/include.
    local qt_cflags=""
    local qt_libs=""
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists Qt6Core Qt6Qml 2>/dev/null; then
        qt_cflags=$(pkg-config --cflags Qt6Core Qt6Qml 2>/dev/null || true)
        qt_libs=$(pkg-config --libs Qt6Core Qt6Qml 2>/dev/null || true)
    fi
    if [ -z "$qt_cflags" ] || [ -z "$qt_libs" ]; then
        # Fallback: use the qt6_root we resolved earlier. Qt6 doesn't ship
        # pkg-config .pc files on Debian (only on Fedora/Arch etc.), so we
        # fall back to the multiarch include path we already located.
        if [ -z "$qt6_root" ] || [ ! -d "$qt6_root" ]; then
            warn "  pkg-config for Qt6 not available and multiarch Qt6 headers not found."
            warn "  Install with: sudo apt install qt6-base-dev qt6-declarative-dev"
            return 1
        fi
        qt_cflags="-I${qt6_root} -I${qt6_root}/QtCore -I${qt6_root}/QtQml"
        qt_libs="-lQt6Core -lQt6Qml"
        info "  pkg-config not available; using multiarch path ${qt6_root}"
    fi

    # ── 3. Skip if up-to-date (idempotent) ──────────────────────────────────
    local newer=0
    for f in "$src_dir"/*.cpp "$src_dir"/*.h "$src_dir/qmldir"; do
        if [ -f "$f" ] && [ ! -f "$out_so" -o "$f" -nt "$out_so" ]; then
            newer=1
            break
        fi
    done
    if [ "$newer" = "0" ] && [ -f "$out_so" ]; then
        info "  QML plugin already built and up-to-date."
        return 0
    fi

    # ── 4. Build ────────────────────────────────────────────────────────────
    local build_dir
    build_dir=$(mktemp -d /tmp/pibrick-qs-plugin-XXXXXX)
    info "  Building QML plugin in $build_dir (this takes ~5s the first time)..."
    info "  qml_uri=$qml_uri  cxx=$cxx  moc=$moc"

    # Run moc on both headers; outputs are moc_<hdr>.cpp files. We include
    # those moc_*.cpp outputs at the bottom of the matching .cpp file.
    # We surface moc's stderr because silent moc failures are a common
    # mistake when the moc binary is the wrong Qt version, or the input
    # isn't a recognized MOC input.
    #
    # moc also needs the include paths so it can resolve <QObject> etc.
    # inside the headers it scans. Without these flags moc emits
    # "fatal error: 'QObject': No such file or directory" and exits 1.
    "$moc" $qt_cflags -o "$build_dir/moc_pibrick-autorotation-util.cpp" \
        "$src_dir/pibrick-autorotation-util.h" \
        >"$build_dir/moc-util.log" 2>&1 || {
        warn "  moc failed for pibrick-autorotation-util.h. moc stderr:"
        sed 's/^/      /' "$build_dir/moc-util.log" >&2
        warn "  (moc=$moc, moc --version: $($moc --version 2>&1 | head -1))"
        rm -rf "$build_dir"
        return 1
    }
    "$moc" $qt_cflags -o "$build_dir/pibrick-autorotation-plugin.moc" \
        "$src_dir/pibrick-autorotation-plugin.cpp" \
        >"$build_dir/moc-plugin.log" 2>&1 || {
        warn "  moc failed for pibrick-autorotation-plugin.cpp. moc stderr:"
        sed 's/^/      /' "$build_dir/moc-plugin.log" >&2
        warn "  (moc=$moc, moc --version: $($moc --version 2>&1 | head -1))"
        rm -rf "$build_dir"
        return 1
    }

    # ── 4. Compile & link. -fPIC + -shared. We deliberately do not link ─────
    # against Qt6Widgets / Qt6Quick / Qt6Svg — only Core + Qml are needed.
    # -I"$build_dir" lets the .cpp files `#include "moc_*.cpp"` to pull in
    # the MOC-generated code, since moc output lives in the build dir rather
    # than the source dir. We deliberately do NOT pass moc_*.cpp as a
    # separate compile input — that would cause ODR violations with the
    # `#include "moc_*.cpp"` at the bottom of each .cpp file.
    #
    # The linker needs the destination directory to exist before it can
    # create the .so there. Otherwise /usr/bin/ld exits with
    # 'cannot open output file ...: No such file or directory' even though
    # the compile succeeded.
    mkdir -p "$qml_install_root"
    if ! "$cxx" -fPIC -shared -std=c++17 \
        -fvisibility=hidden \
        -I"$build_dir" \
        $qt_cflags \
        "$src_dir/pibrick-autorotation-plugin.cpp" \
        "$src_dir/pibrick-autorotation-util.cpp" \
        -o "$out_so" \
        $qt_libs \
        2>"$build_dir/build.log"; then
        warn "  C++ build failed. Build log:"
        sed 's/^/      /' "$build_dir/build.log" >&2
        rm -rf "$build_dir"
        return 1
    fi

    # ── 5. Install qmldir + .so into the QML module dir ────────────────────
    safe_cp "$src_dir/qmldir" "$qml_install_root/qmldir"
    chmod 644 "$out_so"
    success "  QML plugin installed: $out_so"

    # Drop a small README next to it so uninstall doesn't leave a mystery.
    cat > "$qml_install_root/.pibrick-autorotation-source" <<EOF
Built by autorotation-service/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
Source: $src_dir/
Build cmd: $cxx -fPIC -shared -std=c++17 -fvisibility=hidden \\
    $qt_cflags \\
    pibrick-autorotation-plugin.cpp \\
    pibrick-autorotation-util.cpp \\
    -o $out_so \\
    $qt_libs
EOF

    rm -rf "$build_dir"
    return 0
}

# ── Install Quick Drawer entry (Plasma Mobile top-pull panel) ───────────────────
# Drops a GenericQML KPackage at /usr/share/plasma/quicksettings/ so the tile
# appears in the Quick Drawer (top-pull panel) alongside the built-in entries.
# Idempotent: re-running replaces the package in place.
install_quicksetting() {
    info "Installing Quick Drawer entry..."

    # Ensure the entry is in the user's enabled-quick-settings list. The
    # shell only renders tiles that are both (a) discoverable on disk
    # AND (b) listed in enabledQuickSettings. We add it implicitly if
    # the user already has a list set (so we don't drop their other
    # customizations), and skip otherwise — the user can enable it via
    # Settings → Shell → Action Drawer → Quick Settings.
    if [ -n "${SUDO_USER:-}" ]; then
        local user_home
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        local pmrc="${user_home:-$HOME}/.config/plasmamobilerc"
        if [ -f "$pmrc" ] && grep -q '^enabledQuickSettings=' "$pmrc" 2>/dev/null; then
            if ! grep -q 'pibrick-autorotation' "$pmrc"; then
                info "  Adding pibrick-autorotation to enabledQuickSettings in $pmrc"
                # Append to the comma-separated list without disturbing order.
                sed -i 's|^enabledQuickSettings=\(.*\)$|\1,org.kde.plasma.quicksetting.pibrick-autorotation|' \
                    "$pmrc"
            fi
        fi
    fi

    if [ ! -d "$SCRIPT_DIR/quicksetting" ]; then
        warn "  quicksetting package source missing; skipping"
        return 0
    fi
    local qs_id
    qs_id=$(grep -o '"Id": *"[^"]*"' "$SCRIPT_DIR/quicksetting/package/metadata.json" \
            | head -1 | sed 's/.*"\(org\.kde\.plasma\.quicksetting\.[^"]*\)".*/\1/')
    if [ -z "$qs_id" ]; then
        warn "  could not read quicksetting Id from metadata.json; skipping"
        return 0
    fi
    local qs_dir="/usr/share/plasma/quicksettings/$qs_id"
    rm -rf "$qs_dir" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/quicksetting/package" "$qs_dir"
    # The default QML imports a QML module installed by the C++ plugin
    # built below. We stage it as main.qml temporarily; after the plugin
    # build we either keep it (plugin OK) or replace it with main-fallback.qml
    # (plugin failed — missing the import would otherwise drop the tile).
    local qml_uri="${qs_id//-/_}"
    local plugin_so="/usr/lib/qt6/qml/$qml_uri/libpibrick-autorotation-plugin.so"

    info "  Quick Drawer entry installed: $qs_id"

    # Build and install the matching QML extension plugin so the tile
    # gets a bindable state property. Without it, the tile would always
    # appear "on" because pure QML in this sandbox has no way to read
    # the auto-rotation state. See plugin-src/README-style comments in
    # pibrick-autorotation-util.h for the rationale.
    if build_quicksetting_plugin "$qs_id"; then
        info "  Tile state is now live (auto / locked)."
    else
        warn "  QML plugin build failed — falling back to a static tile."
        warn "  The 'Auto-rotate' tile will still appear, but it will not"
        warn "  reflect the current rotation state. To get live state,"
        warn "  install Qt6 dev headers and rerun:"
        warn "    sudo apt install g++ qt6-base-dev qt6-declarative-dev"
        if [ -f "$qs_dir/contents/ui/main-fallback.qml" ]; then
            mv "$qs_dir/contents/ui/main.qml" "$qs_dir/contents/ui/main.qml.disabled"
            mv "$qs_dir/contents/ui/main-fallback.qml" "$qs_dir/contents/ui/main.qml"
            info "  Replaced main.qml with the no-plugin fallback."
        else
            warn "  No main-fallback.qml found; leaving the stateful main.qml"
            warn "  in place — it will fail to load and the tile will be hidden."
        fi
    fi

    info "  Sign out and back in once; the 'Auto-rotate' tile will then appear in the"
    info "  top-pull Quick Drawer. (The shell scans quicksettings/ at session start;"
    info "  there is no user-level plasmashell unit on this image to restart instead.)"
}
install_quicksetting

# ── Add Plasmoid to Panel Configuration ─────────────────────────────────────────
add_plasmoid_to_panel() {
    local user_home=""
    
    if [ -z "${SUDO_USER:-}" ]; then
        info "  No SUDO_USER set, skipping panel config"
        return 0
    fi
    
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -z "$user_home" ]; then
        info "  Could not determine user home, skipping panel config"
        return 0
    fi
    
    info "Adding widget to Plasma Mobile panel..."
    
    local panel_config="$user_home/.config/plasma-org.kde.plasma.mobileshell-appletsrc"
    
    # Create the config file if it doesn't exist
    if [ ! -f "$panel_config" ]; then
        mkdir -p "$(dirname "$panel_config")"
        cat > "$panel_config" << 'PANELCONFIGEOF'
[Containments][1]
plugin=org.kde.plasma.mobile.homescreen.folio

[Containments][3]
plugin=org.kde.plasma.mobile.panel
PANELCONFIGEOF
        chown "$SUDO_USER:$SUDO_USER" "$panel_config"
    fi
    
    # Check if the widget is already added
    if ! grep -q "pibrick-rotation-lock" "$panel_config" 2>/dev/null; then
        # Find the next available applet ID using awk
        local applet_id
        applet_id=$(awk -F'[][]' '/Applets\]\[/ {gsub(/\[/, "", $2); if ($2 > max) max=$2} END {print (max+1)}' "$panel_config" 2>/dev/null || echo "101")
        [ -z "$applet_id" ] && applet_id="101"
        
        cat >> "$panel_config" << EOF

[Containments][3][Applets][$applet_id]
plugin=pibrick-rotation-lock
EOF
        chown "$SUDO_USER:$SUDO_USER" "$panel_config"
        info "  Widget added to panel (ID: $applet_id)"
    else
        info "  Widget already in panel configuration"
    fi
}
add_plasmoid_to_panel

# Create /var/lib/pibrick — needed for rotation state tracking and debug logs
mkdir -p /var/lib/pibrick
if [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER:$SUDO_USER" /var/lib/pibrick
else
    chown root:root /var/lib/pibrick
fi

# Install systemd service with user/policy substituted
install_systemd_service() {
    # Resolve the real desktop user so the service runs as the correct UID.
    local autorot_user=""
    if [ -n "${SUDO_USER:-}" ] && [ "$(id -un)" = "root" ]; then
        autorot_user="$SUDO_USER"
    else
        autorot_user=$(loginctl list-sessions --no-legend 2>/dev/null | \
            awk 'NR>0 && $3 != "" && $3 != "root" && $6 != "manager" {print $3; exit}')
        [ -z "$autorot_user" ] && autorot_user=$(who 2>/dev/null | awk '{print $1}' | grep -v '^root$' | head -1)
    fi
    [ -z "$autorot_user" ] && autorot_user="root"

    local autorot_uid
    autorot_uid=$(id -u "$autorot_user" 2>/dev/null)
    if [ -z "$autorot_uid" ]; then
        autorot_uid=1000
    fi
    local autorot_home
    autorot_home=$(getent passwd "$autorot_user" 2>/dev/null | cut -d: -f6)
    autorot_home="${autorot_home:-/home/$autorot_user}"

    # Substitute User, Group, HOME, USER, and UID-specific paths in the service file
    sed -e "s|^User=congn$|User=$autorot_user|" \
        -e "s|^Group=congn$|Group=$autorot_user|" \
        -e "s|Environment=USER=congn$|Environment=USER=$autorot_user|" \
        -e "s|Environment=HOME=/home/congn$|Environment=HOME=$autorot_home|" \
        -e "s|Environment=XDG_RUNTIME_DIR=/run/user/1000$|Environment=XDG_RUNTIME_DIR=/run/user/$autorot_uid|" \
        -e "s|Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus$|Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$autorot_uid/bus|" \
        "$SCRIPT_DIR/pibrick-autorotation.service" \
        > /etc/systemd/system/pibrick-autorotation.service
    chmod 644 /etc/systemd/system/pibrick-autorotation.service
    info "  pibrick-autorotation.service installed (user=$autorot_user uid=$autorot_uid)"
}
install_systemd_service

# ── Disable KWin built-in auto-rotation ────────────────────────────────────────
disable_kwin_auto_rotation() {
    info "Disabling KWin built-in auto-rotation..."

    # Find the active user (the user who owns the Wayland session)
    local active_user
    # Prefer SUDO_USER if set (we're running under sudo), otherwise detect.
    if [ -n "${SUDO_USER:-}" ]; then
        active_user="$SUDO_USER"
    else
        # Try to find a real (non-root) user from loginctl
        active_user=$(loginctl list-sessions --no-legend 2>/dev/null | \
            awk 'NR>1 && $3 != "root" {print $3; exit}')
        [ -z "$active_user" ] && active_user=$(who 2>/dev/null | awk '{print $1}' | grep -v '^root$' | head -1)
    fi
    [ -z "$active_user" ] && active_user="root"

    local home_dir
    home_dir=$(getent passwd "$active_user" 2>/dev/null | cut -d: -f6)
    [ -z "$home_dir" ] && home_dir="/home/$active_user"

    local kwin_config="$home_dir/.config/kwinoutputconfig.json"
    local kwinrc="$home_dir/.config/kwinrc"

    # Fix kwinoutputconfig.json: set autoRotation to "InTabletMode"
    # We want KWin's auto-rotation to work when enabled.
    # Pass the path via env to avoid shell injection into the Python -c body.
    if [ -f "$kwin_config" ]; then
        if grep -q '"autoRotation"' "$kwin_config" 2>/dev/null; then
            if grep -q '"autoRotation": "Always"' "$kwin_config" 2>/dev/null; then
                info "  Setting autoRotation to InTabletMode in kwinoutputconfig.json..."
                KWIN_CONFIG_PATH="$kwin_config" sudo -u "$active_user" python3 -c '
import json, os
path = os.environ["KWIN_CONFIG_PATH"]
with open(path) as f:
    d = json.load(f)
for section in d:
    if section.get("name") == "outputs":
        for output in section.get("data", []):
            if output.get("autoRotation") == "Always":
                output["autoRotation"] = "InTabletMode"
with open(path, "w") as f:
    json.dump(d, f, indent=2)
' && info "  autoRotation set to InTabletMode" || \
                    warn "  Failed to update kwinoutputconfig.json"
            else
                info "  autoRotation already configured"
            fi
        fi
    fi

    # CRITICAL: mask and stop iio-sensor-proxy.service to prevent KWin from using it
    # for built-in auto-rotation.  This conflicts with our custom autorotation service.
    if systemctl is-active --quiet iio-sensor-proxy.service 2>/dev/null || \
       systemctl is-enabled --quiet iio-sensor-proxy.service 2>/dev/null; then
        info "  Stopping and masking iio-sensor-proxy.service..."
        systemctl mask iio-sensor-proxy.service >/dev/null 2>&1 || true
        systemctl stop iio-sensor-proxy.service >/dev/null 2>&1 || true
        info "  iio-sensor-proxy.service stopped and masked"
    else
        info "  iio-sensor-proxy.service already disabled"
    fi

    info "  KWin auto-rotation configured"
}

disable_kwin_auto_rotation

# Reload systemd
systemctl daemon-reload

# Note: SDDM default session is left at distro defaults. The plasma-mobile
# session is available in the wayland-sessions directory and the user can
# pick it at the SDDM greeter on first login. Previously we wrote a
# /etc/sddm.conf.d/zz-pibrick-autorotation.conf to pre-select it; that
# overrode the user's preference and prevented easy switching back to
# another session. Skip it now and let the greeter show the default.

# ── Enable and Start Service ────────────────────────────────────────────────────

info "Enabling autorotation service..."
systemctl enable pibrick-autorotation.service

info "Starting autorotation service..."
if systemctl restart pibrick-autorotation.service; then
    success "Autorotation service started"
else
    warn "Service failed to start - checking logs..."
    journalctl -u pibrick-autorotation.service -n 5 --no-pager || true
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
echo "Services installed:"
echo "  - pibrick-autorotation.service  (system) - Main rotation service"
echo "  - pibrick-rotation-ui.service  (user)   - HTTP API for plasmoid"
echo "  - com.pibrick.Autorotation     (dbus)   - D-Bus IPC interface"
echo "  - SDDM                         (system) - Display manager configured"
echo ""
echo "The service monitors device orientation and rotates the screen automatically."
echo ""
echo "Usage:"
echo "  autorotation-lock [normal|left|right|inverted]  Lock to specific orientation"
echo "  autorotation-lock auto                       Enable auto-rotation"
echo "  pibrick-autorotation-ctl lock <orientation>  Alternative (plasmoid uses this)"
echo ""
echo "Service commands:"
echo "  sudo systemctl start pibrick-autorotation"
echo "  sudo systemctl stop pibrick-autorotation"
echo "  sudo systemctl restart pibrick-autorotation"
echo "  systemctl --user start pibrick-rotation-ui"
echo "  pkill -f pibrick-rotation-ui  # restart UI daemon"
echo "  sudo pibrick-autorotation.sh --status       View status"
echo "  journalctl -u pibrick-autorotation -f       View logs"
echo ""

# Check if reboot needed
if [ -f /boot/firmware/config.txt ]; then
    if grep -q "^dtoverlay=pibrick-mma8451q" /boot/firmware/config.txt 2>/dev/null; then
        if ! grep -q "^dtoverlay=pibrick-mma8451q" /proc/device-tree/aliases/i2c* 2>/dev/null; then
            echo "NOTE: Device tree overlay added. Reboot recommended."
        fi
    fi
fi

echo "Installation complete!"
