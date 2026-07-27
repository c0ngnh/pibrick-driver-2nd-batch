#!/bin/bash
#
# pibrick-autorotation - Automatic screen rotation based on MMA8451Q accelerometer
#
# Based on the piBrick AOSP17 V6 implementation by Sconioo.
# https://github.com/Sconioo/pibrick-aosp17/releases/tag/v6
#
# This service reads accelerometer data and rotates the screen based on
# device orientation. Supports both kernel IIO driver and userspace I2C fallback.
#
# Supported desktops:
#   - GNOME (via mutter)
#   - KDE Plasma (via kscreen)
#   - Generic X11 (via xrandr)
#   - Wayland compositors (via wlr-randr for labwc/sway)
#
# Orientation states: normal, left, right, inverted
#
set -euo pipefail

# Configuration
STATE_DIR="/var/lib/pibrick"
ORIENTATION_LOCK_FILE="$STATE_DIR/autorotation.lock"
LOCK_TYPE_FILE="$STATE_DIR/autorotation.lock.type"
SERVICE_NAME="pibrick-autorotation"

# IIO device paths (discovered at runtime)
IIO_DEVICE_PATH=""

# I2C fallback settings
I2C_BUS=1          # I2C1
I2C_ADDR=0x1C      # MMA8451Q I2C address (SA0 floating)
USE_I2C_FALLBACK=0 # Set to 1 if IIO driver not available
I2CGET="sudo /usr/sbin/i2cget"   # Full path for i2c-tools with sudo
I2CSET="sudo /usr/sbin/i2cset"   # Full path for i2c-tools with sudo

# Ensure PATH is set (systemd may have limited PATH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STABLE_DELAY_MS=50           # ms - delay before committing to new orientation
ROTATION_COOLDOWN_MS=200    # ms - minimum time between rotation commands

# Variance filter: DISABLED for maximum responsiveness.
# To re-enable anti-walking filter, set VARIANCE_WINDOW > 1 and
# set VARIANCE_THRESHOLD appropriately for your sensor noise level.
VARIANCE_WINDOW=1           # 1 = disabled (no variance filtering)
VARIANCE_THRESHOLD=5000     # max allowed variance
FLAT_Z_MAG=3500              # |Z| above this → device is flat (ignore auto-rotate)
FLAT_XY_MAX=2200             # when flat, |X| and |Y| must both be below this

# MMA8451Q registers
MMA8451_STATUS=0x00
MMA8451_OUT_X_MSB=0x01
MMA8451_OUT_X_LSB=0x02
MMA8451_OUT_Y_MSB=0x03
MMA8451_OUT_Y_LSB=0x04
MMA8451_OUT_Z_MSB=0x05
MMA8451_OUT_Z_LSB=0x06
MMA8451_XYZ_DATA_CFG=0x0E
MMA8451_CTRL_REG1=0x2A

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$SERVICE_NAME] $*"
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$SERVICE_NAME] WARN: $*" >&2
}

error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$SERVICE_NAME] ERROR: $*" >&2
}

# ── I2C Helpers ─────────────────────────────────────────────────────────────────

i2c_read() {
    local reg=$1
    local value

    if [ ! -e "/dev/i2c-$I2C_BUS" ]; then
        return 1
    fi

    # Use i2c-tools with full path
    if [ -x "$I2CGET" ]; then
        value=$("$I2CGET" -y "$I2C_BUS" "$I2C_ADDR" "$reg" 2>/dev/null || echo "0x00")
        # Convert hex string to decimal number
        value=$((value))
        echo "$value"
    elif command -v python3 >/dev/null 2>&1; then
        # Fallback: use python3 with smbus2
        value=$(python3 -c "
import smbus2
try:
    bus = smbus2.SMBus($I2C_BUS)
    print(bus.read_byte_data($I2C_ADDR, $reg))
    bus.close()
except:
    print(0)
" 2>/dev/null || echo "0")
        echo "$value"
    else
        return 1
    fi
}

i2c_write() {
    local reg=$1
    local value=$2

    if [ ! -e "/dev/i2c-$I2C_BUS" ]; then
        return 1
    fi

    if [ -x "$I2CSET" ]; then
        "$I2CSET" -y "$I2C_BUS" "$I2C_ADDR" "$reg" "$value" 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import smbus2
try:
    bus = smbus2.SMBus($I2C_BUS)
    bus.write_byte_data($I2C_ADDR, $reg, $value)
    bus.close()
except:
    pass
" 2>/dev/null || true
    fi
}

# ── MMA8451Q Userspace Access ──────────────────────────────────────────────────

init_mma8451q() {
    # Initialize MMA8451Q for active mode, 2g range, 100Hz
    # Set standby mode
    i2c_write "$MMA8451_CTRL_REG1" 0x00
    # Set 2g range (0x00 = 2g, 0x01 = 4g, 0x02 = 8g)
    i2c_write "$MMA8451_XYZ_DATA_CFG" 0x00
    # Set active mode, 100Hz ODR (0x00 = 800Hz, 0x01 = 400Hz, ... 0x07 = 1.56Hz)
    # For 100Hz: oversampling 0x00, DR 0x08 -> 0x00 | 0x08 = 0x08
    i2c_write "$MMA8451_CTRL_REG1" 0x01  # 0x01 = active mode, 800Hz (fastest)
    log "MMA8451Q initialized via I2C"
}

check_mma8451q_present() {
    # Try to read WHO_AM_I register (should return 0x1A for MMA8451Q)
    local whoami
    whoami=$(i2c_read 0x0D 2>/dev/null || echo "0")
    # Convert to decimal for comparison
    local decimal=$((whoami))
    # MMA8451Q: 0x1A (26), MMA8452: 0x2A (42), MMA8453: 0x1A (26) or 0x2A (42)
    if [ "$decimal" = "26" ] || [ "$decimal" = "42" ]; then
        log "MMA845x detected (WHO_AM_I=0x${whoami}, decimal=$decimal)"
        return 0
    fi
    warn "MMA8451Q not detected (WHO_AM_I=$whoami, decimal=$decimal, expected 26 or 42)"
    return 1
}

read_mma8451q_raw() {
    # Read X, Y, Z accelerometer values via I2C
    # Returns: "x y z"

    local status x_msb x_lsb y_msb y_lsb z_msb z_lsb
    local x y z

    # Check if data is ready
    status=$(i2c_read "$MMA8451_STATUS" 2>/dev/null || echo "0")
    if [ "$((status & 0x08))" -eq 0 ]; then  # ZYXDR bit not set
        # No new data, return last known values (or 0,0,0)
        echo "0 0 0"
        return
    fi

    # Read MSB and LSB for X, Y, Z
    x_msb=$(i2c_read "$MMA8451_OUT_X_MSB" 2>/dev/null || echo "0")
    x_lsb=$(i2c_read "$MMA8451_OUT_X_LSB" 2>/dev/null || echo "0")
    y_msb=$(i2c_read "$MMA8451_OUT_Y_MSB" 2>/dev/null || echo "0")
    y_lsb=$(i2c_read "$MMA8451_OUT_Y_LSB" 2>/dev/null || echo "0")
    z_msb=$(i2c_read "$MMA8451_OUT_Z_MSB" 2>/dev/null || echo "0")
    z_lsb=$(i2c_read "$MMA8451_OUT_Z_LSB" 2>/dev/null || echo "0")

    # Combine MSB and LSB (12-bit signed values)
    x=$(( (x_msb << 8) | (x_lsb & 0xFF) ))
    y=$(( (y_msb << 8) | (y_lsb & 0xFF) ))
    z=$(( (z_msb << 8) | (z_lsb & 0xFF) ))

    # Sign extend 12-bit to 16-bit
    if [ "$((x & 0x800))" -ne 0 ]; then
        x=$(( x | 0xF000 ))
    fi
    if [ "$((y & 0x800))" -ne 0 ]; then
        y=$(( y | 0xF000 ))
    fi
    if [ "$((z & 0x800))" -ne 0 ]; then
        z=$(( z | 0xF000 ))
    fi

    echo "$x $y $z"
}

# ── IIO Device Discovery ─────────────────────────────────────────────────────────

find_mma8452_device() {
    # Search for MMA8452/MMA8451Q in IIO sysfs
    # The mma8452 driver handles MMA8451, MMA8452, MMA8453 family

    for dev in /sys/bus/iio/devices/iio:device*; do
        [ ! -d "$dev" ] && continue
        [ ! -f "$dev/name" ] && continue

        local name
        name=$(cat "$dev/name" 2>/dev/null || echo "")

        # Match mma8452 or mma8451 family devices
        if [[ "$name" == *"mma845"* ]]; then
            IIO_DEVICE_PATH="$dev"
            log "Found MMA845x device at $dev (name: $name)"
            return 0
        fi
    done

    return 1
}

read_accel_raw() {
    # Read raw accelerometer values
    # Returns: "x y z"

    if [ -n "$IIO_DEVICE_PATH" ] && [ -d "$IIO_DEVICE_PATH" ]; then
        # Use kernel IIO driver
        local x=0 y=0 z=0
        [ -f "$IIO_DEVICE_PATH/in_accel_x_raw" ] && x=$(cat "$IIO_DEVICE_PATH/in_accel_x_raw" 2>/dev/null || echo "0")
        [ -f "$IIO_DEVICE_PATH/in_accel_y_raw" ] && y=$(cat "$IIO_DEVICE_PATH/in_accel_y_raw" 2>/dev/null || echo "0")
        [ -f "$IIO_DEVICE_PATH/in_accel_z_raw" ] && z=$(cat "$IIO_DEVICE_PATH/in_accel_z_raw" 2>/dev/null || echo "0")
        echo "$x $y $z"
    elif [ "$USE_I2C_FALLBACK" = "1" ]; then
        # Use userspace I2C
        read_mma8451q_raw
    else
        return 1
    fi
}

# ── Orientation Detection ───────────────────────────────────────────────────────

detect_orientation() {
    local x=$1 y=$2 z=$3

    # Get absolute values
    local abs_x=${x#-}
    local abs_y=${y#-}
    local abs_z=${z#-}

    # Tolerance / minimum tilt to register a real orientation change.
    # This is the minimum difference between the dominant axis and the second-largest.
    # Portrait-tilted: X=-11856, Y=10376 → diff=1480, needs ≤1500
    # Phone stand: X≈700, Y≈-12000 → diff=1000, X<1200 → still FLAT ✓
    # Walking: X≈5000, Y≈-11000 → passes with 3-sample consistency buffer
    local tilt_threshold=1500

    # Find the dominant axis and how much it dominates the next largest.
    # This cleanly handles the phone-stand case where Y≈Z (nearly tied)
    # and the axes are roughly equal — correctly returns flat instead of portrait.
    local dom=0 dval=0 second=0

    if (( abs_x >= abs_y )) && (( abs_x >= abs_z )); then
        dom=0; dval=abs_x
        second=$(( abs_y > abs_z ? abs_y : abs_z ))
    elif (( abs_y >= abs_x )) && (( abs_y >= abs_z )); then
        dom=1; dval=abs_y
        second=$(( abs_x > abs_z ? abs_x : abs_z ))
    else
        dom=2; dval=abs_z
        second=$(( abs_x > abs_y ? abs_x : abs_y ))
    fi

    # If dominant axis does not clearly exceed the next largest, treat as flat/neutral
    if (( dval - second < tilt_threshold )); then
        return
    fi

    # Also reject purely level (all axes small)
    if (( dval < tilt_threshold )); then
        return
    fi

    # Classify based on dominant axis
    case $dom in
        1) # Y dominant = portrait
            (( y < 0 )) && echo "normal" || echo "inverted"
            ;;
        0) # X dominant = landscape
            (( x > 0 )) && echo "left" || echo "right"
            ;;
        2) # Z dominant = flat
            return
            ;;
    esac
}

# ── Desktop Integration ─────────────────────────────────────────────────────────

is_gnome() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"gnome"* ]] || [[ "${XDG_CURRENT_DESKTOP:-}" == *"GNOME"* ]]
}

is_kde() {
    # Detect KDE Plasma (including Plasma Mobile)
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"kde"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"Plasma"* ]] || \
    command -v kscreen-doctor >/dev/null 2>&1
}

is_wayland() {
    # Check for Wayland display
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
    
    # Also check if we're in a KDE Plasma session (even without WAYLAND_DISPLAY set)
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] || [[ "${XDG_CURRENT_DESKTOP:-}" == *"Plasma"* ]]; then
        return 0
    fi
    
    # Check for kwin_wayland process
    pgrep -x kwin_wayland >/dev/null 2>&1 && return 0
    
    return 1
}

is_x11() {
    [ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]
}

get_active_user() {
    # Get the user of the active session
    loginctl show-session "$(loginctl | grep -E '^\s*c[0-9]+' | head -1 | awk '{print $1}' 2>/dev/null || echo 'c1')" -p User --value 2>/dev/null || \
    who | head -1 | awk '{print $1}'
}

run_as_user() {
    local user=$1
    shift
    local uid
    uid=$(id -u "$user" 2>/dev/null || echo "1000")
    sudo -u "$user" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$uid" "$@" 2>/dev/null || true
}

# ── Rotation Functions ─────────────────────────────────────────────────────────

rotate_gnome() {
    local orientation=$1
    local user
    user=$(get_active_user)
    [ -z "$user" ] && { warn "No active user session"; return 1; }

    local uid=$(id -u "$user" 2>/dev/null || echo "1000")

    # GNOME uses gsettings for orientation lock
    local gsetting_val
    case "$orientation" in
        normal)   gsetting_val="normal" ;;
        left)     gsetting_val="left-up" ;;
        right)    gsetting_val="right-up" ;;
        inverted) gsetting_val="upsidedown" ;;
    esac

    # Try setting via gsettings (GNOME Settings Daemon)
    sudo -u "$user" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$uid" \
        gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock "$gsetting_val" 2>/dev/null || true

    # For GNOME 48+ with mutter, also try via bus
    if command -v busctl >/dev/null 2>&1; then
        local rotation_angle
        case "$orientation" in
            normal)   rotation_angle=0 ;;
            left)     rotation_angle=90 ;;
            right)    rotation_angle=270 ;;
            inverted) rotation_angle=180 ;;
        esac
        # This is a simplified approach - full implementation would use Mutter API
        sudo -u "$user" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$uid" \
            busctl --user call org.gnome.Mutter.DisplayConfig /org/gnome/Mutter/DisplayConfig \
            org.gnome.Mutter.DisplayConfig ApplyMonitorsConfig 'aiavo' 1 "$rotation_angle" 2 2>/dev/null || true
    fi

    log "Applied GNOME rotation: $orientation"
}

rotate_kde() {
    local orientation=$1

    # KDE Plasma (including Plasma Mobile) on Wayland.
    # Uses kscreen-doctor to apply rotation.  kscreen-doctor can be unreliable
    # (may crash, may silently fail to connect to Wayland) so we retry up to
    # MAX_RETRIES times and verify via kwinoutputconfig.json (not kscreen-doctor
    # which crashes in service context).

    if ! command -v kscreen-doctor >/dev/null 2>&1; then
        warn "kscreen-doctor not found - cannot rotate KDE display"
        return 1
    fi

    # Map orientation names to kwinoutputconfig transform values
    local transform_val
    case "$orientation" in
        normal)   transform_val="Normal" ;;
        left)     transform_val="Rotated270" ;;
        right)    transform_val="Rotated90" ;;
        inverted) transform_val="Rotated180" ;;
        *)        warn "Unknown orientation: $orientation"; return 1 ;;
    esac

        local max_retries=5
    local retry_delay=0.1

    for attempt in $(seq 1 $max_retries); do
        # Run kscreen-doctor; it may crash (SIGABRT) but rotation may still apply.
        # Suppress all output to stderr/stdout to reduce noise.
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}" \
        QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}" \
        EGL_PLATFORM="${EGL_PLATFORM:-wayland}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}" \
            kscreen-doctor "output.1.rotation.$orientation" 2>/dev/null
        local exit_code=$?
        trap - ERR

        # Check if kwinoutputconfig.json reflects the new rotation
        sleep 0.1
        local current_transform
        current_transform=$(
            python3 -c "
import json, os
path = os.path.expanduser('~/.config/kwinoutputconfig.json')
try:
    with open(path) as f:
        data = json.load(f)
    for section in data:
        if section.get('name') == 'outputs':
            for out in section.get('data', []):
                if 'transform' in out:
                    print(out['transform'])
                    break
except: pass
" 2>/dev/null || echo ""
        )

        if [ "$current_transform" = "$transform_val" ]; then
            log "Applied KDE rotation: $orientation (attempt $attempt)"
            return 0
        fi

        # Not yet applied — retry
        if [ "$attempt" -lt $max_retries ]; then
            log "kscreen-doctor attempt $attempt (exit $exit_code) not yet applied (transform=$current_transform), retrying..."
            sleep "$retry_delay"
        fi
    done

    warn "Failed to rotate KDE display after $max_retries attempts (transform=$current_transform, expected=$transform_val)"
    return 1
}

rotate_x11() {
    local orientation=$1

    # X11 rotation via xrandr
    local xrandr_rot
    case "$orientation" in
        normal)   xrandr_rot="normal" ;;
        left)     xrandr_rot="left" ;;
        right)    xrandr_rot="right" ;;
        inverted) xrandr_rot="inverted" ;;
    esac

    # Find connected displays and rotate them all
    local display
    display=$(xrandr --listmonitors 2>/dev/null | grep '\*' | head -1 | awk '{print $4}' || echo "")

    if [ -n "$display" ]; then
        xrandr --output "$display" --rotate "$xrandr_rot" 2>/dev/null || true
    else
        # Try all connected outputs
        xrandr 2>/dev/null | grep ' connected' | while read -r line; do
            local output
            output=$(echo "$line" | awk '{print $1}')
            xrandr --output "$output" --rotate "$xrandr_rot" 2>/dev/null || true
        done
    fi

    log "Applied X11 rotation: $orientation"
}

rotate_wayland() {
    local orientation=$1

    # labwc/sway use wlr-randr
    if command -v wlr-randr >/dev/null 2>&1; then
        local rotation
        case "$orientation" in
            normal)   rotation="normal" ;;
            left)     rotation="90" ;;
            right)    rotation="270" ;;
            inverted) rotation="180" ;;
        esac

        wlr-randr 2>/dev/null | grep -E '^[^ ]+' | while read -r output; do
            wlr-randr --output "$output" --transform "$rotation" 2>/dev/null || true
        done
        log "Applied wlr-randr rotation: $orientation"
        return 0
    fi

    # GNOME on Wayland
    if is_gnome && command -v gsettings >/dev/null 2>&1; then
        rotate_gnome "$orientation"
        return $?
    fi

    warn "No supported Wayland compositor rotation method found"
    return 1
}

# ── Rotation Verification ───────────────────────────────────────────────────────

# Query the current screen rotation state from KWin.
# Returns: normal | left | right | inverted | unknown
# Handles kscreen-doctor crashes gracefully (the crash itself means the call was
# processed by KWin before the Qt crash).
get_current_rotation() {
    local rot
    # kscreen-doctor -o output: "    Rotation: <ANSI>1<ANSI><newline>"
    # The ANSI color codes appear before and after the digit.  We strip all
    # ANSI escape sequences (ESC[...m) and then remove whitespace to get e.g.
    # "Rotation:1".  The last digit is always the actual rotation value.
    rot=$(
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}" \
        QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}" \
        EGL_PLATFORM="${EGL_PLATFORM:-wayland}" \
            kscreen-doctor -o 2>/dev/null | \
            grep "Rotation:" | \
            sed 's/'$'\033''\[[0-9;]*m//g' | \
            tr -d ' \t' | \
            grep -o '[0-9]$' || true
    )
    # Do NOT || return 1 — kscreen-doctor may SIGABRT but output is still produced.

    case "$rot" in
        1) echo "normal" ;;
        2) echo "left" ;;
        4) echo "inverted" ;;
        8) echo "right" ;;
        *) echo "unknown" ;;
    esac
}

# ── Rotation Application ─────────────────────────────────────────────────────────

apply_rotation() {
    local orientation=$1

    log "Applying rotation: $orientation"

    if is_gnome; then
        rotate_gnome "$orientation"
    elif is_kde; then
        rotate_kde "$orientation"
    elif is_wayland; then
        rotate_wayland "$orientation"
    elif is_x11; then
        rotate_x11 "$orientation"
    else
        warn "No supported desktop environment detected"
        warn "Detected: XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unknown}, DISPLAY=${DISPLAY:-none}, WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-none}"
        return 1
    fi

    return 0
}

# ── Lock Management ─────────────────────────────────────────────────────────────

is_locked() {
    [ -f "$ORIENTATION_LOCK_FILE" ] && [ -s "$ORIENTATION_LOCK_FILE" ]
}

get_locked_orientation() {
    [ -f "$ORIENTATION_LOCK_FILE" ] && cat "$ORIENTATION_LOCK_FILE" || echo ""
}

# ── Main Service Loop ──────────────────────────────────────────────────────────

main() {
    log "Starting pibrick-autorotation service"
    log "Based on piBrick AOSP17 V6 by Sconioo"

    if [ "$(id -u)" != "0" ] && [ "$(id -u)" != "1000" ]; then
        error "Must be run as root or user congn"
        exit 1
    fi

    # Create state directory (chmod is a no-op when not root)
    mkdir -p "$STATE_DIR"
    [ "$(id -u)" = "0" ] && chmod 755 "$STATE_DIR" 2>/dev/null || true

    # First, try to find kernel IIO driver
    if find_mma8452_device; then
        # Check IIO device is readable
        if [ ! -r "$IIO_DEVICE_PATH/in_accel_x_raw" ]; then
            warn "Cannot read from IIO device $IIO_DEVICE_PATH"
            USE_I2C_FALLBACK=1
        else
            log "Using kernel IIO driver at: $IIO_DEVICE_PATH"
        fi
    else
        warn "MMA845x kernel driver not found"
        USE_I2C_FALLBACK=1
    fi

    # Fall back to userspace I2C if needed
    if [ "$USE_I2C_FALLBACK" = "1" ]; then
        log "Attempting userspace I2C fallback..."
        log "  I2C_BUS=$I2C_BUS, I2C_ADDR=$I2C_ADDR"
        log "  I2CGET=$I2CGET"

        # Check if I2C device is available
        if [ ! -e "/dev/i2c-$I2C_BUS" ]; then
            error "I2C bus /dev/i2c-$I2C_BUS not available"
            error "Load i2c-dev module: sudo modprobe i2c-dev"
            exit 1
        fi
        log "  /dev/i2c-$I2C_BUS exists"

        # Check if i2cget exists and is executable
        local cmd_path
        cmd_path=$(echo "$I2CGET" | awk '{print $1}')  # Get first word (sudo)
        if [ ! -x "$cmd_path" ]; then
            error "i2cget not found at $I2CGET"
            exit 1
        fi
        log "  i2cget found at $I2CGET"

        # Test I2C access
        local whoami_test
        whoami_test=$("$I2CGET" -y "$I2C_BUS" "$I2C_ADDR" 0x0D 2>&1) || whoami_test="ERROR"
        log "  WHO_AM_I test: $whoami_test"

        # Try to detect MMA8451Q
        if check_mma8451q_present; then
            init_mma8451q
            log "Using userspace I2C driver for MMA8451Q"
        else
            error "MMA8451Q accelerometer not found on I2C bus $I2C_BUS at address 0x1C"
            error "Check hardware connections and device tree overlay"
            exit 1
        fi
    fi

    # Main polling loop
    local current_orientation=""
    local pending_orientation=""
    local pending_timestamp=0
    local last_rotation_timestamp=0

    # Startup sync: read actual screen rotation from kwinoutputconfig.json so we don't
    # re-rotate unnecessarily. kscreen-doctor is unreliable in the service context.
    log "Reading current screen rotation..."
    local initial_rot
    initial_rot=$(
        python3 -c "
import json, os, sys
path = os.path.expanduser('~/.config/kwinoutputconfig.json')
try:
    with open(path) as f:
        data = json.load(f)
    for section in data:
        if section.get('name') == 'outputs':
            for out in section.get('data', []):
                if 'transform' in out:
                    t = out['transform']
                    if t == 'Normal': print('normal')
                    elif t == 'Rotated90': print('right')
                    elif t == 'Rotated180': print('inverted')
                    elif t == 'Rotated270': print('left')
                    else: print('unknown')
                    break
except: print('unknown')
" 2>/dev/null || echo "unknown"
    )
    if [ -n "$initial_rot" ] && [ "$initial_rot" != "unknown" ]; then
        current_orientation="$initial_rot"
        log "Startup: screen is at '$current_orientation' — will maintain"
    else
        log "Startup: could not determine screen rotation — will rotate as needed"
    fi

    # orient_buf_size=1 → instant single-sample detection
    local orient_buf_size=1

    # Rolling variance filter: maintain a small buffer of recent X values
    # to detect vibration (walking). If variance is high, skip the sample.
    local var_x=()
    local var_y=()
    local var_z=()
    local flat_count=0

    log "Monitoring orientation changes..."

    while true; do
        # Check for manual lock
        if is_locked; then
            local locked_orient
            locked_orient=$(get_locked_orientation)
            if [ "$locked_orient" != "$current_orientation" ]; then
                apply_rotation "$locked_orient"
                current_orientation="$locked_orient"
            fi
            sleep 0.2
            continue
        fi

        # Read accelerometer
        local accel_data x y z
        accel_data=$(read_accel_raw) || {
            sleep 0.02
            continue
        }

        read -r x y z <<< "$accel_data"

        # Skip if all zeros (no new data)
        if [ "$x" = "0" ] && [ "$y" = "0" ] && [ "$z" = "0" ]; then
            sleep 0.02
            continue
        fi

        # Rolling variance filter: detect walking / vibration
        # If standard deviation of recent X readings is too high, skip sample
        var_x+=("$x")
        var_y+=("$y")
        var_z+=("$z")
        if [ "${#var_x[@]}" -gt "$VARIANCE_WINDOW" ]; then
            var_x=("${var_x[@]:1}")
            var_y=("${var_y[@]:1}")
            var_z=("${var_z[@]:1}")
        fi

        if [ "${#var_x[@]}" -ge "$VARIANCE_WINDOW" ]; then
            local sum_x=0 sum_x2=0
            for v in "${var_x[@]}"; do
                sum_x=$((sum_x + v))
                sum_x2=$((sum_x2 + v * v))
            done
            local mean_x=$((sum_x / VARIANCE_WINDOW))
            local var_n=$((sum_x2 / VARIANCE_WINDOW - mean_x * mean_x))
            if [ "$var_n" -gt "$VARIANCE_THRESHOLD" ]; then
                # High variance → walking / vibration noise; hold orientation
                pending_orientation=""
                sleep 0.02
                continue
            fi
        fi

        # Detect orientation
        local new_orientation
        new_orientation=$(detect_orientation "$x" "$y" "$z")

        # If detect_orientation returns empty (flat/ambiguous), reset the buffer
        if [ -z "$new_orientation" ]; then
            pending_orientation=""
            orient_buf=()
            sleep 0.02
            continue
        fi

        # Add to consistency buffer
        orient_buf+=("$new_orientation")
        if [ "${#orient_buf[@]}" -gt "$orient_buf_size" ]; then
            orient_buf=("${orient_buf[@]:1}")
        fi

        # ── Consistency check ─────────────────────────────────────────────────
        # Require all ORIENTATION_CONSISTENCY (3) samples to agree.
        # If they do, that's a stable orientation. Otherwise keep waiting.
        local all_same=1
        for o in "${orient_buf[@]}"; do
            if [ "$o" != "$new_orientation" ]; then
                all_same=0
                break
            fi
        done

        # If buffer not full yet, just keep accumulating
        if [ "${#orient_buf[@]}" -lt "$orient_buf_size" ]; then
            sleep 0.02
            continue
        fi

        # Buffer is full and all agree
        if [ "$all_same" -eq 0 ]; then
            # Buffer disagrees — sensor noisy or transitioning; reset
            pending_orientation=""
            orient_buf=()
            sleep 0.02
            continue
        fi

        # All buffer entries agree: we have a confirmed new orientation
        if [ "$new_orientation" != "$current_orientation" ]; then
            if [ -z "$pending_orientation" ]; then
                # First confirmation of a new orientation
                pending_orientation="$new_orientation"
                pending_timestamp=$(date +%s%3N)
            fi

            # Check stability time
            local now elapsed
            now=$(date +%s%3N)
            elapsed=$((now - pending_timestamp))

            if (( elapsed >= STABLE_DELAY_MS )); then
                # Check cooldown to avoid spamming kscreen-doctor
                local now_ms elapsed_since_rotation
                now_ms=$(date +%s%3N)
                elapsed_since_rotation=$((now_ms - last_rotation_timestamp))

                if (( elapsed_since_rotation >= ROTATION_COOLDOWN_MS )); then
                    # Apply rotation
                    if apply_rotation "$pending_orientation"; then
                        current_orientation="$pending_orientation"
                        last_rotation_timestamp=$(date +%s%3N)
                        log "Orientation: $pending_orientation (x=$x y=$y z=$z)"
                    fi
                fi
                pending_orientation=""
                orient_buf=()
            fi
        else
            # Same as current — clear pending
            pending_orientation=""
            orient_buf=()
        fi

        sleep 0.02  # 20ms polling interval — snappy responsiveness
    done
}

# ── CLI Interface ──────────────────────────────────────────────────────────────

show_status() {
    echo "=== pibrick-autorotation status ==="
    echo ""

    if systemctl is-active --quiet pibrick-autorotation.service 2>/dev/null; then
        echo "Service: running"
    else
        echo "Service: stopped"
    fi

    # Check IIO
    if find_mma8452_device 2>/dev/null; then
        echo "Driver: kernel IIO at $IIO_DEVICE_PATH"
        echo -n "Accelerometer: "
        read_accel_raw || echo "error reading"
    elif [ -e "/dev/i2c-$I2C_BUS" ]; then
        echo "Driver: userspace I2C fallback"
        echo -n "MMA8451Q: "
        check_mma8451q_present && echo "detected" || echo "not detected"
    else
        echo "No MMA8451Q driver available"
    fi

    echo ""
    if is_locked; then
        echo "Lock: enabled ($(get_locked_orientation))"
    else
        echo "Lock: disabled (auto-rotation)"
    fi
}

case "${1:-}" in
    --status)
        show_status
        ;;
    --help|-h)
        echo "pibrick-autorotation - Automatic screen rotation service"
        echo ""
        echo "Usage:"
        echo "  pibrick-autorotation          Start the rotation service"
        echo "  pibrick-autorotation --status Show service status"
        echo "  pibrick-autorotation --help   Show this help"
        ;;
    *)
        main
        ;;
esac
