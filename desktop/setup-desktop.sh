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

if ! python3 -c "import gi; gi.require_version('Gtk','3.0')" 2>/dev/null; then
	echo "Installing Gtk Python bindings for the battery indicator..."
	apt-get install -y python3-gi gir1.2-gtk-3.0 || true
fi

if ! python3 -c "import gi; gi.require_version('GtkLayerShell','0.1')" 2>/dev/null; then
	apt-get install -y gtk-layer-shell gir1.2-gtklayershell-0.1 2>/dev/null || true
fi

echo "piBrick battery taskbar indicator installed (autostart enabled)."
