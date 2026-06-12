#!/bin/bash
# Power button short press: Pi OS default menu (same as XF86PowerOff in labwc).

for menu_cmd in pishutdown lxde-pi-shutdown-helper /usr/bin/pishutdown; do
	if command -v "$menu_cmd" >/dev/null 2>&1; then
		bash /etc/pibrick/actions/run-as-session-user.sh "$menu_cmd" && exit 0
	fi
	if [ -x "$menu_cmd" ]; then
		bash /etc/pibrick/actions/run-as-session-user.sh "$menu_cmd" && exit 0
	fi
done

echo "pishutdown not found (install raspberrypi-ui-mods / desktop packages)" >&2
exit 1
