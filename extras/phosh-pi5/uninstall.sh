#!/bin/bash
#
# extras/phosh-pi5/uninstall.sh — reverses the libwlroots-0.18 hold
# installed by fix-phosh-pi5.sh so apt upgrades can flow again.
#
# Boot-mode changes (GDM enable/disable, phosh.service enable/disable) are
# NOT reverted here — those are session-preference choices, not the fix
# itself. The user can change them via the original script's
# --boot-to-{phosh,gdm} flags or manually with systemctl.
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "phosh-pi5 uninstall requires root. Re-run: sudo $0" >&2
    exit 1
fi

echo ">>> Releasing apt hold on libwlroots-0.18..."
apt-mark unhold libwlroots-0.18 2>/dev/null || true

# Show the user what state they're now in.
echo ">>> Current libwlroots-0.18:"
dpkg-query -W -f='  libwlroots-0.18 ${Version}\n' libwlroots-0.18 2>/dev/null || echo "  (not installed)"
echo ">>> Held packages:"
apt-mark showhold || true

echo
echo ">>> Done. Boot behaviour (GDM / phosh.service) was left unchanged."
echo "    Use 'sudo bash fix-phosh-pi5.sh --boot-to-gdm' or '--boot-to-phosh' to change it."