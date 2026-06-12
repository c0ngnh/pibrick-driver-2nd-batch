#!/bin/bash
# Step brightness on pibrick-backlight (0–255 on 9203 panel)

backlight="/sys/class/backlight/pibrick-backlight/brightness"
max_file="/sys/class/backlight/pibrick-backlight/max_brightness"

if [ ! -f "$backlight" ]; then
	exit 1
fi

current=$(cat "$backlight")
max=$(cat "$max_file")
step=$((max / 4))
[ "$step" -lt 1 ] && step=1

new=$((current + step))
[ "$new" -gt "$max" ] && new=0

echo "$new" >"$backlight"
