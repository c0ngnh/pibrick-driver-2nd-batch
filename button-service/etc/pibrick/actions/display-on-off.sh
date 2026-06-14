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

# After turning the panel on, nudge touch in case drm_panel resume raced with suspend.
if [ "$new_value" -eq 1 ]; then
	sleep 0.15
	dbg=$(find /sys/bus/i2c/devices -name hyntpdbg 2>/dev/null | head -n 1)
	if [ -n "$dbg" ]; then
		echo rst >"$dbg" 2>/dev/null || true
	fi
fi
