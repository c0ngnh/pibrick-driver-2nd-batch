#!/bin/bash
#
# extras/zsh/install.sh — entry point invoked by the main install.sh
# (or pibrick-tools --install zsh).
#
# install_zsh.sh refuses to run as root: it manipulates files under $HOME
# (Oh My Zsh, .zshrc, default shell) and those must be owned by the
# interactive user. Our wrapper runs as root (it was invoked via sudo by
# pibrick-tools), so we detect the active user and re-exec the inner
# script under `sudo -u <user>`.
#
# User detection order (matches the rest of the install system):
#   1. SUDO_USER              (set when this script was run via sudo)
#   2. loginctl first non-root (in case the user is on a graphical session)
#   3. who first non-root
#   4. fall back to refusing — we'd rather error than run as root.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER_SCRIPT="$SCRIPT_DIR/install-zsh.sh"

if [ ! -r "$INNER_SCRIPT" ]; then
    echo "install-zsh.sh missing at $INNER_SCRIPT" >&2
    exit 1
fi

# ── Detect the active user ───────────────────────────────────────────────────
detect_active_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return
    fi
    local u
    u=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk 'NR>1 && $3 != "root" {print $3; exit}')
    if [ -n "$u" ]; then
        echo "$u"
        return
    fi
    u=$(who 2>/dev/null | awk '{print $1}' | grep -v '^root$' | head -1)
    if [ -n "$u" ]; then
        echo "$u"
        return
    fi
    return 1
}

active_user="$(detect_active_user || true)"
if [ -z "$active_user" ]; then
    cat >&2 <<EOF
zsh install refused: could not determine the active non-root user.

The zsh installer manipulates files under \$HOME (Oh My Zsh, .zshrc,
default shell) and refuses to run as root. Run this command from an
interactive sudo session so SUDO_USER is set:

  sudo pibrick-tools --install zsh
EOF
    exit 1
fi

user_home="$(getent passwd "$active_user" | cut -d: -f6)"
[ -z "$user_home" ] && user_home="/home/$active_user"

echo ">>> zsh install: running as user '$active_user' (home $user_home)"

# Inner script refuses to run as root. Two strategies:
#   1. If we're already non-root, just exec.
#   2. If we're root, re-exec under `sudo -u <user> bash`.
if [ "$(id -u)" -ne 0 ]; then
    exec bash "$INNER_SCRIPT" "$@"
else
    # Pass the inner script via stdin so we don't need to chmod it world-readable
    # and we don't trigger the "are you root" check until the inner script is
    # already running as the user.
    exec sudo -u "$active_user" -H bash "$INNER_SCRIPT" "$@"
fi