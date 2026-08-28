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
#   - Phosh (via wlr-randr or phoc D-Bus)
#
# Orientation states: normal, left, right, inverted
#
set -euo pipefail

# Source shared desktop detection library
LIB_FILE="/usr/lib/pibrick/lib-desktop-detection.sh"
if [ -f "$LIB_FILE" ]; then
    # shellcheck source=/dev/null
    source "$LIB_FILE"
else
    # Inline fallback if library not installed yet (development)
    is_gnome() {
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"gnome"* ]] || [[ "${XDG_CURRENT_DESKTOP:-}" == *"GNOME"* ]]
    }
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
    is_wayland() {
        [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
        [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] && return 0
        pgrep -x kwin_wayland >/dev/null 2>&1 && return 0
        return 1
    }
    is_x11() {
        [ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]
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
    run_as_user() {
        local user=$1
        shift
        local uid
        uid=$(id -u "$user" 2>/dev/null)
        if [ -z "$uid" ]; then
            warn "run_as_user: cannot resolve UID for '$user', skipping"
            return 1
        fi
        sudo -u "$user" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$uid" "$@" 2>/dev/null || true
    }
fi

# ── Configuration ────────────────────────────────────────────────────────────────
# Load configuration from /etc/pibrick/autorotation.conf if it exists
# This allows overriding I2C bus, address, and other settings without editing the script
CONFIG_FILE="/etc/pibrick/autorotation.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

STATE_DIR="/var/lib/pibrick"
ORIENTATION_LOCK_FILE="$STATE_DIR/autorotation.lock"
LOCK_TYPE_FILE="$STATE_DIR/autorotation.lock.type"
SERVICE_NAME="pibrick-autorotation"

# IIO device paths (discovered at runtime)
IIO_DEVICE_PATH=""

# I2C fallback settings (can be overridden by /etc/pibrick/autorotation.conf)
# Default: MMA8451Q on I2C1 at address 0x1C
I2C_BUS="${I2C_BUS:-1}"           # I2C bus number
I2C_ADDR="${I2C_ADDR:-0x1C}"       # MMA8451Q I2C address (SA0 floating)
USE_I2C_FALLBACK="${USE_I2C_FALLBACK:-0}"  # Set to 1 if IIO driver not available
I2CGET="sudo /usr/sbin/i2cget"     # Full path for i2c-tools with sudo
I2CSET="sudo /usr/sbin/i2cset"    # Full path for i2c-tools with sudo

# Ensure PATH is set (systemd may have limited PATH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STABLE_DELAY_MS=50           # ms - delay before committing to new orientation
ROTATION_COOLDOWN_MS=400    # ms - minimum time between rotation commands
                                # Set high enough that the sensor settles before next detection fires

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

    # Prefer Python/smbus2 (works in more constrained environments than i2c-tools).
    # i2c-tools may fail with "Operation not permitted" in systemd/cgroup-isolated
    # contexts even when the user is in the i2c group or has CAP_SYS_RAWIO.
    if command -v python3 >/dev/null 2>&1 && python3 -c "import smbus2" 2>/dev/null; then
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
    elif [ -x "$I2CGET" ]; then
        # Fallback: use i2c-tools with full path
        value=$("$I2CGET" -y "$I2C_BUS" "$I2C_ADDR" "$reg" 2>/dev/null || echo "0x00")
        # Convert hex string to decimal number
        value=$((value))
        echo "$value"
    else
        return 1
    fi
}

# Batch I2C read: reads all 6 accelerometer bytes + status in one atomic
# Python subprocess call and returns them as "x y z" (space-separated signed ints).
# The sign extension is done in Python to avoid bash arithmetic issues.
#
# Calling Python once per byte is slow AND causes a race: between separate
# `i2c_read X_MSB` and `i2c_read X_LSB` calls the sensor may produce new
# data, so we get the old MSB but new LSB — creating inconsistent readings.
i2c_read_all() {
    python3 -c "
import smbus2

def sign12(v):
    if v & 0x800:
        return v - 0x1000
    return v

try:
    bus = smbus2.SMBus($I2C_BUS)
    addr = $I2C_ADDR
    status = bus.read_byte_data(addr, 0x00)
    x_msb  = bus.read_byte_data(addr, 0x01)
    x_lsb  = bus.read_byte_data(addr, 0x02)
    y_msb  = bus.read_byte_data(addr, 0x03)
    y_lsb  = bus.read_byte_data(addr, 0x04)
    z_msb  = bus.read_byte_data(addr, 0x05)
    z_lsb  = bus.read_byte_data(addr, 0x06)
    bus.close()

    # 12-bit to 16-bit sign extension
    x = sign12((x_msb << 8) | x_lsb)
    y = sign12((y_msb << 8) | y_lsb)
    z = sign12((z_msb << 8) | z_lsb)

    # Return status (for ZYXDR check) and x y z as space-separated values.
    print(f'{status} {x} {y} {z}')
except Exception:
    print('0 0 0 0')
" 2>/dev/null || echo "0 0 0 0"
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
    # Set standby mode first (required before changing settings)
    i2c_write "$MMA8451_CTRL_REG1" 0x00
    # Set 2g range (0x00 = 2g, 0x01 = 4g, 0x02 = 8g)
    i2c_write "$MMA8451_XYZ_DATA_CFG" 0x00
    # Set active mode, 100Hz output data rate
    # CTRL_REG1: bit 0 = Active (1=on), bits [2:0] = DR
    # DR=011 (0x03) = 100Hz, so value = 0x03 | 0x01 = 0x03
    i2c_write "$MMA8451_CTRL_REG1" 0x03
    log "MMA8451Q initialized via I2C (100Hz, 2g range)"
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

    # Use the batch atomic read (single Python subprocess) to avoid race
    # conditions between separate reads.
    local raw
    raw=$(i2c_read_all) || {
        echo "0 0 0"
        return
    }

    # Parse: "status x y z"
    local status x y z
    read -r status x y z <<< "$raw"

    # Check if data is ready
    if [ -z "$status" ] || [ "$status" = "0" ] || [ "$status" = "" ]; then
        echo "0 0 0"
        return
    fi

    if [ "$((status & 0x08))" -eq 0 ]; then  # ZYXDR bit not set
        echo "0 0 0"
        return
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

    # Chip: MMA8451Q in 2g high-resolution mode, ±16384 = 1g.
    # PocketCM5 axis mount (calibrated empirically):
    #
    #   Portrait USB-bottom (normal):   y ≈ -16000  (|y| >> |x|,|z|)
    #   Portrait USB-top   (inverted): y ≈ +16200  (|y| >> |x|,|z|)
    #   Landscape USB-right (left):     x ≈ -16150  (|x| >> |y|,|z|)
    #   Landscape USB-left  (right):    x ≈ +16060  (|x| >> |y|,|z|)
    #   Flat (any face):              |z| dominates  (|z| >> |x|,|z|)
    #
    # Threshold and dominance margin are defined below.  See the rationale
    # comment above the `local THRESHOLD=...` line for why these specific
    # values were chosen.
    #
    # Algorithm: find the dominant (largest |value|) axis, then use its sign.
    # This correctly handles portrait (Y-dominant) vs landscape (X-dominant)
    # without needing a 2x2 magnitude matrix.

    # Threshold: 12000 = ~0.73g.  This is the boundary between "noise on a still
    # accelerometer" and "gravity is clearly along this axis".  At rest the
    # dominant axis reads ~14800-16200 and the perpendicular axes read ~0-3000.
    # Setting the threshold high enough that random noise on the non-dominant
    # axis can't push it past the dominant axis is critical — otherwise the
    # device "rotates randomly" while held still.
    #
    # We also require a DOMINANCE MARGIN: the chosen axis must exceed the
    # second-largest axis by at least DOMINANCE_MARGIN.  This prevents 45°
    # transitions from being committed too early.
    local THRESHOLD=12000
    local DOMINANCE_MARGIN=6000  # ~0.37g — chosen axis must beat runner-up by this much

    # ── Flat detection ────────────────────────────────────────────────────────
    # If gravity is primarily along Z (device lying flat face-up or face-down),
    # we ignore the orientation — no rotation needed.
    if (( abs_z > THRESHOLD )) && (( abs_z > abs_x + DOMINANCE_MARGIN )) && (( abs_z > abs_y + DOMINANCE_MARGIN )); then
        # Device is flat on a surface.  Return empty so the caller resets the
        # pending buffer and waits for a non-flat pose.
        return 0
    fi

    # ── Portrait orientations (Y axis dominant) ────────────────────────────────
    if (( abs_y > THRESHOLD )) && (( abs_y > abs_x + DOMINANCE_MARGIN )) && (( abs_y > abs_z + DOMINANCE_MARGIN )); then
        if (( y < 0 )); then
            # Y negative → gravity along +Y in chip frame → Y axis points DOWN
            # → device is portrait, USB at bottom → normal
            echo "normal"
        else
            # Y positive → gravity along -Y → device is upside-down
            echo "inverted"
        fi
        return 0
    fi

    # ── Landscape orientations (X axis dominant) ──────────────────────────────
    if (( abs_x > THRESHOLD )) && (( abs_x > abs_y + DOMINANCE_MARGIN )) && (( abs_x > abs_z + DOMINANCE_MARGIN )); then
        if (( x < 0 )); then
            # X negative → gravity along +X → USB on RIGHT side → left
            echo "left"
        else
            # X positive → gravity along -X → USB on LEFT side → right
            echo "right"
        fi
        return 0
    fi

    # Ambiguous / not settled: dominant-axis not enough to commit.  Reset the
    # pending buffer and wait for a clear sample.
    return 0
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

is_phosh() {
    # Detect Phosh (PureOS, Mobian, etc.)
    # Phosh sets PHOSH environment variable and uses phoc compositor
    [ -n "${PHOSH:-}" ] && return 0
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"phosh"* ]] && return 0
    command -v phoc >/dev/null 2>&1 && return 0
    # Also check for phosh-specific indicators
    [ -d "/usr/share/phosh" ] && return 0
    [ -f "/usr/share/xsessions/phosh.desktop" ] && return 0
    return 1
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
    # Get the user of the active graphical session.
    # loginctl list-sessions columns: SESSION UID USER SEAT PID TYPE TTY REMOTE ACTIVE
    # Skip the 'manager' session (no user) and any root session; pick the first user session.
    local session
    session=$(loginctl list-sessions --no-legend 2>/dev/null | \
        awk '$3 != "" && $3 != "root" && $6 != "manager" {print $1; exit}')
    if [ -n "$session" ]; then
        loginctl show-session "$session" -p User --value 2>/dev/null && return 0
    fi
    # Fallback: first non-root user from who(1)
    who 2>/dev/null | awk '$1 != "root" {print $1; exit}'
}

run_as_user() {
    local user=$1
    shift
    local uid
    uid=$(id -u "$user" 2>/dev/null)
    if [ -z "$uid" ]; then
        warn "run_as_user: cannot resolve UID for '$user', skipping"
        return 1
    fi
    sudo -u "$user" DISPLAY="${DISPLAY:-:0}" XDG_RUNTIME_DIR="/run/user/$uid" "$@" 2>/dev/null || true
}

# ── Rotation Functions ─────────────────────────────────────────────────────────

rotate_gnome() {
    local orientation=$1
    local user
    user=$(get_active_user)
    [ -z "$user" ] && { warn "No active user session"; return 1; }

    local uid
    uid=$(id -u "$user" 2>/dev/null)
    if [ -z "$uid" ]; then
        warn "rotate_gnome: cannot resolve UID for '$user', aborting"
        return 1
    fi

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

# ── Phosh/Phoc Rotation ───────────────────────────────────────────────────────
#
# Phosh uses phoc compositor which is a wlroots-based compositor.
# Phoc exposes screen rotation through D-Bus properties and accepts
# rotation commands via wlr-randr-compatible interface.
#
# Key differences from KDE:
# - No kscreen-doctor or kscreen libraries
# - Uses wlr-randr for rotation commands
# - Rotation state stored in phoc's session D-Bus interface
# - Lock state tracked via our own lock file (not phoc's config)

rotate_phosh() {
    local orientation=$1

    # Get active user for running commands as user
    local user
    user=$(get_active_user)
    [ -z "$user" ] && { warn "No active user session"; return 1; }

    local uid
    uid=$(id -u "$user" 2>/dev/null)
    [ -z "$uid" ] && { warn "rotate_phosh: cannot resolve UID for '$user'"; return 1; }

    # Get the primary output name from phoc
    # Phoc typically has a primary output that we need to rotate
    local output=""
    local xdg_runtime="/run/user/$uid"

    # Method 1: Use wlr-randr if available (phoc supports this)
    if command -v wlr-randr >/dev/null 2>&1; then
        # Get list of outputs and rotate the first one
        local transform
        case "$orientation" in
            normal)   transform="normal" ;;
            left)    transform="90" ;;
            right)   transform="270" ;;
            inverted) transform="180" ;;
            *)       warn "Unknown orientation: $orientation"; return 1 ;;
        esac

        # Try to get the primary output from phoc D-Bus
        local phoc_output
        if command -v busctl >/dev/null 2>&1; then
            phoc_output=$(busctl --user get-property \
                sm.puri.phoc \
                /sm/puri/phoc \
                sm.puri.phoc.Manager \
                PrimaryOutput 2>/dev/null || echo "")
        fi

        # If we got a valid output name from phoc, use it
        if [ -n "$phoc_output" ]; then
            # busctl returns s "<output-name>", extract the name
            output=$(echo "$phoc_output" | sed 's/^s "//;s/"$//')
        fi

        # Apply rotation using wlr-randr
        if [ -n "$output" ]; then
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            XDG_RUNTIME_DIR="$xdg_runtime" \
                wlr-randr --output "$output" --transform "$transform" 2>/dev/null || true
        else
            # Fallback: apply to all outputs
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            XDG_RUNTIME_DIR="$xdg_runtime" \
                wlr-randr 2>/dev/null | grep -E '^[^ ]+' | while read -r line; do
                WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                XDG_RUNTIME_DIR="$xdg_runtime" \
                    wlr-randr --output "$line" --transform "$transform" 2>/dev/null || true
            done
        fi
        log "Applied Phosh rotation via wlr-randr: $orientation"
        return 0
    fi

    # Method 2: Use phoc's D-Bus interface directly
    if command -v busctl >/dev/null 2>&1; then
        # Get rotation value for phoc (0=normal, 90=left, 180=inverted, 270=right)
        local phoc_rot
        case "$orientation" in
            normal)   phoc_rot=0 ;;
            left)    phoc_rot=90 ;;
            right)   phoc_rot=270 ;;
            inverted) phoc_rot=180 ;;
        esac

        # Try to set rotation via phoc D-Bus
        # phoc exposes: sm.puri.phoc.Manager.RotateOutput method
        busctl --user call \
            sm.puri.phoc \
            /sm/puri/phoc \
            sm.puri.phoc.Manager \
            RotateOutput 'sui' '' 1 "$phoc_rot" 2>/dev/null || true

        log "Applied Phosh rotation via D-Bus: $orientation"
        return 0
    fi

    warn "No rotation method available for Phosh (needs wlr-randr or busctl)"
    return 1
}

rotate_kde() {
    local orientation=$1

    # KDE Plasma (including Plasma Mobile) on Wayland.
    # Uses kscreen-doctor to apply rotation, then verifies via kscreen-doctor -j.
    # If KWin is not running (e.g. early boot before user logs in), kscreen-doctor
    # produces no useful output and we propagate the failure so the main loop retries.

    if ! command -v kscreen-doctor >/dev/null 2>&1; then
        warn "kscreen-doctor not found - cannot rotate KDE display"
        return 1
    fi

    # PocketCM5 axis mount (from empirical calibration):
    #   portrait: Y dominant, landscape: X dominant.
    #   left  = landscape, USB on RIGHT -> kscreen "right"  (rotated 90 CW from normal)
    #   right = landscape, USB on LEFT  -> kscreen "left"   (rotated 90 CCW from normal)
    local kscreen_orientation
    case "$orientation" in
        normal)   kscreen_orientation="normal" ;;
        left)     kscreen_orientation="right" ;;
        right)    kscreen_orientation="left" ;;
        inverted) kscreen_orientation="inverted" ;;
        *)        warn "Unknown orientation: $orientation"; return 1 ;;
    esac

    # kscreen-doctor needs these env vars or it falls back to xcb and crashes.
    # Export rather than building an eval-string, to avoid quoting bugs.
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
    export EGL_PLATFORM="${EGL_PLATFORM:-wayland}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

    # Try up to 2 times: once immediately, once after a short pause.
    local attempt kscreen_stderr
    for attempt in 1 2; do
        # kscreen-doctor prints error messages to stderr.  Rotation commands
        # produce no stdout on success.  Run it once and capture stderr.
        kscreen_stderr=$(kscreen-doctor "output.1.rotation.$kscreen_orientation" 2>&1 >/dev/null | head -5)

        if [ -n "$kscreen_stderr" ]; then
            if [ "$attempt" -eq 1 ]; then
                warn "kscreen-doctor attempt $attempt failed: $kscreen_stderr, retrying in 0.5s"
                sleep 0.5
                continue
            else
                warn "kscreen-doctor failed after 2 attempts: $kscreen_stderr"
                return 1
            fi
        fi

        # Verify: read back current rotation via kscreen-doctor -j.
        local json
        json=$(timeout 3 kscreen-doctor -j 2>/dev/null || echo "")
        if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
            local current_kscreen
            current_kscreen=$(echo "$json" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
outputs = d.get('outputs', [])
primary = next((o for o in outputs if o.get('enabled')), outputs[0] if outputs else None)
if not primary:
    sys.exit(1)
# kscreen rotation values are bit flags:
#   1 = normal (0°)
#   2 = left (90° CCW)
#   4 = inverted (180°)
#   8 = right (90° CW)
inv = {1: 'normal', 2: 'left', 4: 'inverted', 8: 'right'}
print(inv.get(primary.get('rotation', 1), 'unknown'))
" 2>/dev/null || echo "unknown")

            if [ "$current_kscreen" = "$orientation" ]; then
                log "Applied KDE rotation: $orientation (verified via kscreen-doctor -j)"
                return 0
            else
                warn "kscreen-doctor output seen, but KWin reports rotation '$current_kscreen' (expected '$orientation')"
                log "Applied KDE rotation: $orientation (kscreen mismatch, trusting kscreen-doctor)"
                return 0
            fi
        else
            # No JSON verification possible.
            log "Applied KDE rotation: $orientation (kscreen $kscreen_orientation, no verification)"
            return 0
        fi
    done
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
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
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

# Print the orientation the screen is currently in: normal | left | right | inverted
# Falls back to "normal" if no supported desktop tool is available.
get_current_orientation() {
    # Try kscreen-doctor -j (KDE Plasma / Plasma Mobile).
    # Wrap in a 3-second timeout because Qt can hang trying to init a display
    # when called outside a proper user session (e.g. from SSH).
    if command -v kscreen-doctor >/dev/null 2>&1; then
        local json
        json=$(WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
               XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
               timeout 3 kscreen-doctor -j 2>/dev/null) || true
        if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
            python3 - "$json" <<'PY' 2>/dev/null && return
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
outputs = d.get("outputs", [])
# Prefer the enabled primary output.
primary = next((o for o in outputs if o.get("primary")), None) or \
          next((o for o in outputs if o.get("enabled")), None) or \
          (outputs[0] if outputs else None)
if not primary:
    sys.exit(1)
r = primary.get("rotation", 1)
# kscreen uses 0=0°, 1=90° (normal on a portrait panel), 2=180°, 3=270°
name = {0: "normal", 1: "normal", 2: "inverted", 3: "left"}
# Our orientation names assume a 90°-rotated portrait panel:
#   normal = 1, right = 1+90° rotated in our terms = ks 0/2, etc.
# kscreen-doctor's output.<name>.rotation.<orientation> mapping is:
#   "normal" -> 1, "right" -> 0, "inverted" -> 3, "left" -> 2
# So invert that mapping here:
inv = {1: "normal", 0: "right", 3: "inverted", 2: "left"}
print(inv.get(r, "normal"))
sys.exit(0)
PY
        fi
    fi
    # Fallback: wlr-randr (labwc/sway, and Phosh via phoc).
    # Phosh uses phoc which is wlroots-based, so wlr-randr works on Phosh too.
    if command -v wlr-randr >/dev/null 2>&1; then
        local rot
        rot=$(WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
              XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
              timeout 3 wlr-randr 2>/dev/null | awk '/Transform:/ {print $2; exit}')
        case "$rot" in
            normal|0)   echo "normal"   ; return ;;
            90|right)   echo "right"    ; return ;;
            180|inverted) echo "inverted" ; return ;;
            270|left)   echo "left"     ; return ;;
        esac
    fi
    # Fallback: try phoc D-Bus directly for Phosh
    if is_phosh && command -v busctl >/dev/null 2>&1; then
        local user uid phoc_rot
        user=$(get_active_user 2>/dev/null || echo "")
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        if [ -n "$user" ] && [ "$uid" != "" ]; then
            # Get current rotation from phoc
            # phoc uses: sm.puri.phoc /sm/puri/phoc Manager GetScreenRotation (returns i)
            phoc_rot=$(timeout 3 busctl --user --machine="$user" get-property \
                sm.puri.phoc /sm/puri/phoc \
                sm.puri.phoc.Manager GetScreenRotation 2>/dev/null | \
                awk '{print $2}' || echo "")
            case "$phoc_rot" in
                0) echo "normal"   ; return ;;
                90) echo "right"   ; return ;;
                180) echo "inverted" ; return ;;
                270) echo "left"    ; return ;;
            esac
        fi
    fi
    # Final fallback: assume portrait.
    echo "normal"
}

apply_rotation() {
    local orientation=$1

    log "Applying rotation: $orientation"

    if is_phosh; then
        rotate_phosh "$orientation"
    elif is_gnome; then
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

    if [ "$(id -u)" != "0" ] && [ "$(id -u)" -gt 1000 ] 2>/dev/null; then
        error "Must be run as root or a regular user (UID > 1000)"
        exit 1
    fi

    # Create state directory (chmod is a no-op when not root)
    mkdir -p "$STATE_DIR"
    [ "$(id -u)" = "0" ] && chmod 755 "$STATE_DIR" 2>/dev/null || true

    # Wait for kwin_wayland to be up before polling the accelerometer.
    # Without this, kscreen-doctor calls at boot race with the compositor startup
    # and produce SIGABRT failures that the old code treated as success.
    # Poll for up to 90s so the service still starts on non-Plasma systems.
    # NOTE: pgrep -q is not available on all procps versions; use /dev/null redirect.
    if ! pgrep -x kwin_wayland >/dev/null 2>&1; then
        log "Waiting for kwin_wayland (up to 90s)..."
        local waited=0
        while [ "$waited" -lt 90 ]; do
            sleep 1
            waited=$((waited + 1))
            pgrep -x kwin_wayland >/dev/null 2>&1 && break
        done
        if pgrep -x kwin_wayland >/dev/null 2>&1; then
            log "kwin_wayland detected after ${waited}s - starting rotation loop"
        else
            log "kwin_wayland not found after 90s - starting rotation loop anyway"
        fi
    fi

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

        # Check if I2C device is available
        if [ ! -e "/dev/i2c-$I2C_BUS" ]; then
            error "I2C bus /dev/i2c-$I2C_BUS not available"
            error "Load i2c-dev module: sudo modprobe i2c-dev"
            exit 1
        fi
        log "  /dev/i2c-$I2C_BUS exists"

        # Prefer Python/smbus2 (works in more constrained environments).
        # Check availability first.
        local i2c_backend="i2c-tools"
        if command -v python3 >/dev/null 2>&1 && python3 -c "import smbus2" 2>/dev/null; then
            i2c_backend="python-smbus2"
            log "  Using Python/smbus2 for I2C access"
        elif [ -x "$I2CGET" ]; then
            log "  i2cget found: $I2CGET"
        else
            error "Neither Python smbus2 nor i2c-tools found"
            exit 1
        fi

        # Test I2C access
        local whoami_test
        if [ "$i2c_backend" = "python-smbus2" ]; then
            whoami_test=$(python3 -c "
import smbus2
try:
    bus = smbus2.SMBus($I2C_BUS)
    print(hex(bus.read_byte_data($I2C_ADDR, 0x0D)))
    bus.close()
except Exception as e:
    print('ERROR:' + str(e))
" 2>/dev/null || echo "ERROR")
        else
            whoami_test=$("$I2CGET" -y "$I2C_BUS" "$I2C_ADDR" 0x0D 2>&1) || whoami_test="ERROR"
        fi
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
    local last_rotated_to=""  # GUARD: ignore re-detecting the same orientation we just rotated to.

    # No startup sync from kwinoutputconfig.json — the file is whatever the screen
    # was last left at, NOT what the sensor says is correct now. Trusting it leads
    # to a visible flip 1-2s after boot whenever the file's stored rotation doesn't
    # match the user's actual orientation (e.g. they held the device still while
    # the prior session left the screen rotated, then rebooted). Instead, let the
    # sensor drive the first rotation. Buffer-fills in ~100ms, with a single
    # one-time flicker to the correct orientation.
    log "Startup: trusting accelerometer for first orientation"
    current_orientation=""

    # orient_buf_size=5 → 5 consecutive samples must agree before committing rotation.
    # This filters out single-sample sensor noise and prevents rapid bouncing when
    # the dominant axis is borderline (e.g. abs_x≈abs_z).
    local orient_buf_size=5
    local orient_buf=()

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
        # GUARD: If we already have a pending orientation that was applied (and the
        # cooldown cleared it), don't re-trigger the same orientation. Without this
        # check, re-reading the same orientation as current caused unnecessary
        # redundant rotation calls → bounce-back on transition completion.
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
                    # GUARD: if we rotated to this same orientation within the cooldown
                    # window, skip — the screen is already there and the sensor is still
                    # settling. Without this, the next few samples of the same orientation
                    # each pass the stability timer and trigger redundant rotations.
                    if [ "$pending_orientation" = "$last_rotated_to" ]; then
                        pending_orientation=""
                        orient_buf=()
                        continue
                    fi

                    # Apply rotation
                    if apply_rotation "$pending_orientation"; then
                        current_orientation="$pending_orientation"
                        last_rotation_timestamp=$(date +%s%3N)
                        last_rotated_to="$pending_orientation"
                        log "Orientation: $pending_orientation (x=$x y=$y z=$z)"
                    fi
                fi
                pending_orientation=""
                orient_buf=()
            fi
        else
            # Same as current — clear pending (no re-application)
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
    --apply-rotation)
        # Called by autorotation-lock.sh to apply a rotation immediately
        # (used when the user manually locks from the quick setting)
        apply_rotation "${2:-normal}"
        ;;
    --status)
        show_status
        ;;
    --current-orientation)
        # Used by autorotation-lock lock-current to figure out what the
        # screen is currently displaying so a tap on the Plasma Mobile
        # Quick Drawer tile can lock the orientation without rotating.
        get_current_orientation
        ;;
    --help|-h)
        echo "pibrick-autorotation - Automatic screen rotation service"
        echo ""
        echo "Usage:"
        echo "  pibrick-autorotation               Start the rotation service"
        echo "  pibrick-autorotation --apply-rotation <ori>   Apply rotation immediately"
        echo "  pibrick-autorotation --current-orientation    Print the current orientation"
        echo "  pibrick-autorotation --status      Show service status"
        echo "  pibrick-autorotation --help        Show this help"
        ;;
    *)
        main
        ;;
esac
