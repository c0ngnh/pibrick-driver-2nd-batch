#!/bin/bash
# Interactive piBrick AMOLED settings: color profile (sysfs) and refresh rate (DRM).

set -euo pipefail

PANEL_WIDTH=1080
PANEL_HEIGHT=1240
PANEL_MODE="${PANEL_WIDTH}x${PANEL_HEIGHT}"

COLOR_PROFILES=(natural vivid srgb warm cool night soft)
REFRESH_RATES=(90 60)

PIBRICK_PANEL="9203"
if [ -r /etc/pibrick.panel ]; then
	PIBRICK_PANEL=$(tr -d '[:space:]' </etc/pibrick.panel)
fi

case "$PIBRICK_PANEL" in
9202|548)
	REFRESH_RATES=(60)
	PANEL_MODES_LABEL="60 @ ${PANEL_MODE}"
	;;
*)
	PANEL_MODES_LABEL="90 / 60 @ ${PANEL_MODE}"
	;;
esac

color_profile_node=""
display_output=""
display_tool=""
panel_mode="$PANEL_MODE"
session_user=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --help              Show this help
  -s, --status            Print current profile and refresh rate, then exit
  -p, --profile NAME      Set color profile (non-interactive)
  -r, --refresh HZ        Set refresh rate to 60 or 90 (non-interactive)

Color profiles: ${COLOR_PROFILES[*]}
Refresh rates:  ${REFRESH_RATES[*]} Hz @ ${PANEL_MODE}
EOF
}

find_color_profile_node() {
	find /sys -name color_profile 2>/dev/null | grep dsi | head -n1 || true
}

read_color_profile() {
	local node="$1"

	if [ -z "$node" ] || [ ! -r "$node" ]; then
		echo "unknown"
		return
	fi

	tr -d '[:space:]' <"$node"
}

write_color_profile() {
	local node="$1"
	local profile="$2"

	if [ -z "$node" ] || [ ! -e "$node" ]; then
		echo "color_profile sysfs node not found" >&2
		return 1
	fi

	if [ -w "$node" ]; then
		echo "$profile" >"$node"
	else
		echo "$profile" | sudo tee "$node" >/dev/null
	fi
}

find_graphical_session() {
	local sid active session_user_name session_type user_id

	for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
		[ -n "$sid" ] || continue

		active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null)
		[ "$active" = "yes" ] || continue

		session_user_name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
		[ -n "$session_user_name" ] || continue
		[ "$session_user_name" = "root" ] && continue

		session_type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
		case "$session_type" in
		wayland|x11|mir)
			echo "$sid $session_user_name"
			return 0
			;;
		esac
	done

	for runtime_dir in /run/user/[1-9]*; do
		[ -d "$runtime_dir" ] || continue
		user_id=$(basename "$runtime_dir")
		session_user_name=$(id -un "$user_id" 2>/dev/null) || continue
		[ -S "$runtime_dir/bus" ] || continue

		echo "0 $session_user_name"
		return 0
	done

	return 1
}

find_wayland_socket() {
	local runtime_dir="$1"
	local wayland_socket

	for wayland_socket in "$runtime_dir"/wayland-*; do
		[ -S "$wayland_socket" ] || continue
		basename "$wayland_socket"
		return 0
	done

	echo "wayland-0"
}

ensure_graphical_session_env() {
	local session_info session_id session_type session_desktop user_id runtime_dir
	local display_value wayland_display

	if [ -z "${session_user:-}" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -z "${XDG_RUNTIME_DIR:-}" ]; then
		session_info=$(find_graphical_session) || true
		if [ -n "${session_info:-}" ]; then
			session_id=${session_info%% *}
			session_user=${session_info#* }

			user_id=$(id -u "$session_user") || return 1
			runtime_dir="/run/user/$user_id"
			[ -d "$runtime_dir" ] || return 1

			export XDG_RUNTIME_DIR="$runtime_dir"
			export DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus"

			session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null)
			session_desktop=$(loginctl show-session "$session_id" -p Desktop --value 2>/dev/null)
			[ -n "$session_desktop" ] && export XDG_CURRENT_DESKTOP="$session_desktop"
			[ -n "$session_type" ] && export XDG_SESSION_TYPE="$session_type"

			if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
				wayland_display=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null)
				if [ "$session_type" = "x11" ]; then
					export DISPLAY="${wayland_display:-:0}"
					unset WAYLAND_DISPLAY
				else
					[ -z "$wayland_display" ] && wayland_display=$(find_wayland_socket "$runtime_dir")
					export WAYLAND_DISPLAY="$wayland_display"
				fi
			fi
		fi
	fi

	[ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] && return 0

	session_info=$(find_graphical_session) || return 1
	session_id=${session_info%% *}
	session_user=${session_info#* }

	user_id=$(id -u "$session_user") || return 1
	runtime_dir="/run/user/$user_id"
	[ -d "$runtime_dir" ] || return 1

	export XDG_RUNTIME_DIR="$runtime_dir"
	export DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus"

	session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null)
	session_desktop=$(loginctl show-session "$session_id" -p Desktop --value 2>/dev/null)
	[ -n "$session_desktop" ] && export XDG_CURRENT_DESKTOP="$session_desktop"
	[ -n "$session_type" ] && export XDG_SESSION_TYPE="$session_type"

	wayland_display=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null)
	if [ "$session_type" = "x11" ]; then
		export DISPLAY="${wayland_display:-:0}"
		unset WAYLAND_DISPLAY
	else
		[ -z "$wayland_display" ] && wayland_display=$(find_wayland_socket "$runtime_dir")
		export WAYLAND_DISPLAY="$wayland_display"
	fi

	return 0
}

find_gnome_rate_helper() {
	local candidate script_dir

	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	for candidate in \
		/usr/local/bin/gnome-display-rate.py \
		/usr/lib/pibrick/tools/gnome-display-rate.py \
		"$script_dir/gnome-display-rate.py"; do
		if [ -f "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

session_has_gnome_mutter() {
	ensure_graphical_session_env || true
	busctl --user status org.gnome.Mutter.DisplayConfig >/dev/null 2>&1
}

line_matches_panel_mode() {
	local line="$1"
	[[ "$line" =~ ${PANEL_WIDTH}x${PANEL_HEIGHT} ]] || [[ "$line" =~ ${PANEL_HEIGHT}x${PANEL_WIDTH} ]]
}

extract_panel_mode() {
	local line="$1"
	if [[ "$line" =~ (${PANEL_WIDTH}x${PANEL_HEIGHT}) ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$line" =~ (${PANEL_HEIGHT}x${PANEL_WIDTH}) ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

find_panel_output() {
	local line output candidate="" fallback_dsi=""

	ensure_graphical_session_env || true

	case "$display_tool" in
	gnome-mutter)
		display_output="primary"
		panel_mode="$PANEL_MODE"
		return 0
		;;
	wlr-randr)
		while IFS= read -r line; do
			if [[ "$line" =~ ^(DSI-[0-9]+)[[:space:]] ]]; then
				output="${BASH_REMATCH[1]}"
				if line_matches_panel_mode "$line"; then
					display_output="$output"
					panel_mode="$(extract_panel_mode "$line")"
					return 0
				fi
				[ -z "$fallback_dsi" ] && fallback_dsi="$output"
				candidate="$output"
				continue
			fi

			if [[ -n "$candidate" && "$line" =~ ^[[:space:]]+ ]] && line_matches_panel_mode "$line"; then
				display_output="$candidate"
				panel_mode="$(extract_panel_mode "$line")"
				return 0
			fi
		done < <(wlr-randr 2>/dev/null)

		if [ -n "$fallback_dsi" ]; then
			display_output="$fallback_dsi"
			panel_mode="$PANEL_MODE"
			return 0
		fi
		;;
	xrandr)
		while IFS= read -r line; do
			if [[ "$line" =~ ^([A-Za-z0-9-]+)[[:space:]]connected ]]; then
				output="${BASH_REMATCH[1]}"
				if [[ "$output" == DSI-* ]] || line_matches_panel_mode "$line"; then
					display_output="$output"
					if extracted_mode=$(extract_panel_mode "$line"); then
						panel_mode="$extracted_mode"
					else
						panel_mode="$PANEL_MODE"
					fi
					return 0
				fi
				candidate="$output"
			fi
		done < <(xrandr 2>/dev/null)

		if [ -n "$candidate" ]; then
			display_output="$candidate"
			panel_mode="$PANEL_MODE"
			return 0
		fi
		;;
	esac

	return 1
}

read_refresh_rate_sysfs() {
	local mode_line refresh

	for mode_file in /sys/class/drm/card*-DSI-*/modes; do
		[ -f "$mode_file" ] || continue
		while IFS= read -r mode_line; do
			if [[ "$mode_line" =~ ${PANEL_WIDTH}x${PANEL_HEIGHT}@([0-9]+) ]]; then
				refresh="${BASH_REMATCH[1]}"
				printf '%.0f\n' "$refresh"
				return 0
			fi
		done <"$mode_file"
	done

	return 1
}

detect_display_tool() {
	local gnome_helper=""

	ensure_graphical_session_env || true

	if session_has_gnome_mutter; then
		gnome_helper=$(find_gnome_rate_helper || true)
		if [ -n "$gnome_helper" ]; then
			display_tool="gnome-mutter"
			return 0
		fi
	fi

	if { [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; } \
		&& command -v wlr-randr >/dev/null 2>&1 \
		&& ! session_has_gnome_mutter; then
		display_tool="wlr-randr"
		return 0
	fi

	if [ -n "${DISPLAY:-}" ] && command -v xrandr >/dev/null 2>&1; then
		display_tool="xrandr"
		return 0
	fi

	if command -v wlr-randr >/dev/null 2>&1 && ! session_has_gnome_mutter; then
		display_tool="wlr-randr"
		return 0
	fi

	if command -v xrandr >/dev/null 2>&1; then
		display_tool="xrandr"
		return 0
	fi

	return 1
}

read_refresh_rate() {
	local line refresh current_output="" gnome_helper=""

	if ! detect_display_tool; then
		read_refresh_rate_sysfs || echo "unknown"
		return 0
	fi

	case "$display_tool" in
	gnome-mutter)
		gnome_helper=$(find_gnome_rate_helper) || true
		if [ -n "$gnome_helper" ] && refresh=$(python3 "$gnome_helper" get 2>/dev/null); then
			display_output="primary"
			panel_mode="$PANEL_MODE"
			printf '%.0f\n' "$refresh"
			return 0
		fi
		;;
	wlr-randr)
		# wlr-randr mode lines look like: "1080x1240 px, 90.000000 Hz (current)".
		while IFS= read -r line; do
			if [[ "$line" =~ ^([A-Za-z0-9-]+)[[:space:]] ]]; then
				current_output="${BASH_REMATCH[1]}"
			fi
			if [[ "$line" =~ px,[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]+Hz[[:space:]]+\(current\) ]]; then
				refresh="${BASH_REMATCH[1]}"
				[ -n "$current_output" ] && display_output="$current_output"
				printf '%.0f\n' "$refresh"
				return 0
			fi
		done < <(wlr-randr 2>/dev/null)
		;;
	xrandr)
		find_panel_output || true
		# xrandr mode lines look like: "   1080x1240     90.00*+  60.00"; current rate ends with '*'.
		while IFS= read -r line; do
			if [[ "$line" =~ ${panel_mode}[[:space:]] ]] && [[ "$line" =~ ([0-9]+\.[0-9]+)\* ]]; then
				refresh="${BASH_REMATCH[1]}"
				printf '%.0f\n' "$refresh"
				return 0
			fi
		done < <(xrandr 2>/dev/null)
		;;
	esac

	read_refresh_rate_sysfs || echo "unknown"
}

refresh_rate_help() {
	echo "Could not change refresh rate from this shell." >&2
	echo "  - Run from the desktop terminal (labwc / Pi OS), not plain SSH." >&2
	if session_has_gnome_mutter; then
		echo "  - GNOME: install python3-gi and /usr/lib/pibrick/tools/gnome-display-rate.py" >&2
		echo "  - Or use Settings → Displays → Refresh rate." >&2
	else
		echo "  - Install: sudo apt install wlr-randr" >&2
		if [ -n "${XDG_CURRENT_DESKTOP:-}" ] && [[ "${XDG_CURRENT_DESKTOP^^}" == *GNOME* ]]; then
			echo "  - GNOME: use Settings → Displays → Refresh rate." >&2
		fi
	fi
	if ! ensure_graphical_session_env 2>/dev/null; then
		echo "  - No active graphical session found via loginctl." >&2
	elif [ "$display_tool" = wlr-randr ] && ! wlr-randr >/dev/null 2>&1; then
		echo "  - wlr-randr cannot connect (WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset})." >&2
	fi
}

set_refresh_rate() {
	local refresh="$1"

	if ! detect_display_tool; then
		refresh_rate_help
		return 1
	fi

	if ! find_panel_output; then
		if [ "$display_tool" != "gnome-mutter" ]; then
			echo "Panel output not found (looked for ${PANEL_MODE} on DSI)." >&2
			refresh_rate_help
			return 1
		fi
	fi

	case "$display_tool" in
	gnome-mutter)
		local gnome_helper=""
		gnome_helper=$(find_gnome_rate_helper) || {
			refresh_rate_help
			return 1
		}
		if ! python3 "$gnome_helper" set "$refresh"; then
			echo "GNOME refresh rate change failed for ${refresh} Hz." >&2
			refresh_rate_help
			return 1
		fi
		;;
	wlr-randr)
		# wlr-randr has no --refresh flag; the rate is part of the mode string.
		if ! wlr-randr --output "$display_output" --mode "${panel_mode}@${refresh}Hz"; then
			echo "wlr-randr failed for $display_output @ ${panel_mode}@${refresh}Hz." >&2
			refresh_rate_help
			return 1
		fi
		;;
	xrandr)
		if ! xrandr --output "$display_output" --mode "$panel_mode" --rate "$refresh"; then
			echo "xrandr failed for $display_output @ ${panel_mode} ${refresh} Hz." >&2
			refresh_rate_help
			return 1
		fi
		;;
	esac
}

profile_label() {
	case "$1" in
	natural) echo "natural — balanced default" ;;
	vivid) echo "vivid — stronger colors" ;;
	srgb) echo "srgb — sRGB-like" ;;
	warm) echo "warm — warmer white point" ;;
	cool) echo "cool — cooler white point" ;;
	night) echo "night — low blue / dimmer tone" ;;
	soft) echo "soft — softer contrast" ;;
	*) echo "$1" ;;
	esac
}

is_valid_profile() {
	local profile="$1"
	local item

	for item in "${COLOR_PROFILES[@]}"; do
		if [ "$item" = "$profile" ]; then
			return 0
		fi
	done

	if [ "$profile" = "cold" ]; then
		return 0
	fi

	return 1
}

normalize_profile() {
	case "$1" in
	cold) echo "cool" ;;
	*) echo "$1" ;;
	esac
}

is_valid_refresh() {
	local refresh="$1"
	local item

	for item in "${REFRESH_RATES[@]}"; do
		if [ "$item" = "$refresh" ]; then
			return 0
		fi
	done

	return 1
}

print_status() {
	local profile refresh

	color_profile_node="$(find_color_profile_node)"
	profile="$(read_color_profile "$color_profile_node")"
	refresh="$(read_refresh_rate)"

	echo "Color profile : $profile"
	if [ -n "$color_profile_node" ]; then
		echo "  sysfs       : $color_profile_node"
	fi
	echo "Refresh rate  : ${refresh} Hz (panel modes: ${PANEL_MODES_LABEL})"
	if [ -r /etc/pibrick.panel ]; then
		echo "  panel       : $(tr -d '[:space:]' </etc/pibrick.panel)"
	fi
	if detect_display_tool; then
		if find_panel_output; then
			echo "  output      : $display_output @ ${panel_mode} via $display_tool"
		else
			echo "  output      : not detected (run from desktop session for live refresh control)"
		fi
		if [ -n "${session_user:-}" ]; then
			echo "  session     : $session_user (${WAYLAND_DISPLAY:-${DISPLAY:-no display env}})"
		fi
	fi
}

choose_color_profile() {
	local current choice index profile

	color_profile_node="$(find_color_profile_node)"
	if [ -z "$color_profile_node" ]; then
		echo "color_profile not found under /sys (is panel-pibrick loaded?)" >&2
		return 1
	fi

	current="$(read_color_profile "$color_profile_node")"
	echo
	echo "Color profile (current: $current)"
	echo "  Node: $color_profile_node"
	echo

	PS3="Select profile (number), or 0 to go back: "
	select choice in \
		"$(profile_label natural)" \
		"$(profile_label vivid)" \
		"$(profile_label srgb)" \
		"$(profile_label warm)" \
		"$(profile_label cool)" \
		"$(profile_label night)" \
		"$(profile_label soft)" \
		"Back"; do
		case "${REPLY:-}" in
		0|8|""|"Back")
			return 0
			;;
		[1-7])
			index=$((REPLY - 1))
			profile="${COLOR_PROFILES[$index]}"
			write_color_profile "$color_profile_node" "$profile"
			echo "Set color profile to $(read_color_profile "$color_profile_node")"
			return 0
			;;
		*)
			echo "Invalid choice."
			;;
		esac
	done
}

choose_refresh_rate() {
	local current choice refresh

	current="$(read_refresh_rate)"
	echo
	echo "Refresh rate (current: ${current} Hz)"
	echo "  Resolution: ${PANEL_MODE}"
	echo

	if [ "${#REFRESH_RATES[@]}" -eq 1 ]; then
		echo "  (9202/548 panel: 60 Hz only)"
		return 0
	fi

	PS3="Select refresh rate, or 0 to go back: "
	select choice in "90 Hz (default)" "60 Hz (lower power)" "Back"; do
		case "${REPLY:-}" in
		0|3|""|"Back")
			return 0
			;;
		1)
			refresh=90
			;;
		2)
			refresh=60
			;;
		*)
			echo "Invalid choice."
			continue
			;;
		esac

		if set_refresh_rate "$refresh"; then
			echo "Set refresh rate to ${refresh} Hz on ${display_output:-panel}."
		fi
		return 0
	done
}

interactive_menu() {
	local action

	while true; do
		echo
		echo "=== piBrick display settings ==="
		print_status
		echo

		PS3="Choose an option: "
		select action in "Color profile" "Refresh rate" "Quit"; do
			case "$action" in
			"Color profile")
				choose_color_profile || true
				break
				;;
			"Refresh rate")
				choose_refresh_rate || true
				break
				;;
			Quit|"")
				echo "Bye."
				return 0
				;;
			*)
				echo "Invalid choice."
				;;
			esac
		done
	done
}

main() {
	local profile_arg=""
	local refresh_arg=""
	local show_status=0

	while [ $# -gt 0 ]; do
		case "$1" in
		-h|--help)
			usage
			return 0
			;;
		-s|--status)
			show_status=1
			;;
		-p|--profile)
			shift
			profile_arg="${1:-}"
			[ -n "$profile_arg" ] || { echo "Missing profile name." >&2; return 1; }
			;;
		-r|--refresh)
			shift
			refresh_arg="${1:-}"
			[ -n "$refresh_arg" ] || { echo "Missing refresh rate." >&2; return 1; }
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			return 1
			;;
		esac
		shift
	done

	if [ "$show_status" = 1 ] && [ -z "$profile_arg" ] && [ -z "$refresh_arg" ]; then
		print_status
		return 0
	fi

	if [ -n "$profile_arg" ]; then
		profile_arg="$(normalize_profile "$profile_arg")"
		if ! is_valid_profile "$profile_arg"; then
			echo "Invalid profile: $profile_arg" >&2
			return 1
		fi
		color_profile_node="$(find_color_profile_node)"
		write_color_profile "$color_profile_node" "$profile_arg"
		echo "Color profile: $(read_color_profile "$color_profile_node")"
	fi

	if [ -n "$refresh_arg" ]; then
		if ! is_valid_refresh "$refresh_arg"; then
			echo "Invalid refresh rate: $refresh_arg (use ${REFRESH_RATES[*]})" >&2
			return 1
		fi
		set_refresh_rate "$refresh_arg"
		echo "Refresh rate set to ${refresh_arg} Hz."
	fi

	if [ -z "$profile_arg" ] && [ -z "$refresh_arg" ] && [ "$show_status" = 0 ]; then
		interactive_menu
	fi
}

main "$@"
