#!/bin/bash
set -e
cd "$(dirname "$0")"

FORCE=0
if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
	FORCE=1
fi

LASTBUILD=""
if [ -f /etc/pibrick.lastbuild ]; then
	LASTBUILD="$(cat /etc/pibrick.lastbuild)"
fi

if [ "$FORCE" = "1" ]; then
	echo "Force rebuild requested."
elif [ "$LASTBUILD" = "$(uname -r)" ]; then
	echo "No Linux Kernel Update."
	exit 0
else
	echo "Linux Kernel Changed. Rebuild"
fi

#	apt install -y linux-headers-$(uname -r)

make -j4 amoled
make install

cd hyn_driver_release_qm
make -j4 touch
make install

cd ../battery
make
make install

echo "$(uname -r)" > /etc/pibrick.lastbuild

if [ -f "/boot/firstrun.sh" ]; then
	echo "Firstrun build finished"
else
	reboot
fi
