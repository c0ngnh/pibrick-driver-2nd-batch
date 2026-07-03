#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/lib/pibrick/desktop"
AUTOSTART_DIR="/etc/xdg/autostart"

install -d "$INSTALL_DIR" "$AUTOSTART_DIR"

if [ "$(realpath "$SCRIPT_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
	install -m 755 "$SCRIPT_DIR/pibrick-battery-indicator.py" "$INSTALL_DIR/"
fi
install -m 644 "$SCRIPT_DIR/pibrick-battery-indicator.desktop" "$AUTOSTART_DIR/"

DISPLAY_SETTINGS="$SCRIPT_DIR/../tools/pibrick-display-settings.sh"
DISPLAY_DEFAULTS="$SCRIPT_DIR/../tools/pibrick-apply-display-defaults.sh"
GNOME_RATE_HELPER="$SCRIPT_DIR/../tools/gnome-display-rate.py"
TOUCH_RESET="$SCRIPT_DIR/../tools/pibrick-touch-reset.sh"
TOOLS_DIR="/usr/lib/pibrick/tools"

if [ -f "$DISPLAY_SETTINGS" ]; then
	install -m 755 "$DISPLAY_SETTINGS" /usr/local/bin/pibrick-display-settings
fi

if [ -f "$DISPLAY_DEFAULTS" ]; then
	install -m 755 "$DISPLAY_DEFAULTS" /usr/local/bin/pibrick-apply-display-defaults
	install -m 644 "$SCRIPT_DIR/pibrick-display-defaults.desktop" "$AUTOSTART_DIR/"
fi

if [ -f "$TOUCH_RESET" ]; then
	install -m 755 "$TOUCH_RESET" /usr/local/bin/pibrick-touch-reset
fi

PERSIST_PREFS="$SCRIPT_DIR/../tools/pibrick-persist-display-prefs.sh"
if [ -f "$PERSIST_PREFS" ]; then
	install -m 755 "$PERSIST_PREFS" /usr/local/bin/pibrick-persist-display-prefs
fi

SYNC_PREFS_SERVICE="$SCRIPT_DIR/pibrick-sync-display-prefs.service"
if [ -f "$SYNC_PREFS_SERVICE" ]; then
	install -d /etc/systemd/user
	install -m 644 "$SYNC_PREFS_SERVICE" /etc/systemd/user/pibrick-sync-display-prefs.service
	for user_home in /home/*; do
		[ -d "$user_home" ] || continue
		user_name=$(basename "$user_home")
		id "$user_name" >/dev/null 2>&1 || continue
		sudo -u "$user_name" XDG_RUNTIME_DIR="/run/user/$(id -u "$user_name")" \
			systemctl --user daemon-reload 2>/dev/null || true
		sudo -u "$user_name" XDG_RUNTIME_DIR="/run/user/$(id -u "$user_name")" \
			systemctl --user enable pibrick-sync-display-prefs.service 2>/dev/null || true
	done
fi

TOUCH_RECOVER_SERVICE="$SCRIPT_DIR/pibrick-touch-recover.service"
if [ -f "$TOUCH_RECOVER_SERVICE" ]; then
	install -m 644 "$TOUCH_RECOVER_SERVICE" /etc/systemd/system/pibrick-touch-recover.service
	systemctl daemon-reload
	systemctl enable pibrick-touch-recover.service
fi

BRIGHTNESS_HELPER="$SCRIPT_DIR/../tools/pibrick-brightness.sh"
if [ -f "$BRIGHTNESS_HELPER" ]; then
	install -m 755 "$BRIGHTNESS_HELPER" /usr/local/bin/pibrick-brightness
	apt-get install -y brightnessctl 2>/dev/null || true
	/usr/local/bin/pibrick-brightness install-labwc || true
fi

DISABLE_BAT_SHUTDOWN="$SCRIPT_DIR/../tools/pibrick-disable-battery-shutdown.sh"
if [ -f "$DISABLE_BAT_SHUTDOWN" ]; then
	install -m 755 "$DISABLE_BAT_SHUTDOWN" /usr/local/bin/pibrick-disable-battery-shutdown
	install -m 644 "$SCRIPT_DIR/pibrick-disable-battery-shutdown.desktop" "$AUTOSTART_DIR/"
fi

if [ -f "$GNOME_RATE_HELPER" ]; then
	install -d "$TOOLS_DIR"
	if [ "$(realpath "$GNOME_RATE_HELPER")" != "$(realpath "$TOOLS_DIR/gnome-display-rate.py" 2>/dev/null)" ]; then
		install -m 755 "$GNOME_RATE_HELPER" "$TOOLS_DIR/gnome-display-rate.py"
	fi
fi

if ! python3 -c "import gi; gi.require_version('Gtk','3.0')" 2>/dev/null; then
	echo "Installing Gtk Python bindings for the battery indicator..."
	apt-get install -y python3-gi gir1.2-gtk-3.0 || true
fi

if ! python3 -c "import gi; gi.require_version('Gio','2.0')" 2>/dev/null; then
	apt-get install -y python3-gi gir1.2-gio-2.0 2>/dev/null || true
fi

if ! python3 -c "import dbus" 2>/dev/null; then
	apt-get install -y python3-dbus 2>/dev/null || true
fi

if ! python3 -c "import gi; gi.require_version('GtkLayerShell','0.1')" 2>/dev/null; then
	apt-get install -y gtk-layer-shell gir1.2-gtklayershell-0.1 2>/dev/null || true
fi

if ! command -v wlr-randr >/dev/null 2>&1; then
	apt-get install -y wlr-randr 2>/dev/null || true
fi

echo "piBrick battery taskbar indicator installed (autostart enabled)."
echo "Display settings: pibrick-display-settings"
echo "Brightness keys (Pi OS / labwc): pibrick-brightness up|down (XF86MonBrightness keys)"
echo "Default refresh: 90 Hz for 9203 (applied on login via pibrick-apply-display-defaults)"
