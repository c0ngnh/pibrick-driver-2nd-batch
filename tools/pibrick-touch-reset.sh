#!/bin/bash
# Recover Hynitron touch after panel blank/unblank or display-toggle races.

set -e

find_hyntpdbg() {
	find /sys/bus/i2c/devices -name hyntpdbg 2>/dev/null | head -n 1
}

find_display_enable() {
	find /sys/devices -name pibrick_display_enable 2>/dev/null | grep dsi | head -n 1
}

disp=$(find_display_enable)
if [ -n "$disp" ] && [ "$(cat "$disp")" -eq 0 ]; then
	echo "Turning display on so touch can resume..."
	echo 1 >"$disp"
	sleep 0.3
fi

dbg=$(find_hyntpdbg)
if [ -z "$dbg" ]; then
	echo "hyntpdbg not found (is hyn_ts loaded?)" >&2
	exit 1
fi

echo rst >"$dbg"
sleep 0.1
echo "Touch reset sent via $dbg"
