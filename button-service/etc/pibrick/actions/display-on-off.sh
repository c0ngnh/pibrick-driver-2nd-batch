#!/bin/bash
# Toggle panel via panel-pibrick sysfs (Pi 5 DSI)

sysfs_path=$(find /sys -name pibrick_display_enable 2>/dev/null | grep dsi | head -n 1)

if [ -z "$sysfs_path" ]; then
	echo "pibrick_display_enable not found" >&2
	exit 1
fi

current=$(cat "$sysfs_path")
if [ "$current" -eq 0 ]; then
	new_value=1
else
	new_value=0
fi

if ! echo "$new_value" >"$sysfs_path" 2>/dev/null; then
	echo "pibrick_display_enable: permission denied (re-run: sudo bash button-service/install.sh)" >&2
	exit 1
fi
