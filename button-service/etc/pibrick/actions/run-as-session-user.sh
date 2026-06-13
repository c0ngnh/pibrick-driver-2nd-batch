#!/bin/bash
# Run a command in the active graphical session (Wayland/labwc on Pi OS).

if [ $# -lt 1 ]; then
	echo "usage: run-as-session-user.sh <command> [args...]" >&2
	exit 1
fi

find_graphical_session() {
	local sid active session_user session_type user_id

	for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
		[ -n "$sid" ] || continue

		active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null)
		[ "$active" = "yes" ] || continue

		session_user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
		[ -n "$session_user" ] || continue
		[ "$session_user" = "root" ] && continue

		session_type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
		case "$session_type" in
		wayland|x11|mir)
			echo "$sid $session_user"
			return 0
			;;
		esac
	done

	for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
		[ -n "$sid" ] || continue

		active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null)
		[ "$active" = "yes" ] || continue

		session_user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
		user_id=$(id -u "$session_user" 2>/dev/null) || continue
		[ "$user_id" -ge 1000 ] || continue
		[ -d "/run/user/$user_id" ] || continue

		echo "$sid $session_user"
		return 0
	done

	for runtime_dir in /run/user/[1-9]*; do
		[ -d "$runtime_dir" ] || continue
		user_id=$(basename "$runtime_dir")
		session_user=$(id -un "$user_id" 2>/dev/null) || continue
		[ -S "$runtime_dir/bus" ] || continue
		ls "$runtime_dir"/wayland-* >/dev/null 2>&1 || continue

		echo "0 $session_user"
		return 0
	done

	return 1
}

find_wayland_display() {
	local runtime_dir="$1"
	local wayland_socket

	for wayland_socket in "$runtime_dir"/wayland-*; do
		[ -S "$wayland_socket" ] || continue
		basename "$wayland_socket"
		return 0
	done

	echo "wayland-0"
}

session_info=$(find_graphical_session) || {
	echo "no active graphical session" >&2
	exit 1
}

session_id=${session_info%% *}
session_user=${session_info#* }

user_id=$(id -u "$session_user") || exit 1
runtime_dir="/run/user/$user_id"
[ -d "$runtime_dir" ] || {
	echo "missing runtime dir $runtime_dir" >&2
	exit 1
}

session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null)
session_desktop=$(loginctl show-session "$session_id" -p Desktop --value 2>/dev/null)

detect_session_desktop() {
	local runtime_dir="$1"
	local bus_address="$2"

	if [ -n "$session_desktop" ]; then
		echo "$session_desktop"
		return 0
	fi

	if env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus_address" \
		busctl --user status org.gnome.Shell >/dev/null 2>&1; then
		echo "GNOME"
		return 0
	fi

	if env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus_address" \
		busctl --user status org.kde.LogoutPrompt >/dev/null 2>&1; then
		echo "KDE"
		return 0
	fi

	return 1
}

session_desktop=$(detect_session_desktop "$runtime_dir" "unix:path=${runtime_dir}/bus" || true)

wayland_display=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null)
if [ "$session_type" = "x11" ]; then
	display_value="${wayland_display:-:0}"
	wayland_display=""
else
	display_value=""
	[ -z "$wayland_display" ] && wayland_display=$(find_wayland_display "$runtime_dir")
fi

session_env=(
	env
	XDG_RUNTIME_DIR="$runtime_dir"
	DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus"
)

[ -n "$session_desktop" ] && session_env+=(XDG_CURRENT_DESKTOP="$session_desktop")
[ -n "$session_type" ] && session_env+=(XDG_SESSION_TYPE="$session_type")
[ -n "$wayland_display" ] && session_env+=(WAYLAND_DISPLAY="$wayland_display")
[ -n "$display_value" ] && session_env+=(DISPLAY="$display_value")

exec_as_session_user() {
	local runuser_cmd=""

	for candidate in /usr/sbin/runuser /sbin/runuser runuser; do
		if [ -x "$candidate" ] 2>/dev/null || command -v "$candidate" >/dev/null 2>&1; then
			runuser_cmd="$candidate"
			break
		fi
	done

	if [ -n "$runuser_cmd" ]; then
		exec "$runuser_cmd" -u "$session_user" -- \
			"${session_env[@]}" \
			"$@"
	fi

	# util-linux runuser missing — fall back to su (needs root).
	if [ "$(id -u)" -ne 0 ]; then
		echo "run-as-session-user.sh must run as root (or install util-linux for runuser)" >&2
		exit 1
	fi

	exec su -s /bin/bash "$session_user" -c "$(printf '%q ' "${session_env[@]}" "$@")"
}

exec_as_session_user "$@"
