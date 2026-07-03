#!/bin/bash
# Recover Hynitron touch after panel blank/unblank or early-boot probe races.

set -euo pipefail

MAX_RETRIES=5
RETRY_SLEEP=3

touch_present() {
	grep -q 'Name="hyn_ts"' /proc/bus/input/devices 2>/dev/null
}

find_hyntpdbg() {
	local d

	for d in /sys/bus/i2c/devices/*-005a/hyntpdbg; do
		[ -e "$d" ] || continue
		printf '%s\n' "$d"
		return 0
	done

	find /sys/bus/i2c/devices -name hyntpdbg 2>/dev/null | head -n 1
}

find_display_enable() {
	find /sys/devices -name pibrick_display_enable 2>/dev/null | grep dsi | head -n 1
}

turn_display_on() {
	local disp

	disp=$(find_display_enable)
	[ -n "$disp" ] || return 0

	if [ "$(cat "$disp" 2>/dev/null)" -eq 0 ]; then
		echo "Turning display on so touch can resume..."
		echo 1 >"$disp"
		sleep 0.5
	fi
}

reload_hyn_ts() {
	echo "Reloading hyn_ts..."
	/sbin/modprobe -r hyn_ts 2>/dev/null || true
	sleep 0.5
	/sbin/modprobe hyn_ts
	sleep 2
}

try_soft_reset() {
	local dbg

	dbg=$(find_hyntpdbg)
	[ -n "$dbg" ] || return 1

	echo rst >"$dbg"
	sleep 0.1
	echo "Touch reset sent via $dbg"
	return 0
}

turn_display_on

# Touch already registered — never unload a working driver just because
# hyntpdbg sysfs appears a second late after probe.
if touch_present; then
	for _ in $(seq 1 5); do
		if try_soft_reset; then
			exit 0
		fi
		sleep 1
	done
	echo "Touch input present (skipped driver reload)"
	exit 0
fi

for _ in $(seq 1 "$MAX_RETRIES"); do
	reload_hyn_ts
	if touch_present; then
		try_soft_reset || true
		echo "Touch recovered after reload"
		exit 0
	fi
	sleep "$RETRY_SLEEP"
done

echo "Touch recovery failed: hyn_ts input not registered" >&2
exit 1
