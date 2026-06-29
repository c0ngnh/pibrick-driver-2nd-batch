#!/bin/bash
# Control pibrick-backlight (0–1023 on 9203). Used by labwc keybinds on Pi OS Trixie.
set -euo pipefail

BACKLIGHT="/sys/class/backlight/pibrick-backlight/brightness"
MAX_FILE="/sys/class/backlight/pibrick-backlight/max_brightness"
MARKER_BEGIN="# pibrick-brightness-keybinds"
MARKER_END="# /pibrick-brightness-keybinds"

usage() {
	cat <<EOF
Usage: $(basename "$0") up|down|status|set <value>

  up      Increase brightness (~6% of max per step)
  down    Decrease brightness
  status  Print current / max
  set N   Set absolute brightness (clamped to 1..max)
EOF
}

find_backlight() {
	if [ -r "$BACKLIGHT" ] && [ -w "$BACKLIGHT" ]; then
		return 0
	fi
	BACKLIGHT=$(find /sys/class/backlight -name brightness 2>/dev/null | grep pibrick | head -n1 || true)
	MAX_FILE="${BACKLIGHT%/brightness}/max_brightness"
	[ -n "$BACKLIGHT" ] && [ -r "$BACKLIGHT" ] && [ -w "$BACKLIGHT" ]
}

read_max() {
	tr -d '[:space:]' <"$MAX_FILE"
}

read_current() {
	tr -d '[:space:]' <"$BACKLIGHT"
}

write_brightness() {
	local value="$1"
	local max="$2"

	[ "$value" -lt 1 ] && value=1
	[ "$value" -gt "$max" ] && value="$max"
	printf '%s' "$value" >"$BACKLIGHT"
}

adjust_brightness() {
	local delta="$1"
	local current max step new

	max=$(read_max)
	current=$(read_current)
	step=$((max / 16))
	[ "$step" -lt 1 ] && step=1

	new=$((current + delta * step))
	write_brightness "$new" "$max"
}

cmd_up() {
	adjust_brightness 1
}

cmd_down() {
	adjust_brightness -1
}

cmd_status() {
	local current max

	max=$(read_max)
	current=$(read_current)
	echo "${current}/${max}"
}

cmd_set() {
	local value max

	value="$1"
	max=$(read_max)
	write_brightness "$value" "$max"
}

install_labwc_keybinds() {
	local rc_file target tmp
	local -a rc_files=()

	for rc_file in /etc/xdg/labwc/rc.xml; do
		[ -f "$rc_file" ] && rc_files+=("$rc_file")
	done

	for user_home in /home/*; do
		[ -d "$user_home" ] || continue
		rc_file="$user_home/.config/labwc/rc.xml"
		[ -f "$rc_file" ] && rc_files+=("$rc_file")
	done

	if [ -n "${HOME:-}" ] && [ -f "$HOME/.config/labwc/rc.xml" ]; then
		rc_files+=("$HOME/.config/labwc/rc.xml")
	fi

	if [ "${#rc_files[@]}" -eq 0 ]; then
		echo "No labwc rc.xml found (skip keybind install)." >&2
		return 0
	fi

	patch_existing_brightness_keybinds() {
		local rc_file="$1"

		if grep -q 'XF86MonBrightnessUp' "$rc_file"; then
			sed -i \
				-e 's|brightnessctl set +10%|/usr/local/bin/pibrick-brightness up|g' \
				-e 's|brightnessctl set 10%-|/usr/local/bin/pibrick-brightness down|g' \
				-e 's|brightnessctl -e pibrick-backlight set +10%|/usr/local/bin/pibrick-brightness up|g' \
				-e 's|brightnessctl -e pibrick-backlight set 10%-|/usr/local/bin/pibrick-brightness down|g' \
				"$rc_file"
			echo "Updated existing labwc brightness keybinds in $rc_file"
			return 0
		fi

		return 1
	}

	for rc_file in "${rc_files[@]}"; do
		if grep -q "$MARKER_BEGIN" "$rc_file" 2>/dev/null; then
			echo "labwc keybinds already present in $rc_file"
			continue
		fi

		if patch_existing_brightness_keybinds "$rc_file"; then
			continue
		fi

		if ! grep -q '<keyboard>' "$rc_file"; then
			echo "WARNING: no <keyboard> section in $rc_file — add keybinds manually." >&2
			continue
		fi

		tmp=$(mktemp)
		awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
			/<keyboard>/ && !done {
				print
				print "\t" begin
				print "\t<keybind key=\"XF86MonBrightnessUp\">"
				print "\t  <action name=\"Execute\" command=\"/usr/local/bin/pibrick-brightness up\" />"
				print "\t</keybind>"
				print "\t<keybind key=\"XF86MonBrightnessDown\">"
				print "\t  <action name=\"Execute\" command=\"/usr/local/bin/pibrick-brightness down\" />"
				print "\t</keybind>"
				print "\t" end
				done=1
				next
			}
			{ print }
		' "$rc_file" >"$tmp"
		install -m 644 "$tmp" "$rc_file"
		rm -f "$tmp"
		echo "Installed labwc brightness keybinds in $rc_file"
	done

	if command -v labwc >/dev/null 2>&1; then
		labwc --reconfigure 2>/dev/null || true
	fi
}

main() {
	local cmd="${1:-}"

	case "$cmd" in
	up|down|status)
		find_backlight || {
			echo "pibrick-backlight not writable (check udev rules / group membership)" >&2
			exit 1
		}
		;;
	install-labwc)
		install_labwc_keybinds
		return 0
		;;
	""|-h|--help|help)
		usage
		return 0
		;;
	esac

	case "$cmd" in
	up) cmd_up ;;
	down) cmd_down ;;
	status) cmd_status ;;
	set)
		shift
		[ -n "${1:-}" ] || {
			usage >&2
			exit 1
		}
		find_backlight || exit 1
		cmd_set "$1"
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
}

main "$@"
