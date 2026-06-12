#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! pkg-config --exists libgpiod 2>/dev/null; then
	echo "Installing libgpiod..."
	apt-get install -y libgpiod-dev gpiod
fi

if ! command -v pishutdown >/dev/null 2>&1; then
	echo "WARNING: pishutdown not found — install the Pi OS desktop (pishutdown package)." >&2
fi

gcc -Wall -O2 pibrickbtn.c -o pibrickbtn $(pkg-config --cflags --libs libgpiod)

install -m 755 pibrickbtn /usr/local/bin/pibrickbtn
cp -r etc/pibrick /etc/
chmod +x /etc/pibrick/*.sh /etc/pibrick/actions/*.sh

install -m 644 pibrickbtn.service /etc/systemd/system/pibrickbtn.service
install -m 644 99-pibrick-display.rules /etc/udev/rules.d/99-pibrick-display.rules

# Keep gpio_keys from reclaiming button lines on later modprobe -r cycles.
cat >/etc/modprobe.d/pibrick-btn.conf <<'EOF'
# piBrick buttons are handled by pibrickbtn (userspace), not gpio_keys.
blacklist gpio_keys
EOF
udevadm control --reload-rules
while IFS= read -r sysfs_path; do
	chmod 0666 "$sysfs_path"
done < <(find /sys/devices -name pibrick_display_enable 2>/dev/null)
udevadm trigger --subsystem-match=platform

systemctl daemon-reload
systemctl enable pibrickbtn.service
systemctl restart pibrickbtn.service

echo "piBrick button service installed (user short=display, power short=pishutdown, power long=shutdown)."
echo "GPIO test: sudo systemctl stop pibrickbtn && sudo /usr/local/bin/pibrickbtn --test"
echo "Logs:      journalctl -u pibrickbtn -f"
