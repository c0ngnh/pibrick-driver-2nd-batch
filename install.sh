#!/bin/bash
#
# piBrick Driver Installer
# Interactive installer for piBrick PocketCM5 drivers and tools
#
# Usage:
#   ./install.sh              # Interactive mode
#   ./install.sh --install x  # Non-interactive (see --help)
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Config paths ───────────────────────────────────────────────────────────────
PANEL_CONFIG=/etc/pibrick.panel
DISPLAY_REFRESH_CONFIG=/etc/pibrick.display-refresh
PIBRICK_TOOLS=/home/congn/battery-tools
PIBRICK_LIB=/usr/lib/pibrick

# ── Component flags ─────────────────────────────────────────────────────────────
INSTALL_DISPLAY=
INSTALL_BATTERY_NEW=           # Battery driver with INA228 auto-detection at runtime
INSTALL_BATTERY_ORIGINAL=     # Alias for INSTALL_BATTERY_NEW (kept for compat)
INSTALL_CALIBRATION=
INSTALL_UPower=
INSTALL_BUTTON=
INSTALL_EXPLICIT=

# ── Calibration functions (must be defined before use) ──────────────────────────
status_calibration() {
	if [ ! -f /var/log/bq25890_battery/calibration_status.json ]; then
		echo "No calibration data found."
		echo "Run calibration logger first: sudo systemctl start pibrick-battery-calibration"
		return 1
	fi
	python3 /home/congn/battery-tools/battery-auto-calibrator.py --status 2>/dev/null || \
		cat /var/log/bq25890_battery/calibration_status.json
}

apply_calibration() {
	info "Checking calibration status..."

	if [ ! -f /home/congn/battery-tools/battery-auto-calibrator.py ]; then
		error "Auto-calibrator not installed. Run: $0 --install calibration"
		return 1
	fi

	python3 /home/congn/battery-tools/battery-auto-calibrator.py --apply
}

# ── Battery status (shows current params + persisted config) ──────────────────
battery_status() {
	info "Battery status & custom values"

	if [ ! -f "$PIBRICK_TOOLS/battery_set.py" ]; then
		error "battery_set.py not installed. Run: $0 --install battery"
		return 1
	fi

	echo
	echo -e "${BOLD}=== Current Driver Values (live) ===${RESET}"
	python3 "$PIBRICK_TOOLS/battery_set.py" --show

	echo
	echo -e "${BOLD}=== Persisted Config (/etc/modprobe.d/pibrick-battery.conf) ===${RESET}"
	if [ -f /etc/modprobe.d/pibrick-battery.conf ]; then
		cat /etc/modprobe.d/pibrick-battery.conf
	else
		echo "(none — no values persisted yet)"
	fi

	echo
	echo -e "${BOLD}=== Driver Defaults (compile-time) ===${RESET}"
	python3 "$PIBRICK_TOOLS/battery_set.py" --list 2>&1 | \
		grep -E "Driver Default" || true

	echo
	echo -e "${BOLD}=== Quick SOC Readout ===${RESET}"
	if [ -f /sys/class/power_supply/battery/capacity ]; then
		SOC=$(cat /sys/class/power_supply/battery/capacity)
		STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")
		V=$(($(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0) / 1000))
		I_UA=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
		I_MA=$(awk "BEGIN {printf \"%.0f\", ${I_UA}/1000}")
		echo "  SOC:        ${SOC}%"
		echo "  Status:     ${STATUS}"
		echo "  Voltage:    ${V} mV"
		echo "  Current:    ${I_MA} mA"
	else
		echo "  (battery power_supply not found — is the driver loaded?)"
	fi
}

# ── Battery configuration (interactive / non-interactive) ─────────────────────
battery_config() {
	local persist_flag=""
	local force_flag=""
	local extra_args=()

	# Parse remaining args after --battery-config
	shift 2>/dev/null || true
	while [ $# -gt 0 ]; do
		case "$1" in
		--persist) persist_flag="1" ;;
		--force)   force_flag="1" ;;
		--list)    extra_args+=("--list") ;;
		--list-verbose) extra_args+=("--list-verbose") ;;
		--show)    extra_args+=("--show") ;;
		*)         extra_args+=("$1") ;;
		esac
		shift
	done

	if [ ! -f "$PIBRICK_TOOLS/battery_set.py" ]; then
		error "battery_set.py not installed. Run: $0 --install battery"
		return 1
	fi

	# If no extra args, run interactive mode
	if [ ${#extra_args[@]} -eq 0 ]; then
		info "Launching interactive battery configuration..."
		# Need to be a TTY for interactive; just exec directly
		python3 "$PIBRICK_TOOLS/battery_set.py"
		return $?
	fi

	# Non-interactive path: build command using string concat (preserves args with spaces)
	local cmd="python3 $PIBRICK_TOOLS/battery_set.py"
	for a in "${extra_args[@]}"; do
		cmd="$cmd \"$a\""
	done
	[ -n "$persist_flag" ] && cmd="$cmd --persist"
	[ -n "$force_flag" ] && cmd="$cmd --force"

	info "Running: $cmd"
	# shellcheck disable=SC2086
	eval $cmd
}

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
	cat <<EOF
${BOLD}piBrick Driver Installer${RESET}

${BOLD}Usage:${RESET}
  $0              # Interactive mode
  $0 --install x  # Non-interactive

${BOLD}Display Components (panel selection):${RESET}
  display          Display + Touch (select 9203/9202/548/5inch interactively)
  display-hyn     Display + Hyn touch driver only

${BOLD}Battery Components:${RESET}
  battery          Battery driver (bq25895, INA228 auto-detected at runtime)
  battery-new      Battery driver (bq25895 + INA228) [recommended]
  calibration      Calibration logger + auto-calibrator

${BOLD}Other Components:${RESET}
  upower           UPower KDE fix (show Charging state)
  button           Button service (pibrickbtn over libgpiod)

${BOLD}All Components:${RESET}
  all              Install display + battery-new + calibration + upower + button

${BOLD}Options:${RESET}
  --apply-calibration       Apply calibrated OCV table to installed driver
  --status-calibration      Show calibration status
  --enable-calibration      Enable calibration logging service
  --disable-calibration     Disable calibration logging service
  --battery-status          Show current battery params + persisted config
  --battery-config [args]   Configure battery driver params (interactive)
                              Args forwarded to battery_set.py:
                                <param> <value>    Set value
                                --persist          Save to modprobe.d + reload driver
                                --force            Bypass safety checks (coulomb_uah)
                                --show             Show all current values
                                --list             List all parameters
  -h, --help                Show this help

${BOLD}Examples:${RESET}
  $0 --install all              # Install everything
  $0 --install display          # Display with interactive panel selection
  $0 --install battery-new      # Battery with INA228
  $0 --apply-calibration       # Apply calibrated OCV table
  $0 --status-calibration      # Check calibration status
  $0 --enable-calibration      # Start calibration logging
  $0 --disable-calibration     # Stop calibration logging
  $0 --battery-status          # Show all battery parameters + persisted config
  $0 --battery-config          # Interactive battery parameter setter
  $0 --battery-config charge_full_uah 3800 mAh --persist
                                # Set 3800mAh battery capacity and persist it

${BOLD}Environment:${RESET}
  PANEL=9203  Select panel (9203, 9202, 548, 5inch)
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
	--install)
		shift
		[ $# -eq 0 ] && { error "--install requires argument"; usage; exit 1; }
		for comp in $(echo "$1" | tr ',' ' '); do
			case "$comp" in
			all)
				INSTALL_DISPLAY=1
				INSTALL_BATTERY_NEW=1
				INSTALL_CALIBRATION=1
				INSTALL_UPower=1
				INSTALL_BUTTON=1
				INSTALL_EXPLICIT=1
				;;
			none)
				INSTALL_EXPLICIT=1
				;;
			display)
				INSTALL_DISPLAY=1
				INSTALL_EXPLICIT=1
				;;
			display-hyn)
				INSTALL_DISPLAY=1
				INSTALL_BATTERY_ORIGINAL=1
				INSTALL_EXPLICIT=1
				;;
			battery-new)
				INSTALL_BATTERY_NEW=1
				INSTALL_EXPLICIT=1
				;;
			battery)
				INSTALL_BATTERY_ORIGINAL=1
				INSTALL_EXPLICIT=1
				;;
			calibration)
				INSTALL_CALIBRATION=1
				INSTALL_EXPLICIT=1
				;;
			upower)
				INSTALL_UPower=1
				INSTALL_EXPLICIT=1
				;;
			button)
				INSTALL_BUTTON=1
				INSTALL_EXPLICIT=1
				;;
			*)
				error "Unknown component: $comp"
				usage
				exit 1
				;;
			esac
		done
		shift
		;;
	--apply-calibration)
		apply_calibration
		exit $?
		;;
	--status-calibration)
		status_calibration
		exit $?
		;;
	--enable-calibration)
		systemctl enable pibrick-battery-calibration.service 2>/dev/null || true
		systemctl start pibrick-battery-calibration.service 2>/dev/null || true
		success "Calibration service enabled and started"
		exit 0
		;;
	--disable-calibration)
		systemctl stop pibrick-battery-calibration.service 2>/dev/null || true
		systemctl disable pibrick-battery-calibration.service 2>/dev/null || true
		success "Calibration service disabled and stopped"
		exit 0
		;;
	--battery-status)
		battery_status
		exit $?
		;;
	--battery-config)
		battery_config "$@"
		exit $?
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		error "Unknown argument: $1"
		usage
		exit 1
		;;
	esac
done

# ── Interactive prompts ───────────────────────────────────────────────────────
choose_components() {
	# Non-interactive: install all if no selection
	if [ ! -t 0 ] && [ -z "$INSTALL_EXPLICIT" ]; then
		info "No terminal detected. Installing all components."
		INSTALL_DISPLAY=1
		INSTALL_DISPLAY_NEW=1
		INSTALL_BATTERY=1
		INSTALL_CALIBRATION=1
		INSTALL_UPower=1
		INSTALL_BUTTON=1
		return 0
	fi

	[ -n "$INSTALL_EXPLICIT" ] && return 0

	echo
	echo -e "${BOLD}=== piBrick Driver Installer ===${RESET}"
	echo "Press Enter for default (recommended), or type 'n' to skip."

	prompt_yesno() {
		local prompt="$1"
		local var_name="$2"
		local default="${3:-y}"
		local choice
		printf "%s [%s]: " "$prompt" "$default" >&2
		read -r choice || return 1
		case "${choice,,}" in
		""|y|yes) eval "$var_name=1" ;;
		n|no) eval "$var_name=" ;;
		*) error "Invalid answer: $choice"; return 1 ;;
		esac
	}

	# Display - Panel selection
	echo
	echo -e "${BOLD}=== Display Panel Selection ===${RESET}"
	echo "Select your panel type:"
	echo "  1) 9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)"
	echo "  2) 9202 - Visionox 1080x1240 @ 60 Hz (legacy)"
	echo "  3) 548 - 5.48 inch 1080x1920 @ 60 Hz (FocalTech touch)"
	echo "  4) 5inch - 5 inch 1080x1240 @ 90/60 Hz"
	echo "  5) Skip display installation"
	echo -n "Choose [1]: " >&2
	read -r panel_choice || panel_choice=1
	case "${panel_choice:-1}" in
	1) INSTALL_DISPLAY=1; PANEL=9203 ;;
	2) INSTALL_DISPLAY=1; PANEL=9202 ;;
	3) INSTALL_DISPLAY=1; PANEL=548 ;;
	4) INSTALL_DISPLAY=1; PANEL=5inch ;;
	5) ;; # Skip
	*) INSTALL_DISPLAY=1; PANEL=9203 ;;
	esac

	# Battery driver type
	echo
	echo -e "${BOLD}=== Battery Driver Selection ===${RESET}"
	echo "  1) Battery + INA228 (recommended) - High-precision current sensor"
	echo "  2) Battery only (original) - If no INA228 hardware installed"
	echo -n "Choose [1]: " >&2
	read -r batt_choice || batt_choice=1
	case "${batt_choice:-1}" in
	2) INSTALL_BATTERY_ORIGINAL=1 ;;
	*) INSTALL_BATTERY_NEW=1 ;;
	esac

	prompt_yesno "Install Calibration Tools (logger + auto-calibrator)" INSTALL_CALIBRATION
	prompt_yesno "Apply UPower KDE Fix (show Charging state)" INSTALL_UPower
	prompt_yesno "Install Button Service (pibrickbtn)" INSTALL_BUTTON

	if [ -z "$INSTALL_DISPLAY$INSTALL_BATTERY$INSTALL_CALIBRATION$INSTALL_UPower$INSTALL_BUTTON" ]; then
		error "Nothing selected. Exiting."
		exit 0
	fi
}

# ── Panel selection ────────────────────────────────────────────────────────────
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
	if [ -n "${PANEL:-}" ]; then
		case "$PANEL" in
		9203|9202|548|5inch) echo "$PANEL"; return 0 ;;
		*) error "Invalid PANEL=$PANEL (use 9203, 9202, 548, or 5inch)"; exit 1 ;;
		esac
	fi

	if [ -f "$PANEL_CONFIG" ]; then
		local saved
		saved=$(tr -d '[:space:]' < "$PANEL_CONFIG")
	else
		saved=9203
	fi

	echo
	echo -e "${BOLD}=== Display Panel Selection ===${RESET}"
	echo "1) 9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default)"
	echo "2) 9202 - Visionox 1080x1240 @ 60 Hz (legacy)"
	echo "3) 5.48 inch - 1080x1920 @ 60 Hz"
	echo "4) 5 inch - 1080x1240 @ 90/60 Hz"
	echo -n "Choose [1]: " >&2
	read -r choice || choice=1

	case "${choice:-1}" in
	""|"9203"|1) echo 9203 ;;
	"9202"|2)    echo 9202 ;;
	"548"|3)      echo 548 ;;
	"5inch"|4)    echo 5inch ;;
	*)            echo 9203 ;;
	esac
}

# ── UPower fix ─────────────────────────────────────────────────────────────────
fix_upower() {
	info "Applying UPower KDE fix..."

	local UPowerD=/usr/libexec/upowerd
	if [ ! -f "$UPowerD" ]; then
		warn "upowerd not found at $UPowerD — skipping."
		return 0
	fi

	if grep -q "piBrick: disabled" "$UPowerD" 2>/dev/null; then
		success "UPower already patched."
		restart_upower
		return 0
	fi

	info "Patching UPower (rebuild from source)..."
	local UPVER
	UPVER=$(upower --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
	info "UPower daemon version: $UPVER"

	local UP_SRC=/tmp/upower-pibrick-src
	if [ ! -d "$UP_SRC/.git" ]; then
		info "Cloning UPower source (tag v$UPVER)..."
		rm -rf "$UP_SRC"
		git clone --depth=1 --branch="v$UPVER" \
			https://gitlab.freedesktop.org/upower/upower.git "$UP_SRC" >/dev/null 2>&1 || {
			git clone --depth=1 \
				https://gitlab.freedesktop.org/upower/upower.git "$UP_SRC" >/dev/null 2>&1 || {
					error "Failed to clone UPower source."
					return 1
				}
		}
	fi

	local BAK="${UPowerD}.bak-pibrick-$(date +%Y%m%d%H%M%S)"
	cp "$UPowerD" "$BAK"
	info "Backed up to: $BAK"

	python3 -c "
import sys
content = open('$UP_SRC/src/linux/up-device-supply-battery.c').read()
old = '''	if (values.state != UP_DEVICE_STATE_FULLY_CHARGED &&
	    g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)
		values.state = UP_DEVICE_STATE_DISCHARGING;'''
new = '''	/* piBrick: disabled — BQ25895 follows power_supply convention (negative=charging).
	 * Restore this block if your hardware reports status=Charging when discharging. */
	if (values.state != UP_DEVICE_STATE_FULLY_CHARGED &&
	    0 && /* DISABLED: was: current_now < 0 */
	    g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)
		values.state = UP_DEVICE_STATE_DISCHARGING;'''
if old in content:
    content = content.replace(old, new)
    open('$UP_SRC/src/linux/up-device-supply-battery.c', 'w').write(content)
    print('Source patched: disabled current_now override')
else:
    print('Source pattern not found — trying alternate pattern...')
    content = content.replace(
        'g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)',
        '0 && /* DISABLED */ g_udev_device_get_sysfs_attr_as_double_uncached (native, \"current_now\") < 0.0)'
    )
    open('$UP_SRC/src/linux/up-device-supply-battery.c', 'w').write(content)
    print('Source patched via sed replacement')
"

	info "Building UPower..."
	cd "$UP_SRC"
	mkdir -p build
	PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig \
		meson setup build --prefix=/usr \
			-Dudevrulesdir=/lib/udev/rules.d \
			-Dsystemdsystemunitdir=/lib/systemd/system \
			> /tmp/meson-pibrick.log 2>&1 || {
		error "meson setup failed. See /tmp/meson-pibrick.log"
		cp "$BAK" "$UPowerD"
		return 1
	}

	ninja -C build > /tmp/ninja-pibrick.log 2>&1 || {
		error "ninja build failed. See /tmp/ninja-pibrick.log"
		cp "$BAK" "$UPowerD"
		return 1
	}

	if [ ! -f build/src/upowerd ]; then
		error "Build succeeded but upowerd not found."
		cp "$BAK" "$UPowerD"
		return 1
	fi

	cp "$BAK" "$UPowerD" 2>/dev/null || cp "$BAK" "$UPowerD"
	cp build/src/upowerd "$UPowerD"
	chmod +x "$UPowerD"
	cd /

	success "UPower rebuilt successfully."
	restart_upower
}

restart_upower() {
	info "Restarting UPower daemon..."
	systemctl --user stop upower 2>/dev/null || \
		sudo systemctl stop upower 2>/dev/null || \
		killall -9 upowerd 2>/dev/null || true
	sleep 2
	/usr/libexec/upowerd &
	sleep 4

	local STATE
	STATE=$(upower -i /org/freedesktop/UPower/devices/battery_battery 2>/dev/null \
		| awk '/^    state:/{print $2}')
	local DRIVER_STATUS
	DRIVER_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "N/A")
	info "UPower state='$STATE'  driver status='$DRIVER_STATUS'"
	if [ "$STATE" = "$DRIVER_STATUS" ]; then
		success "UPower fix verified."
	else
		warn "UPower state doesn't match driver. Reboot may be needed."
	fi
}

# ── Copy source tree ────────────────────────────────────────────────────────────
copy_sources() {
	info "Copying source files to $PIBRICK_LIB..."
	mkdir -p "$PIBRICK_LIB"
	rsync_opts=(
		--archive
		--delete
		--exclude='*.o'
		--exclude='*.ko'
		--exclude='*.mod'
		--exclude='.module-common.o.cmd'
		--exclude='.panel-pibrick.ko.cmd'
		--exclude='.bq25890_battery.ko.cmd'
		--exclude='.trellis/'
		--exclude='.cursor/'
	)
	if [ "$(pwd -P)" != "$PIBRICK_LIB" ]; then
		rsync "${rsync_opts[@]}" . "$PIBRICK_LIB/"
	fi
}

# ── Install tools ───────────────────────────────────────────────────────────────
install_tools() {
	mkdir -p "$PIBRICK_TOOLS"

	# Battery tools
	if [ -f battery/battery_set.py ]; then
		cp battery/battery_set.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery_set.py"
		success "Installed: battery_set.py"
	fi

	if [ -f battery/battery-check.py ]; then
		cp battery/battery-check.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-check.py"
		success "Installed: battery-check.py"
	fi

	# Calibration tools
	if [ -f battery/battery-soc-persist.py ]; then
		cp battery/battery-soc-persist.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-soc-persist.py"
		success "Installed: battery-soc-persist.py"
	fi

	if [ -f battery/battery-calibration-logger.py ]; then
		cp battery/battery-calibration-logger.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-calibration-logger.py"
		success "Installed: battery-calibration-logger.py"
	fi

	if [ -f battery/battery-auto-calibrator.py ]; then
		cp battery/battery-auto-calibrator.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-auto-calibrator.py"
		success "Installed: battery-auto-calibrator.py"
	fi
}

# ── Install battery driver (with INA228) ───────────────────────────────────────
install_battery() {
	info "Installing Battery Driver (bq25895 + INA228)..."

	# Copy tools
	install_tools

	# Build and install module with INA228 support
	cd "$PIBRICK_LIB/battery"
	make clean
	# INA228 support is enabled by default in Makefile
	make
	make install

	# Config
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery.conf" ]; then
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery.conf" \
			/etc/modprobe.d/pibrick-battery.conf
	fi

	# SOC persistence
	mkdir -p /var/lib/bq25890_battery
	mkdir -p "$PIBRICK_TOOLS"

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" ]; then
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" \
			/etc/systemd/system/
		systemctl daemon-reload
		systemctl enable pibrick-battery-soc-persist.service
		success "SOC persistence service enabled"
	fi

	# Cron
	CRON_FILE="/etc/cron.d/pibrick-battery-soc"
	if [ ! -f "$CRON_FILE" ]; then
		echo "*/5 * * * * root /usr/bin/python3 $PIBRICK_TOOLS/battery-soc-persist.py --quiet" \
			> "$CRON_FILE"
		chmod 644 "$CRON_FILE"
		success "Cron job installed for SOC persistence"
	fi

	# Initial SOC save
	python3 "$PIBRICK_TOOLS/battery-soc-persist.py" --quiet 2>/dev/null || true

	success "Battery driver installed (INA228 will be auto-detected at runtime)"
	cd "$PIBRICK_LIB"
}

# ── Install original battery driver (bq25895 only, runtime INA228 probe) ─────
install_battery_original() {
	info "Installing Battery Driver (bq25895 with optional INA228 probe)..."

	# Copy tools
	install_tools

	# Build and install module (INA228 is runtime-detected)
	cd "$PIBRICK_LIB/battery"
	make clean
	make
	make install

	# Config
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery.conf" ]; then
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery.conf" \
			/etc/modprobe.d/pibrick-battery.conf
	fi

	# SOC persistence
	mkdir -p /var/lib/bq25890_battery
	mkdir -p "$PIBRICK_TOOLS"

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" ]; then
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" \
			/etc/systemd/system/
		systemctl daemon-reload
		systemctl enable pibrick-battery-soc-persist.service
		success "SOC persistence service enabled"
	fi

	# Cron
	CRON_FILE="/etc/cron.d/pibrick-battery-soc"
	if [ ! -f "$CRON_FILE" ]; then
		echo "*/5 * * * * root /usr/bin/python3 $PIBRICK_TOOLS/battery-soc-persist.py --quiet" \
			> "$CRON_FILE"
		chmod 644 "$CRON_FILE"
		success "Cron job installed for SOC persistence"
	fi

	# Initial SOC save
	python3 "$PIBRICK_TOOLS/battery-soc-persist.py" --quiet 2>/dev/null || true

	success "Battery driver (bq25895) installed (INA228 auto-detected at runtime)"
	cd "$PIBRICK_LIB"
}

# ── Install calibration tools ───────────────────────────────────────────────────
install_calibration() {
	info "Installing Calibration Tools..."

	mkdir -p "$PIBRICK_TOOLS"

	# Copy calibration scripts
	if [ -f battery/battery-calibration-logger.py ]; then
		cp battery/battery-calibration-logger.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-calibration-logger.py"
		success "Installed: battery-calibration-logger.py"
	fi

	if [ -f battery/battery-auto-calibrator.py ]; then
		cp battery/battery-auto-calibrator.py "$PIBRICK_TOOLS/"
		chmod +x "$PIBRICK_TOOLS/battery-auto-calibrator.py"
		success "Installed: battery-auto-calibrator.py"
	fi

	# Create log directory
	mkdir -p /var/log/bq25890_battery

	# Install service
	if [ -f battery/pibrick-battery-calibration.service ]; then
		install -m 644 battery/pibrick-battery-calibration.service \
			/etc/systemd/system/
		systemctl daemon-reload
		success "Calibration logger service installed"
	fi

	success "Calibration tools installed"
}

# ── Install display driver ──────────────────────────────────────────────────────
install_display() {
	local panel="$1"
	info "Installing Display Driver for panel: $(panel_label "$panel")..."

	echo "$panel" > "$PANEL_CONFIG"

	if [ ! -f "$DISPLAY_REFRESH_CONFIG" ]; then
		case "$panel" in
		9203|5inch) echo 90 > "$DISPLAY_REFRESH_CONFIG" ;;
		*)           echo 60 > "$DISPLAY_REFRESH_CONFIG" ;;
		esac
	fi

	# Copy and install
	install -m 644 "$PIBRICK_LIB/pibrick.service" /etc/systemd/system/
	chmod +x "$PIBRICK_LIB/build.sh"
	systemctl daemon-reload
	systemctl enable pibrick.service

	# Build
	cd "$PIBRICK_LIB"
	PANEL="$panel" ./build.sh --force --no-reboot

	success "Display driver installed for panel: $(panel_label "$panel")"
}

# ── Install button service ─────────────────────────────────────────────────────
install_button() {
	info "Installing Button Service..."
	if [ -f button-service/install.sh ]; then
		bash "$PIBRICK_LIB/button-service/install.sh"
	else
		error "Button service install script not found"
		return 1
	fi
}

# ── Reload drivers ─────────────────────────────────────────────────────────────
reload_drivers() {
	info "Reloading drivers..."

	# Display
	if systemctl is-active --quiet pibrick.service 2>/dev/null; then
		systemctl restart pibrick.service
	fi

	# Battery
	if lsmod | grep -q bq25890_battery; then
		sudo modprobe -r bq25890_battery 2>/dev/null || true
		sleep 1
		sudo modprobe bq25890_battery
		success "Battery driver reloaded"
	fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
	choose_components

	# Copy source tree for all installs
	if [ -n "$INSTALL_DISPLAY$INSTALL_BATTERY_NEW$INSTALL_BATTERY_ORIGINAL$INSTALL_CALIBRATION$INSTALL_BUTTON" ]; then
		copy_sources
	fi

	# Panel selection
	local selected_panel="${PANEL:-9203}"
	if [ -n "$INSTALL_DISPLAY" ]; then
		selected_panel=$(choose_panel)
		info "Selected panel: $(panel_label "$selected_panel")"
	fi

	# Install components
	echo
	echo -e "${BOLD}=== Installing Components ===${RESET}"

	[ -n "$INSTALL_DISPLAY" ] && install_display "$selected_panel"
	[ -n "$INSTALL_BATTERY_NEW" ] && install_battery
	[ -n "$INSTALL_BATTERY_ORIGINAL" ] && install_battery_original
	[ -n "$INSTALL_CALIBRATION" ] && install_calibration
	[ -n "$INSTALL_UPower" ] && fix_upower
	[ -n "$INSTALL_BUTTON" ] && install_button

	# Reload
	reload_drivers

	# Summary
	echo
	echo -e "${BOLD}=== Installation Complete ===${RESET}"
	echo "Installed components:"
	[ -n "$INSTALL_DISPLAY" ] && echo "  - Display driver: $(panel_label "$selected_panel")"
	[ -n "$INSTALL_BATTERY_NEW" ] && echo "  - Battery driver (bq25895 + INA228 auto-detect)"
	[ -n "$INSTALL_BATTERY_ORIGINAL" ] && echo "  - Battery driver (bq25895 + INA228 auto-detect)"
	[ -n "$INSTALL_CALIBRATION" ] && echo "  - Calibration tools (logger + auto-calibrator)"
	[ -n "$INSTALL_UPower" ] && echo "  - UPower KDE fix"
	[ -n "$INSTALL_BUTTON" ] && echo "  - Button service"
	echo
	echo "Tools location: $PIBRICK_TOOLS/"
	echo "  battery_set.py       - Battery parameter setter"
	echo "  battery-check.py     - Battery diagnostics"
	echo "  battery-calibration-logger.py - Calibration logger"
	echo "  battery-auto-calibrator.py    - Auto-calibrator"
	echo
	echo "Calibration commands:"
	echo "  $0 --status-calibration     # Check calibration status"
	echo "  $0 --enable-calibration    # Start logging"
	echo "  $0 --disable-calibration   # Stop logging"
	echo "  $0 --apply-calibration     # Apply calibrated OCV"
	echo
	[ -n "$INSTALL_DISPLAY" ] && echo "Reboot to apply display changes: sudo reboot"
}

main
