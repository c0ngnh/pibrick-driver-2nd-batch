#!/bin/bash
# Persist display refresh (and nudge backlight save) for reboot.

set -euo pipefail

REFRESH_FILE=/etc/pibrick.display-refresh
SETTINGS=/usr/local/bin/pibrick-display-settings

read_live_refresh() {
	local line refresh

	if [ ! -x "$SETTINGS" ]; then
		return 1
	fi

	line=$("$SETTINGS" -s 2>/dev/null | sed -n 's/^Refresh rate  : \([0-9][0-9]*\) Hz.*/\1/p' | head -n1)
	refresh="${line:-}"
	[ -n "$refresh" ] || return 1
	printf '%s\n' "$refresh"
}

save_refresh_preference() {
	local refresh="$1"

	[ -n "$refresh" ] || return 1
	case "$refresh" in
	60|90) ;;
	*)
		return 1
		;;
	esac

	if [ -w "$REFRESH_FILE" ]; then
		printf '%s\n' "$refresh" >"$REFRESH_FILE"
	else
		printf '%s\n' "$refresh" | sudo tee "$REFRESH_FILE" >/dev/null
	fi
}

sync_refresh_from_session() {
	local refresh

	refresh=$(read_live_refresh) || return 1
	save_refresh_preference "$refresh"
}

save_backlight_state() {
	local bl current

	bl=$(find /sys/class/backlight -name brightness 2>/dev/null | grep pibrick | head -n1 || true)
	[ -n "$bl" ] && [ -r "$bl" ] || return 0

	current=$(tr -d '[:space:]' <"$bl")
	[ -n "$current" ] || return 0

	if command -v brightnessctl >/dev/null 2>&1; then
		brightnessctl -e pibrick-backlight set "$current" --save >/dev/null 2>&1 || true
	fi
}

restore_backlight_state() {
	local bl saved

	if command -v brightnessctl >/dev/null 2>&1; then
		brightnessctl -e pibrick-backlight restore >/dev/null 2>&1 && return 0
	fi

	bl=$(find /sys/class/backlight -name brightness 2>/dev/null | grep pibrick | head -n1 || true)
	[ -n "$bl" ] || return 0

	for saved in /var/lib/systemd/backlight/platform-*:pibrick-backlight \
		/var/lib/systemd/backlight/*pibrick-backlight*; do
		[ -r "$saved" ] || continue
		if [ -w "$bl" ]; then
			cat "$saved" >"$bl"
		else
			sudo tee "$bl" <"$saved" >/dev/null
		fi
		return 0
	done
}

case "${1:-}" in
save-refresh)
	save_refresh_preference "${2:-}"
	;;
sync-refresh)
	sync_refresh_from_session
	;;
save-backlight)
	save_backlight_state
	;;
restore-backlight)
	restore_backlight_state
	;;
sync-all)
	sync_refresh_from_session || true
	save_backlight_state || true
	;;
*)
	echo "Usage: $(basename "$0") save-refresh <60|90>|sync-refresh|save-backlight|restore-backlight|sync-all" >&2
	exit 1
	;;
esac
