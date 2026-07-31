#!/bin/bash
#
# extras/zsh/uninstall.sh — reverses the user-level zsh setup installed
# by install-zsh.sh.
#
#   - Restores the user's login shell to bash (or whatever was previously
#     set in /etc/passwd).
#   - Removes ~/.oh-my-zsh.
#   - Renames ~/.zshrc to ~/.zshrc.pibrick-backup-<timestamp> so the
#     user can recover their previous config; this is non-destructive
#     in case they had custom content.
#
# Runs as the user (drops privileges from the surrounding sudo context).
#
set -euo pipefail

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
    echo "zsh uninstall: could not determine active non-root user; aborting." >&2
    exit 1
fi

user_home="$(getent passwd "$active_user" | cut -d: -f6)"
[ -z "$user_home" ] && user_home="/home/$active_user"

# Drop privileges if we are root.
if [ "$(id -u)" -eq 0 ]; then
    exec sudo -u "$active_user" -H bash "$0" "$@"
fi

ts="$(date +%Y%m%d%H%M%S)"

echo ">>> Restoring login shell to bash for $active_user..."
# Read previous shell from /etc/passwd before we touch it.
prev_shell="$(getent passwd "$active_user" | cut -d: -f7)"
# Prefer bash; fall back to whatever was already in /etc/passwd.
target_shell="/bin/bash"
[ -x "$target_shell" ] || target_shell="/usr/bin/bash"
[ -x "$target_shell" ] || target_shell="$prev_shell"
if [ "$prev_shell" = "$target_shell" ]; then
    echo "    Login shell already $target_shell; nothing to change."
else
    sudo chsh -s "$target_shell" "$active_user" || \
        echo "    (chsh failed; change the default shell manually if you want to leave zsh.)"
fi

if [ -d "$user_home/.oh-my-zsh" ]; then
    echo ">>> Removing $user_home/.oh-my-zsh..."
    rm -rf "$user_home/.oh-my-zsh"
fi

if [ -f "$user_home/.zshrc" ]; then
    backup="$user_home/.zshrc.pibrick-backup-$ts"
    echo ">>> Backing up .zshrc to $(basename "$backup")..."
    mv "$user_home/.zshrc" "$backup"
fi

echo
echo ">>> zsh uninstall finished for $active_user."