#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# pibrick-desktop - Shared desktop/environment detection library
#
# This library provides functions for detecting the desktop environment,
# Wayland compositor, and session management. It is sourced by other
# piBrick scripts to avoid code duplication.
#
# Usage:
#   source /usr/lib/pibrick/lib-desktop-detection.sh
#
# Functions provided:
#   is_gnome()       - Detect GNOME desktop
#   is_kde()         - Detect KDE Plasma (including Plasma Mobile)
#   is_phosh()       - Detect Phosh mobile environment
#   is_wayland()     - Detect Wayland session
#   is_x11()         - Detect X11 session
#   is_sway()        - Detect Sway compositor
#   is_labwc()       - Detect labwc compositor
#   is_wlroots()     - Detect any wlroots-based compositor
#   get_active_user() - Get the user of the active graphical session
#   get_active_uid()  - Get the UID of the active user
#   run_as_user()    - Run a command as the active user
#   get_phoc_primary_output() - Get Phosh primary output name

# ── Desktop Detection ─────────────────────────────────────────────────────────

# Detect GNOME desktop (including GNOME Shell on Wayland)
is_gnome() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"gnome"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"GNOME"* ]]
}

# Detect KDE Plasma (including Plasma Mobile)
is_kde() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"kde"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] || \
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"Plasma"* ]] || \
    command -v kscreen-doctor >/dev/null 2>&1
}

# Detect Phosh (PureOS, Mobian, etc.)
# Phosh sets PHOSH environment variable and uses phoc compositor
is_phosh() {
    [ -n "${PHOSH:-}" ] && return 0
    [[ "${XDG_CURRENT_DESKTOP:-}" == *"phosh"* ]] && return 0
    command -v phoc >/dev/null 2>&1 && return 0
    [ -d "/usr/share/phosh" ] && return 0
    [ -f "/usr/share/xsessions/phosh.desktop" ] && return 0
    return 1
}

# Check for Wayland display
is_wayland() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 0

    # Also check if we're in a KDE Plasma session (even without WAYLAND_DISPLAY set)
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *"plasma"* ]] || \
       [[ "${XDG_CURRENT_DESKTOP:-}" == *"Plasma"* ]]; then
        return 0
    fi

    # Check for kwin_wayland process
    pgrep -x kwin_wayland >/dev/null 2>&1 && return 0

    return 1
}

# Detect X11 session
is_x11() {
    [ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]
}

# Detect Sway compositor
is_sway() {
    [ -n "${SWAYSOCK:-}" ]
}

# Detect labwc compositor
is_labwc() {
    [ -n "${LABWC_CONFIG:-}" ] || pgrep -x labwc >/dev/null 2>&1
}

# Detect any wlroots-based compositor
is_wlroots() {
    is_sway || is_labwc
}

# ── Session/User Management ───────────────────────────────────────────────────

# Get the user of the active graphical session.
# Returns the username, or empty string if no active session.
get_active_user() {
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

# Get the UID of the active user.
# Returns the UID, or empty string if no active session.
get_active_uid() {
    local user
    user=$(get_active_user)
    if [ -n "$user" ]; then
        id -u "$user" 2>/dev/null
    fi
}

# Run a command as the active user.
# Arguments:
#   $@ - Command and arguments to run
# Returns:
#   Exit code of the command (0 on success)
run_as_user() {
    local user
    user=$(get_active_user)
    if [ -z "$user" ]; then
        return 1
    fi

    local uid
    uid=$(id -u "$user" 2>/dev/null)
    if [ -z "$uid" ]; then
        return 1
    fi

    sudo -u "$user" DISPLAY="${DISPLAY:-:0}" \
         XDG_RUNTIME_DIR="/run/user/$uid" \
         DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
         "$@" 2>/dev/null || return 1
}

# ── Phosh-specific Functions ─────────────────────────────────────────────────

# Get the primary output name from Phosh/phoc.
# Arguments:
#   $1 - Username (optional, defaults to active user)
#   $2 - UID (optional, defaults to active user's UID)
# Returns:
#   The output name, or empty string if not available
get_phoc_primary_output() {
    local user="${1:-$(get_active_user)}"
    local uid="${2:-$(get_active_uid)}"

    if [ -z "$uid" ]; then
        return 1
    fi

    # Try D-Bus via busctl
    if command -v busctl >/dev/null 2>&1; then
        busctl --user --machine="$user" get-property \
            sm.puri.phoc \
            /sm/puri/phoc \
            sm.puri.phoc.Manager \
            PrimaryOutput 2>/dev/null | \
            sed 's/^s "//;s/"$//' || echo ""
    fi
}

# ── D-Bus Helpers ────────────────────────────────────────────────────────────

# Get the D-Bus session address for a user.
# Arguments:
#   $1 - Username (optional, defaults to active user)
# Returns:
#   The D-Bus session address
get_dbus_session_address() {
    local user="${1:-$(get_active_user)}"
    local uid="${2:-$(get_active_uid)}"

    if [ -z "$uid" ]; then
        # Fallback to environment variables
        echo "${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
        return 0
    fi

    echo "unix:path=/run/user/$uid/bus"
}

# ── Utility Functions ────────────────────────────────────────────────────────

# Log a message (wrapper for scripts that use this library)
pibrick_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [pibrick] $*"
}

# Log a warning message
pibrick_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [pibrick] WARN: $*" >&2
}

# Log an error message
pibrick_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [pibrick] ERROR: $*" >&2
}
