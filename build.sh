#!/bin/bash
cd "$(dirname "$0")"

force_rebuild=0
skip_reboot=0

for arg in "$@"; do
	case "$arg" in
	--force|-f) force_rebuild=1 ;;
	--no-reboot) skip_reboot=1 ;;
	esac
done

if [ "$force_rebuild" = 1 ]; then
	echo "Force rebuild requested."
elif [ -f /etc/pibrick.lastbuild ] && [ "$(cat /etc/pibrick.lastbuild)" = "$(uname -r)" ]; then
	echo "No Linux Kernel Update."
	exit 0
else
	echo "Linux Kernel changed. Rebuild."
fi

#	apt install -y linux-headers-$(uname -r)

# Clean before each build so a changed header/source can't leave stale
# objects behind (incremental builds normally suffice, but this guarantees
# a fresh module on every kernel update).
make clean
make -j4 amoled
make install

cd hyn_driver_release_qm
make clean
make -j4 touch
make install

cd ../battery
make clean
make
make install

echo "$(uname -r)" > /etc/pibrick.lastbuild

if [ "$skip_reboot" = 1 ]; then
	echo "Build finished (reboot skipped)."
elif [ -f "/boot/firstrun.sh" ]; then
	echo "Firstrun build finished"
else
	reboot
fi
