#!/bin/bash
#
# pibrick-autorotation uninstaller
#
# Removes the autorotation service and device tree overlay
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

# Check for root
if [ "$(id -u)" != "0" ]; then
    echo "autorotation-uninstall: this command modifies the system; please re-run with sudo:" >&2
    echo "  sudo $0" >&2
    exit 1
fi

info "Uninstalling piBrick Autorotation Service..."

# Stop and disable service
info "Stopping service..."
systemctl stop pibrick-autorotation.service 2>/dev/null || true
systemctl disable pibrick-autorotation.service 2>/dev/null || true

# Unload kernel module if loaded
KVER="$(uname -r)"
KVER_DIR="/lib/modules/$KVER"
if [ -f "$KVER_DIR/extra/mma8451q.ko" ]; then
    if lsmod 2>/dev/null | grep -q mma8451q; then
        modprobe -r mma8451q 2>/dev/null || true
    fi
    rm -f "$KVER_DIR/extra/mma8451q.ko"
    depmod -a 2>/dev/null || true
fi

# Remove systemd unit
info "Removing systemd service..."
rm -f /etc/systemd/system/pibrick-autorotation.service
systemctl daemon-reload

# Remove binaries
info "Removing binaries..."
rm -f /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh
rm -f /usr/lib/pibrick/autorotation-service/pibrick-autorotation.sh.bak* 2>/dev/null || true
rmdir /usr/lib/pibrick/autorotation-service 2>/dev/null || true

# Remove action scripts
info "Removing action scripts..."
rm -f /etc/pibrick/actions/autorotation-lock.sh

# Remove autostart desktop entry
info "Removing autostart entry..."
for home in /root /home/*; do
    rm -f "$home/.config/autostart/pibrick-autorotation.desktop" 2>/dev/null || true
done

# Remove device tree overlay
info "Removing device tree overlay..."
rm -f /boot/firmware/overlays/pibrick-mma8451q.dtbo 2>/dev/null || true

# Remove from config.txt
info "Cleaning up config.txt..."
sed -i '/dtoverlay=pibrick-mma8451q/d' /boot/firmware/config.txt 2>/dev/null || true

# Remove state files
info "Removing state files..."
rm -f /var/lib/pibrick/autorotation.lock
rm -f /var/lib/pibrick/autorotation.lock.type

# Remove SDDM config files created by autorotation-service
info "Removing SDDM config files..."
rm -f /etc/sddm.conf.d/10-pibrick.conf
rm -f /etc/sddm.conf.d/kde-plasmamobile.conf
rm -f /etc/sddm.conf.d/zz-pibrick-autorotation.conf

# Remove plasmoid and user services
info "Removing plasmoid and user services..."
for home in /home/*; do
    rm -rf "$home/.local/share/kservices5/pibrick-rotation-lock" 2>/dev/null || true
    rm -rf "$home/.local/share/plasma/plasmoids/pibrick-rotation-lock" 2>/dev/null || true
    rm -f "$home/.local/share/dbus-1/services/com.pibrick.Autorotation.service" 2>/dev/null || true
    rm -f "$home/.config/systemd/user/pibrick-rotation-ui.service" 2>/dev/null || true
done
# System plasmoid dir (not user-specific)
rm -rf /usr/share/plasma/plasmoids/pibrick-rotation-lock 2>/dev/null || true

# Remove Quick Drawer entry (Plasma Mobile top-pull panel tile)
info "Removing Quick Drawer entry..."
rm -rf /usr/share/plasma/quicksettings/org.kde.plasma.quicksetting.pibrick-autorotation 2>/dev/null || true
# Also remove any user-level copy
for home in /home/*; do
    rm -rf "$home/.local/share/plasma/quicksettings/org.kde.plasma.quicksetting.pibrick-autorotation" 2>/dev/null || true
done

# Strip our entry from each user's enabled-quick-settings list. If left in
# place after uninstall the Quick Settings UI silently loses a tile on every
# shell start, which looks like a regression.
info "Removing pibrick-autorotation from users' Quick Settings lists..."
for home in /home/*; do
    pmrc="$home/.config/plasmamobilerc"
    [ -f "$pmrc" ] || continue
    if grep -q 'pibrick-autorotation' "$pmrc"; then
        # Remove just our ID, with surrounding comma if present, from the
        # comma-separated list. Done with sed; if the line ends up empty the
        # shell will simply ignore it.
        sed -i 's/,\{0,1\}org\.kde\.plasma\.quicksetting\.pibrick-autorotation,*/,/g; \
                s/^enabledQuickSettings=,$//; \
                s/,,\+/,/g' "$pmrc"
    fi
done

# Scrub any leftover pibrick-rotation-lock entries from the Plasma Mobile
# panel config of every user. Earlier installs wrote them in and they can
# crash the panel containment; uninstall should leave the panel config
# clean so the top bar keeps rendering after uninstall.
info "Removing pibrick-rotation-lock entries from Plasma Mobile panel configs..."
for home in /home/*; do
    panel_cfg="$home/.config/plasma-org.kde.plasma.mobileshell-appletsrc"
    [ -f "$panel_cfg" ] || continue
    if grep -q "pibrick-rotation-lock" "$panel_cfg"; then
        perl -0777 -i -ne '
            my @lines = split /\n/, $_;
            my $i = 0;
            my @keep;
            while ($i < @lines) {
                if ($lines[$i] =~ /^\[Containments\]\[\d+\]\[Applets\]\[\d+\]\s*$/) {
                    my $j = $i + 1;
                    my %props;
                    while ($j < @lines && $lines[$j] =~ /^([^=]+)=(.*)$/) {
                        $props{$1} = $2;
                        $j++;
                    }
                    if (($props{plugin} // "") !~ /pibrick-rotation-lock/) {
                        push @keep, @lines[$i .. $j - 1];
                    }
                    $i = $j;
                } else {
                    push @keep, $lines[$i];
                    $i++;
                }
            }
            print join("\n", @keep);
            print "\n" if $keep[-1] !~ /^\n$/;
        ' "$panel_cfg"
    fi
done

info "Autorotation service uninstalled."
