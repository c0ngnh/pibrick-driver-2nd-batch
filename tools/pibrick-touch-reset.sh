#!/bin/bash
# Recover Hynitron touch after panel blank/unblank or early-boot probe races.

set -e

touch_present() {
	grep -q 'Name="hyn_ts"' /proc/bus/input/devices 2>/dev/null
}

find_hyntpdbg() {
	find /sys/bus/i2c/devices -name hyntpdbg 2>/dev/null | head -n 1
}

find_display_enable() {
	find /sys/devices -name pibrick_display_enable 2>/dev/null | grep dsi | head -n 1
}

reload_hyn_ts() {
	/sbin/modprobe -r hyn_ts 2>/dev/null || true
	sleep 0.5
	/sbin/modprobe hyn_ts
	sleep 0.5
}

disp=$(find_display_enable)
if [ -n "$disp" ] && [ "$(cat "$disp")" -eq 0 ]; then
	echo "Turning display on so touch can resume..."
	echo 1 >"$disp"
	sleep 0.3
fi

if ! touch_present; then
	echo "hyn_ts input missing; reloading driver..."
	reload_hyn_ts
fi

dbg=$(find_hyntpdbg)
if [ -z "$dbg" ]; then
	echo "hyntpdbg not found; reloading driver..."
	reload_hyn_ts
	dbg=$(find_hyntpdbg)
fi

if [ -z "$dbg" ]; then
	echo "hyn_ts still not ready after reload" >&2
	exit 1
fi

echo rst >"$dbg"
sleep 0.1
echo "Touch reset sent via $dbg"
