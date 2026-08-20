#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! pkg-config --exists libgpiod 2>/dev/null; then
	echo "Installing libgpiod..."
	apt-get install -y libgpiod-dev gpiod
fi

if ! command -v pishutdown >/dev/null 2>&1; then
	echo "NOTE: pishutdown not found — Pi OS menu fallback unavailable (GNOME/KDE/etc. still work)." >&2
fi

gcc -Wall -O2 pibrickbtn.c -o pibrickbtn $(pkg-config --cflags --libs libgpiod)

install -m 755 pibrickbtn /usr/local/bin/pibrickbtn
cp -r etc/pibrick /etc/
chmod +x /etc/pibrick/*.sh /etc/pibrick/actions/*.sh

install -m 644 pibrickbtn.service /etc/systemd/system/pibrickbtn.service
install -m 644 99-pibrick-display.rules /etc/udev/rules.d/99-pibrick-display.rules

# Keep gpio_keys from reclaiming button lines on later modprobe -r cycles.
cat >/etc/modprobe.d/pibrick-btn.conf <<'EOF'
# PiBrick PocketCM5 only: userspace pibrickbtn owns the button GPIOs.
# Other boards are unaffected unless they install this package.
blacklist gpio_keys
EOF
udevadm control --reload-rules
while IFS= read -r sysfs_path; do
	chmod 0666 "$sysfs_path"
done < <(find /sys/devices -name pibrick_display_enable 2>/dev/null)
while IFS= read -r sysfs_path; do
	chmod 0664 "$sysfs_path" 2>/dev/null || chmod 0666 "$sysfs_path"
	chgrp video "$sysfs_path" 2>/dev/null || true
done < <(find /sys/devices -name color_profile 2>/dev/null | grep dsi || true)
if [ -f /sys/class/backlight/pibrick-backlight/brightness ]; then
	chmod 0664 /sys/class/backlight/pibrick-backlight/brightness 2>/dev/null || \
		chmod 0666 /sys/class/backlight/pibrick-backlight/brightness
	chgrp video /sys/class/backlight/pibrick-backlight/brightness 2>/dev/null || true
fi
while IFS= read -r sysfs_path; do
	chmod 0666 "$sysfs_path" 2>/dev/null || true
done < <(find /sys/bus/i2c/devices -name hyntpdbg 2>/dev/null)
udevadm trigger --subsystem-match=platform
udevadm trigger --subsystem-match=backlight
udevadm trigger --subsystem-match=i2c
udevadm trigger --subsystem-match=mipi-dsi

systemctl daemon-reload
systemctl enable pibrickbtn.service
systemctl restart pibrickbtn.service

echo "piBrick button service installed (user short=display, power short=desktop power menu, power long=shutdown)."
echo "GPIO test: sudo systemctl stop pibrickbtn && sudo /usr/local/bin/pibrickbtn --test"
echo "Logs:      journalctl -u pibrickbtn -f"
