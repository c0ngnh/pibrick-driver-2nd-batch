#!/bin/bash

# Install piBrick autoBuild Kernel Modules
mkdir -p /usr/lib/pibrick/
cp -rf ./* /usr/lib/pibrick/
cp /usr/lib/pibrick/pibrick.service /etc/systemd/system/
chmod +x /usr/lib/pibrick/build.sh
systemctl daemon-reload
systemctl enable pibrick.service
cd /usr/lib/pibrick/
/usr/lib/pibrick/build.sh --force --no-reboot
bash /usr/lib/pibrick/desktop/setup-desktop.sh
bash /usr/lib/pibrick/button-service/install.sh
systemctl start pibrick.service
