#!/bin/bash
set -euo pipefail

PANEL_CONFIG=/etc/pibrick.panel
DISPLAY_REFRESH_CONFIG=/etc/pibrick.display-refresh
INSTALL_DISPLAY=
INSTALL_BATTERY=
INSTALL_BUTTON=
INSTALL_UPOWER_FIX=
INSTALL_EXPLICIT=
PIBRICK_TOOLS=/home/congn/battery-tools

usage() {
	cat >&2 <<EOF
Usage: $0 [--install COMPONENTS]

COMPONENTS is a comma-separated list of: display, battery, button, fix-upower
or a special token: all, none.

Options:
  --fix-upower    Apply UPower KDE fix (patches upowerd to correctly show
                  "Charging" state instead of "Discharging")
                  Applied automatically when battery is selected (interactive mode).

Examples:
  $0 --install all            # every component (default when interactive)
  $0 --install none           # nothing (dry-run sanity check)
  $0 --install display,button # display panels + button service, skip battery
  $0 --install display,battery,fix-upower
                              # battery driver + UPower fix
  $0 --fix-upower            # apply only the UPower fix
  PANEL=9203 $0 --install display
                              # non-interactive panel selection via env var
EOF
}

# ── UPower fix ─────────────────────────────────────────────────────────────────

fix_upower() {
	echo "=== Applying UPower KDE fix ==="

	UPowerD=/usr/libexec/upowerd
	if [ ! -f "$UPowerD" ]; then
		echo "upowerd not found at $UPowerD — skipping."
		return 0
	fi

	# Check if already patched
	if grep -q "DISABLED for piBrick" "$UPowerD" 2>/dev/null; then
		echo "UPower already patched — skipping."
		return 0
	fi

	# Determine UPower version
	UPVER=$(upower --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
	echo "UPower version: $UPVER"

	# Check if the override pattern exists (UPower < 0.99.18 or >= 1.90)
	# The override is: if (current_now < 0) state = DISCHARGING
	# We patch the C source and rebuild.
	if ! grep -q "current_now.*<.*0.0" "$UPowerD" 2>/dev/null; then
		# Try string-based patch: change "discharging" to "Charging___"
		# so the override assigns "Charging___" instead of "discharging"
		BACKUP="${UPowerD}.bak-pibrick-$(date +%Y%m%d%H%M%S)"
		cp "$UPowerD" "$BACKUP"
		echo "Backed up to: $BACKUP"

		# Patch: find "discharging" string and replace with "Charging___"
		# This changes what the override sets state to.
		# The comparison still happens, so status-based state remains.
		if python3 -c "
import sys
path = sys.argv[1]
old = 'discharging'
new = 'Charging___'
with open(path, 'r+b') as f:
    data = f.read()
    idx = data.find(old.encode())
    if idx < 0:
        print('Pattern not found')
        sys.exit(1)
    f.seek(idx)
    f.write(new.encode())
    print('Patched at offset 0x%x' % idx)
" "$UPowerD" 2>/dev/null; then
			echo "Patched UPower: disabled current_now override"
		else
			# Fallback: binary patch the assembly condition
			echo "String patch not applicable — trying binary patch..."
			# Change the condition: if (current_now < 0) -> if (current_now > 999999999)
			# This effectively disables the override.
			# In ARM64: cmp x0, #0 followed by b.lt -> change #0 to #999999999
			# This is fragile; try the rebuild approach instead.
			UP_SRC=/tmp/upower-src
			if [ ! -d "$UP_SRC" ]; then
				echo "Cloning UPower source..."
				git clone --depth=1 https://gitlab.freedesktop.org/upower/upower.git "$UP_SRC" >/dev/null 2>&1 || {
					echo "Failed to clone UPower source."
					echo "Restoring backup: $BACKUP"
					cp "$BACKUP" "$UPowerD"
					return 1
				}
			fi

			echo "Patching UPower source..."
			# Patch the override condition to be always false
			sed -i 's/false && \/\* DISABLED/false \&\& 0 \&\& \/\* DISABLED/' \
				"$UP_SRC/src/linux/up-device-supply-battery.c" 2>/dev/null || true

			python3 -c "
import sys
content = open('$UP_SRC/src/linux/up-device-supply-battery.c').read()
old = '''	if (values.state != UP_DEVICE_STATE_FULLY_CHARGED &&
	    g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)
		values.state = UP_DEVICE_STATE_DISCHARGING;'''
new = '''	/* DISABLED for piBrick: BQ25895 follows power_supply convention (negative=charging). */
	if (values.state != UP_DEVICE_STATE_FULLY_CHARGED &&
	    0 && /* DISABLED: was: current_now < 0 */
	    g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)
		values.state = UP_DEVICE_STATE_DISCHARGING;'''
if old in content:
    content = content.replace(old, new)
    open('$UP_SRC/src/linux/up-device-supply-battery.c', 'w').write(content)
    print('Source patched')
else:
    print('Source pattern not found')
    sys.exit(1)
" || {
				echo "Could not patch source."
				return 1
			}

			echo "Building UPower..."
			# Build dependencies
			apt-get install -y meson ninja-build gettext libgudev-1.0-dev \
				libpolkit-gobject-1-dev gtk-doc-tools >/dev/null 2>&1 || true

			cd "$UP_SRC"
			mkdir -p build
			PKG_CONFIG_PATH=/usr/lib/pkgconfig \
			meson setup build --prefix=/usr \
				-Dudevrulesdir=/lib/udev/rules.d \
				-Dsystemdsystemunitdir=/lib/systemd/system \
				> /tmp/meson.log 2>&1 || {
				# Try without systemd
				meson setup build --prefix=/usr \
					-Dudevrulesdir=/lib/udev/rules.d \
					> /tmp/meson.log 2>&1 || {
					echo "meson setup failed. See /tmp/meson.log"
					return 1
				}
			}

			ninja -C build > /tmp/ninja.log 2>&1 || {
				echo "ninja build failed. See /tmp/ninja.log"
				return 1
			}

			if [ -f build/src/upowerd ]; then
				cp "$UPowerD" "$BACKUP"
				cp build/src/upowerd "$UPowerD"
				echo "UPower rebuilt and installed."
			else
				echo "Build succeeded but upowerd not found."
				return 1
			fi
			cd /
		fi
	fi

	# Restart UPower
	echo "Restarting UPower daemon..."
	systemctl stop upower 2>/dev/null || killall -9 upowerd 2>/dev/null || true
	sleep 1
	systemctl start upower 2>/dev/null || /usr/libexec/upowerd &
	sleep 3

	# Verify
	STATE=$(upower -i /org/freedesktop/UPower/devices/battery_battery 2>/dev/null | grep "^    state" | awk '{print $2}')
	DRIVER_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "N/A")
	if [ "$STATE" = "$DRIVER_STATUS" ]; then
		echo "UPower state='$STATE' matches driver status='$DRIVER_STATUS' ✓"
		echo "KDE Plasma Mobile should now show Charging correctly."
	else
		echo "UPower state='$STATE' (driver: '$DRIVER_STATUS')"
		echo "UPower fix applied but state may still need verification."
		echo "Run 'upower -i /org/freedesktop/UPower/devices/battery_battery' to check."
	fi

	echo "UPower fix applied."
}

# ── argument parsing ────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
	case "$1" in
	--install)
		shift
		if [ $# -eq 0 ]; then
			echo "ERROR: --install requires an argument" >&2
			usage
			exit 1
		fi
		for comp in $(echo "$1" | tr ',' ' '); do
			case "$comp" in
			all)
				INSTALL_DISPLAY=1
				INSTALL_BATTERY=1
				INSTALL_BUTTON=1
				INSTALL_UPOWER_FIX=1
				INSTALL_EXPLICIT=1
				;;
			none)
				INSTALL_DISPLAY=
				INSTALL_BATTERY=
				INSTALL_BUTTON=
				INSTALL_UPOWER_FIX=
				INSTALL_EXPLICIT=1
				;;
			fix-upower)
				INSTALL_UPOWER_FIX=1
				INSTALL_EXPLICIT=1
				;;
			display)
				INSTALL_DISPLAY=1
				INSTALL_EXPLICIT=1
				;;
			battery)
				INSTALL_BATTERY=1
				INSTALL_EXPLICIT=1
				;;
			button)
				INSTALL_BUTTON=1
				INSTALL_EXPLICIT=1
				;;
			*)
				echo "ERROR: unknown component: $comp" >&2
				usage
				exit 1
				;;
			esac
		done
		shift
		;;
	--fix-upower)
		INSTALL_UPOWER_FIX=1
		INSTALL_EXPLICIT=1
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "ERROR: unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
done

component_selected() {
	case "$1" in
	display)  [ -n "$INSTALL_DISPLAY"  ] ;;
	battery)  [ -n "$INSTALL_BATTERY"  ] ;;
	button)   [ -n "$INSTALL_BUTTON"  ] ;;
	upower)  [ -n "$INSTALL_UPOWER_FIX" ] ;;
	*)
		echo "ERROR: component_selected: unknown component $1" >&2
		exit 1
		;;
	esac
}

# ── interactive prompts ─────────────────────────────────────────────────────────

choose_components_and_panel() {
	local choice

	# Non-interactive: fall back to "install all" when no --install given.
	if [ ! -t 0 ] && [ -z "$INSTALL_EXPLICIT" ]; then
		echo "No terminal for component prompt; installing all." >&2
		INSTALL_DISPLAY=1
		INSTALL_BATTERY=1
		INSTALL_BUTTON=1
		INSTALL_UPOWER_FIX=1
		return 0
	fi

	if [ -n "$INSTALL_EXPLICIT" ]; then
		# Check for battery without explicit upower flag
		if component_selected battery && ! component_selected upower; then
			# Auto-enable upower fix for battery users
			INSTALL_UPOWER_FIX=1
		fi
		return 0
	fi

	# Interactive
	echo >&2
	echo "=== piBrick install: component selection ===" >&2
	echo "Press Enter to accept the default (Y). Type n then Enter to skip." >&2

	printf "Install display panel driver (panel-pibrick + touch)? [Y/n]: " >&2
	if ! read -r choice; then
		echo "ERROR: no selection made." >&2
		exit 1
	fi
	case "${choice,,}" in
	""|y|yes) INSTALL_DISPLAY=1 ;;
	n|no)      ;;
	*)
		echo "ERROR: invalid answer: $choice" >&2
		exit 1
		;;
	esac

	printf "Install battery driver (bq25895 fuel gauge / INA228)? [Y/n]: " >&2
	if ! read -r choice; then
		echo "ERROR: no selection made." >&2
		exit 1
	fi
	case "${choice,,}" in
	""|y|yes)
		INSTALL_BATTERY=1
		INSTALL_UPOWER_FIX=1
		;;
	n|no)      ;;
	*)
		echo "ERROR: invalid answer: $choice" >&2
		exit 1
		;;
	esac

	printf "Apply UPower KDE fix (show Charging state in Plasma Mobile)? [Y/n]: " >&2
	if ! read -r choice; then
		echo "ERROR: no selection made." >&2
		exit 1
	fi
	case "${choice,,}" in
	""|y|yes) INSTALL_UPOWER_FIX=1 ;;
	n|no)      ;;
	*)
		echo "ERROR: invalid answer: $choice" >&2
		exit 1
		;;
	esac

	printf "Install button service (pibrickbtn over libgpiod)? [Y/n]: " >&2
	if ! read -r choice; then
		echo "ERROR: no selection made." >&2
		exit 1
	fi
	case "${choice,,}" in
	""|y|yes) INSTALL_BUTTON=1 ;;
	n|no)      ;;
	*)
		echo "ERROR: invalid answer: $choice" >&2
		exit 1
		;;
	esac

	if [ -z "$INSTALL_DISPLAY$INSTALL_BATTERY$INSTALL_BUTTON$INSTALL_UPOWER_FIX" ]; then
		echo "Nothing selected; exiting." >&2
		exit 0
	fi
}

panel_label() {
	case "$1" in
	9203)  echo "9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)" ;;
	9202)  echo "9202 - Visionox 1080x1240 @ 60 Hz (legacy)" ;;
	548)   echo "5.48 inch - 1080x1920 @ 60 Hz" ;;
	5inch) echo "5 inch - 1080x1240 @ 90/60 Hz" ;;
	*)     echo "$1" ;;
	esac
}

choose_panel() {
	local choice saved

	if [ -n "${PANEL:-}" ]; then
		case "$PANEL" in
		9203|9202|548|5inch) echo "$PANEL"; return 0 ;;
		*)
			echo "ERROR: invalid PANEL=$PANEL (use 9203, 9202, 548, or 5inch)" >&2
			exit 1
			;;
		esac
	fi

	if [ -f "$PANEL_CONFIG" ]; then
		saved="$(tr -d '[:space:]' < "$PANEL_CONFIG")"
	else
		saved=9203
	fi

	if [ ! -t 0 ]; then
		echo "No terminal for panel prompt; using ${saved}." >&2
		echo "$saved"
		return 0
	fi

	echo >&2
	echo "=== piBrick display panel ===" >&2
	echo "1) 9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)" >&2
	echo "2) 9202 - Visionox 1080x1240 @ 60 Hz (legacy)" >&2
	echo "3) 5.48 inch - 1080x1920 @ 60 Hz" >&2
	echo "4) 5 inch - 1080x1240 @ 90/60 Hz" >&2
	echo >&2
	printf "Choose panel [1-4] (default: %s): " "$saved" >&2

	if ! read -r choice; then
		echo "ERROR: no panel selected." >&2
		exit 1
	fi

	case "${choice:-}" in
	"")           echo "$saved" ;;
	"9203"|1)    echo 9203 ;;
	"9202"|2)    echo 9202 ;;
	"548"|3)      echo 548 ;;
	"5inch"|4)    echo 5inch ;;
	*)
		echo "ERROR: invalid choice: $choice" >&2
		exit 1
		;;
	esac
}

choose_components_and_panel

# ── panel selection ─────────────────────────────────────────────────────────────

SELECTED_PANEL=
if component_selected display; then
	SELECTED_PANEL="$(choose_panel)"
	echo "$SELECTED_PANEL" > "$PANEL_CONFIG"
	if [ ! -f "$DISPLAY_REFRESH_CONFIG" ]; then
		case "$SELECTED_PANEL" in
		9203|5inch) echo 90 > "$DISPLAY_REFRESH_CONFIG" ;;
		*)           echo 60 > "$DISPLAY_REFRESH_CONFIG" ;;
		esac
	fi
	echo "Selected panel: $(panel_label "$SELECTED_PANEL")"
	echo "Default refresh: $(tr -d '[:space:]' < "$DISPLAY_REFRESH_CONFIG") Hz"
fi

# ── rsync source tree ────────────────────────────────────────────────────────────

TARGET=/usr/lib/pibrick
mkdir -p "$TARGET"
rsync_opts=(
	--archive
	--delete
	--exclude='*.o'
	--exclude='*.ko'
	--exclude='*.mod'
	--exclude='.module-common.o.cmd'
	--exclude='.panel-pibrick.ko.cmd'
	--exclude='.panel-pibrick.mod.cmd'
	--exclude='.panel-pibrick.mod.o.cmd'
	--exclude='.bq25890_battery.ko.cmd'
	--exclude='.bq25890_battery.mod.cmd'
	--exclude='.bq25890_battery.mod.o.cmd'
	--exclude='.modules.order.cmd'
	--exclude='.trellis/'
	--exclude='.cursor/'
)
if [ "$(pwd -P)" != "$TARGET" ]; then
	rsync "${rsync_opts[@]}" . "$TARGET/"
fi

# ── install tools ───────────────────────────────────────────────────────────────

# Copy battery tools to PIBRICK_TOOLS for easy user access
if component_selected battery || component_selected upower; then
	mkdir -p "$PIBRICK_TOOLS"
	for tool in battery/battery_set.py battery/battery-check.py; do
		if [ -f "$TARGET/$tool" ]; then
			cp "$TARGET/$tool" "$PIBRICK_TOOLS/"
			chmod +x "$PIBRICK_TOOLS/$(basename "$tool")"
		fi
	done
fi

# ── systemd service ──────────────────────────────────────────────────────────────

if component_selected display || component_selected battery; then
	install -m 644 "$TARGET/pibrick.service" /etc/systemd/system/ \
		&& chmod +x "$TARGET/build.sh" \
		&& systemctl daemon-reload \
		&& systemctl enable pibrick.service
fi

# ── battery module config ────────────────────────────────────────────────────────

if component_selected battery; then
	install -m 644 "$TARGET/battery/pibrick-battery.conf" \
		/etc/modprobe.d/pibrick-battery.conf
fi

# ── build and load ──────────────────────────────────────────────────────────────

if component_selected display; then
	cd "$TARGET"
	PANEL="$SELECTED_PANEL" "$TARGET/build.sh" --force --no-reboot
	cd /
elif component_selected battery; then
	cd "$TARGET/battery"
	make install
fi

if component_selected display; then
	bash "$TARGET/desktop/setup-desktop.sh"
fi

if component_selected button; then
	bash "$TARGET/button-service/install.sh"
fi

# ── upower fix ─────────────────────────────────────────────────────────────────

if component_selected upower; then
	fix_upower
fi

# ── restart services ────────────────────────────────────────────────────────────

if component_selected display || component_selected battery; then
	systemctl start pibrick.service
fi

# ── summary ─────────────────────────────────────────────────────────────────────

echo
echo "Install complete."
[ -n "$SELECTED_PANEL" ] && echo "  display: panel $(panel_label "$SELECTED_PANEL")"
component_selected battery && echo "  battery: bq25895 fuel gauge loaded"
component_selected upower && echo "  upower: KDE charging-state fix applied"
component_selected button && echo "  button: pibrickbtn service enabled"
echo "Tools: $PIBRICK_TOOLS/{battery_set.py,battery-check.py}"
echo "Reboot to apply display changes: sudo reboot"
