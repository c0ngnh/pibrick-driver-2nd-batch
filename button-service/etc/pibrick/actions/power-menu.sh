#!/bin/bash
# Show the native power / shutdown menu for the active desktop environment.

set -euo pipefail

desktop_name="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-}}"
desktop_name="${desktop_name^^}"

session_has_gnome_shell() {
	busctl --user status org.gnome.Shell >/dev/null 2>&1
}

session_has_kde_plasma() {
	busctl --user status org.kde.LogoutPrompt >/dev/null 2>&1
}

run_gnome_power_menu() {
	# EndSessionDialog leaves a stuck modal blur on GNOME 48; pibrickbtn injects KEY_POWER instead.
	# Manual-test fallback only (e.g. sudo bash power-short.sh without a button press).
	if command -v gnome-session-quit >/dev/null 2>&1; then
		gnome-session-quit --power-off >/dev/null 2>&1 &
		return 0
	fi

	return 1
}

run_kde_power_menu() {
	if command -v qdbus6 >/dev/null 2>&1; then
		qdbus6 org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt.promptShutDown >/dev/null 2>&1 && return 0
		qdbus6 org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt.promptAll >/dev/null 2>&1 && return 0
	fi

	if command -v qdbus >/dev/null 2>&1; then
		qdbus org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt.promptShutDown >/dev/null 2>&1 && return 0
		qdbus org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt.promptAll >/dev/null 2>&1 && return 0
	fi

	if command -v dbus-send >/dev/null 2>&1; then
		dbus-send --session --print-reply \
			--dest=org.kde.LogoutPrompt \
			/LogoutPrompt \
			org.kde.LogoutPrompt.promptShutDown >/dev/null 2>&1 && return 0
	fi

	return 1
}

run_xfce_power_menu() {
	if command -v xfce4-session-logout >/dev/null 2>&1; then
		xfce4-session-logout >/dev/null 2>&1 && return 0
	fi

	return 1
}

run_mate_power_menu() {
	if command -v mate-session-save >/dev/null 2>&1; then
		mate-session-save --logout-dialog >/dev/null 2>&1 && return 0
	fi

	return 1
}

run_lxqt_power_menu() {
	if command -v lxqt-leave >/dev/null 2>&1; then
		lxqt-leave --leave-with-shutdown >/dev/null 2>&1 && return 0
	fi

	return 1
}

run_pios_power_menu() {
	local menu_cmd

	for menu_cmd in pishutdown lxde-pi-shutdown-helper /usr/bin/pishutdown; do
		if command -v "$menu_cmd" >/dev/null 2>&1; then
			exec "$menu_cmd"
		fi
		if [ -x "$menu_cmd" ]; then
			exec "$menu_cmd"
		fi
	done

	return 1
}

send_power_key() {
	if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
		if command -v wtype >/dev/null 2>&1; then
			wtype -P XF86PowerOff -p XF86PowerOff && return 0
		fi
	fi

	if [ -n "${DISPLAY:-}" ] && command -v xdotool >/dev/null 2>&1; then
		xdotool key XF86PowerOff && return 0
	fi

	return 1
}

# GNOME/KDE: pibrickbtn already injected KEY_POWER — skip dbus/script menu (avoids double dialog + blur).
if session_has_gnome_shell; then
	exit 0
fi

if session_has_kde_plasma; then
	exit 0
fi

# Live session D-Bus beats stale XDG vars (Pi images may still export LABWC while GNOME runs).
case "$desktop_name" in
*GNOME*|*CINNAMON*|*BUDGIE*|*UNITY*)
	run_gnome_power_menu && exit 0
	;;
*KDE*|*PLASMA*)
	run_kde_power_menu && exit 0
	;;
*XFCE*)
	run_xfce_power_menu && exit 0
	;;
*MATE*)
	run_mate_power_menu && exit 0
	;;
*LXQT*)
	run_lxqt_power_menu && exit 0
	;;
*LABWC*|*LXDE*|*RPD-LABWC*)
	# Only when GNOME/KDE are not actually running on the session bus.
	if ! session_has_gnome_shell && ! session_has_kde_plasma; then
		run_pios_power_menu && exit 0
	fi
	;;
esac

run_gnome_power_menu && exit 0
run_kde_power_menu && exit 0
run_xfce_power_menu && exit 0
send_power_key && exit 0

if ! session_has_gnome_shell && ! session_has_kde_plasma; then
	run_pios_power_menu && exit 0
fi

echo "Could not open a desktop power menu (session: ${desktop_name:-unknown})" >&2
exit 1
