#!/bin/bash
set -euo pipefail

PANEL_CONFIG=/etc/pibrick.panel

panel_label() {
	case "$1" in
	9203) echo "9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)" ;;
	9202) echo "9202 - Visionox 1080x1240 @ 60 Hz" ;;
	548)  echo "5.48 inch - 1080x1920 @ 60 Hz" ;;
	*)    echo "$1" ;;
	esac
}

choose_panel() {
	local choice saved

	if [ -n "${PANEL:-}" ]; then
		case "$PANEL" in
		9203|9202|548) echo "$PANEL"; return 0 ;;
		*)
			echo "ERROR: invalid PANEL=$PANEL (use 9203, 9202, or 548)" >&2
			exit 1
			;;
		esac
	fi

	if [ -f "$PANEL_CONFIG" ]; then
		saved="$(tr -d '[:space:]' < "$PANEL_CONFIG")"
	else
		saved=9203
	fi

	# No terminal on stdin (piped/automated): use saved/default without blocking.
	if [ ! -t 0 ]; then
		echo "No terminal for panel prompt; using ${saved}. Override with PANEL=9203|9202|548." >&2
		echo "$saved"
		return 0
	fi

	# Prompts go to stderr so they show on the terminal; this function's stdout
	# is captured by the caller ($(choose_panel)) and must contain only the result.
	echo >&2
	echo "=== piBrick display panel ===" >&2
	echo "1) 9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)" >&2
	echo "2) 9202 - Visionox 1080x1240 @ 60 Hz" >&2
	echo "3) 5.48 inch - 1080x1920 @ 60 Hz" >&2
	echo >&2
	printf "Choose panel [1-3] (default: %s): " "$saved" >&2

	if ! read -r choice; then
		echo "ERROR: no panel selected." >&2
		exit 1
	fi

	case "${choice:-}" in
	"")          echo "$saved" ;;
	"9203"|1)    echo 9203 ;;
	"9202"|2)    echo 9202 ;;
	"548"|3)     echo 548 ;;
	*)
		echo "ERROR: invalid choice: $choice" >&2
		exit 1
		;;
	esac
}

regenerate_initramfs_if_needed() {
	depmod -a
	if ! command -v update-initramfs >/dev/null 2>&1; then
		echo "WARNING: update-initramfs not found; panel module may stay stale in initramfs." >&2
		return 0
	fi
	if ! grep -q '^auto_initramfs=1' /boot/firmware/config.txt 2>/dev/null; then
		return 0
	fi
	echo "Regenerating initramfs (clears stale panel-pibrick.ko from early boot)..."
	update-initramfs -u -k all || update-initramfs -u || {
		echo "WARNING: update-initramfs failed; run: sudo update-initramfs -u -k all" >&2
		return 1
	}
}

SELECTED_PANEL="$(choose_panel)"
echo "$SELECTED_PANEL" > "$PANEL_CONFIG"
echo 60 > /etc/pibrick.display-refresh
echo "Selected panel: $(panel_label "$SELECTED_PANEL")"
echo "Default refresh: 60 Hz (saved to /etc/pibrick.display-refresh)"
echo "Saved panel to $PANEL_CONFIG"

# Install piBrick autoBuild Kernel Modules
mkdir -p /usr/lib/pibrick/
cp -rf ./* /usr/lib/pibrick/
# Never let a stale real file shadow the Makefile symlink to the chosen panel source.
rm -f /usr/lib/pibrick/panel-pibrick.c
cp /usr/lib/pibrick/pibrick.service /etc/systemd/system/
chmod +x /usr/lib/pibrick/build.sh
systemctl daemon-reload
systemctl enable pibrick.service
cd /usr/lib/pibrick/
PANEL="$SELECTED_PANEL" /usr/lib/pibrick/build.sh --force --no-reboot
bash /usr/lib/pibrick/desktop/setup-desktop.sh
bash /usr/lib/pibrick/button-service/install.sh
systemctl start pibrick.service
regenerate_initramfs_if_needed

echo
echo "Install complete. Panel: $(panel_label "$SELECTED_PANEL")"
echo "Default refresh: 60 Hz (kernel preferred + applied on next login)"
echo "Reboot to apply: sudo reboot"
