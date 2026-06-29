#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

force_rebuild=0
skip_reboot=0

for arg in "$@"; do
	case "$arg" in
	--force|-f) force_rebuild=1 ;;
	--no-reboot) skip_reboot=1 ;;
	esac
done

if [ -f /etc/pibrick.panel ]; then
	PANEL="${PANEL:-$(tr -d '[:space:]' < /etc/pibrick.panel)}"
else
	PANEL="${PANEL:-9203}"
fi

case "$PANEL" in
9203|9202|548|5inch) ;;
*)
	echo "ERROR: invalid PANEL=$PANEL (expected 9203, 9202, 548, or 5inch)" >&2
	exit 1
	;;
esac

if [ "$force_rebuild" = 1 ]; then
	echo "Force rebuild requested."
elif [ -f /etc/pibrick.lastbuild ] && [ "$(cat /etc/pibrick.lastbuild)" = "$(uname -r)" ]; then
	echo "No Linux Kernel Update."
	exit 0
else
	echo "Linux Kernel changed. Rebuild."
fi

regenerate_initramfs_if_needed() {
	depmod -a
	if ! command -v update-initramfs >/dev/null 2>&1; then
		echo "WARNING: update-initramfs not found; panel module may stay stale in initramfs." >&2
		return 0
	fi
	if ! grep -q '^auto_initramfs=1' /boot/firmware/config.txt 2>/dev/null; then
		return 0
	fi
	echo "Regenerating initramfs so the new panel module is loaded at boot..."
	update-initramfs -u -k all || update-initramfs -u || {
		echo "WARNING: update-initramfs failed; run: sudo update-initramfs -u -k all" >&2
		return 1
	}
}

echo "Building panel variant: ${PANEL}"
make clean
rm -f panel-pibrick.c
make -j4 amoled "PANEL=${PANEL}"
make install "PANEL=${PANEL}"

if [ "$PANEL" = 548 ]; then
	cd fts
	make clean
	make -j4 touch
	make install
	cd ../hyn_driver_release_qm
	make remove 2>/dev/null || true
else
	cd hyn_driver_release_qm
	make clean
	make -j4 touch
	make install
	cd ../fts
	make remove 2>/dev/null || true
fi

cd "$ROOT_DIR/battery"
make clean
make
make install

regenerate_initramfs_if_needed

echo "$(uname -r)" > /etc/pibrick.lastbuild

if [ "$skip_reboot" = 1 ]; then
	echo "Build finished (reboot skipped)."
elif [ -f "/boot/firstrun.sh" ]; then
	echo "Firstrun build finished"
else
	reboot
fi
