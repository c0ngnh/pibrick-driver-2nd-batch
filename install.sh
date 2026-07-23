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
PIBRICK_LIB=/usr/lib/pibrick
PIBRICK_TOOLS_DIR="$PIBRICK_LIB/battery-tools"
PIBRICK_TOOLS="$PIBRICK_TOOLS_DIR"
PIBRICK_WRAPPER="/usr/local/bin/pibrick-tools"

# ── Install layout ─────────────────────────────────────────────────────────────
# install.sh only supports ONE install mode: system-wide.
#
#   - Source tree is copied to /usr/lib/pibrick/ (builds + python tools)
#   - /usr/local/bin/pibrick-tools is installed as a global wrapper so
#     users can run `sudo pibrick-tools --battery-status` instead of
#     having to remember the install.sh path.
#
# install.sh MUST be run as root (because it touches /usr/lib, /etc,
# /sys, and the kernel module). Running as non-root prints a helpful
# error and exits.
#
# Standard usage after install:
#   sudo pibrick-tools --battery-status
#   sudo pibrick-tools --battery-config charge_full_uah 3800 mAh --persist
#   sudo pibrick-tools --install calibration
#   sudo pibrick-tools --apply-calibration
#
# To reverse an install:
#   sudo pibrick-tools --uninstall all
# (per-component removal is also supported; the command requires a
# typed YES before any action).

# Detect the source tree (the directory install.sh lives in). This is
# what we copy FROM into /usr/lib/pibrick. Capture at startup so any
# later cwd changes don't affect it.
SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")
PIBRICK_SRC="$(dirname "$SCRIPT_REAL")"

# When sudo runs, $HOME gets reset to /root. Restore the original user's
# home so log messages and config paths make sense.
ORIG_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$(id -un)" = "root" ]; then
	ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
	ORIG_HOME="${ORIG_HOME:-/root}"
fi
HOME="${ORIG_HOME}"


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
	python3 "$PIBRICK_TOOLS_DIR/battery-auto-calibrator.py" --status 2>/dev/null || \
		cat /var/log/bq25890_battery/calibration_status.json
}

# ── Apply the calibrated OCV table ─────────────────────────────────────────────
# Forwards remaining arguments to battery-auto-calibrator.py so users can
# do `sudo pibrick-tools --apply-calibration --yes --no-ina228` etc.
apply_calibration() {
	info "Checking calibration status..."

	local calibrator
	if ! calibrator=$(find_battery_tool "battery-auto-calibrator.py"); then
		return 1
	fi

	# Strip the leading "--apply-calibration" so any args after it
	# become the calibrator's flags (e.g. --yes, --no-ina228,
	# --no-rebuild). Without TTY the "--yes" is implied.
	local extra=()
	for arg in "$@"; do
		case "$arg" in
			--apply-calibration) ;;
			*) extra+=("$arg") ;;
		esac
	done

	# If the user didn't pass --yes and there's no TTY (e.g. running
	# from a script or background), imply --yes so the command doesn't
	# hang forever waiting on stdin.
	if [ ! -t 0 ]; then
		local has_yes=0
		for a in "${extra[@]}"; do
			[ "$a" = "--yes" ] || [ "$a" = "-y" ] && has_yes=1
		done
		[ "$has_yes" = "0" ] && extra+=("--yes")
	fi

	python3 "$calibrator" --apply "${extra[@]}"
}

# ── Find a battery Python helper ───────────────────────────────────────────────
# Resolves the path to a Python helper under the battery tools dir, falling
# back to $PIBRICK_LIB/battery/ (the source tree) if the tools-dir copy
# is missing. Used for battery_set.py / battery-check.py / etc.
find_battery_tool() {
	local script="$1"
	for candidate in \
		"$PIBRICK_TOOLS_DIR/$script" \
		"$PIBRICK_LIB/battery/$script"; do
		if [ -f "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	error "$script not installed. Run: $0 --install calibration"
	return 1
}

# ── Battery status (shows current params + persisted config) ──────────────────
battery_status() {
	info "Battery status & custom values"

	local battery_set
	if ! battery_set=$(find_battery_tool "battery_set.py"); then
		return 1
	fi

	echo
	echo -e "${BOLD}=== Current Driver Values (live) ===${RESET}"
	python3 "$battery_set" --show

	echo
	echo -e "${BOLD}=== Persisted Config (/etc/modprobe.d/pibrick-battery.conf) ===${RESET}"
	if [ -f /etc/modprobe.d/pibrick-battery.conf ]; then
		cat /etc/modprobe.d/pibrick-battery.conf
	else
		echo "(none — no values persisted yet)"
	fi

	echo
	echo -e "${BOLD}=== Driver Defaults (compile-time) ===${RESET}"
	python3 "$battery_set" --list 2>&1 | \
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

	local battery_set
	if ! battery_set=$(find_battery_tool "battery_set.py"); then
		return 1
	fi

	# If no extra args, run interactive mode
	if [ ${#extra_args[@]} -eq 0 ]; then
		info "Launching interactive battery configuration..."
		# Need to be a TTY for interactive; just exec directly
		python3 "$battery_set"
		return $?
	fi

	# Non-interactive path: build command using string concat (preserves args with spaces)
	local cmd="python3 $battery_set"
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

After installation, every command below is also available via the global
wrapper \`pibrick-tools\` (e.g. \`sudo pibrick-tools --battery-status\`)
which \`$0\` installs at \`/usr/local/bin/pibrick-tools\`.

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

${BOLD}Uninstall (requires root, prompts for typed YES):${RESET}
  $0 --uninstall <component[,component...]>    # Remove one or more components
  $0 --uninstall all                            # Remove everything pibrick-tools installed
  Components: display, battery, calibration, upower, button, wrapper

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
  --version                 Print install paths
  -h, --help                Show this help

${BOLD}Examples:${RESET}
  $0 --install all              # Install everything
  $0 --install display          # Display with interactive panel selection
  $0 --install battery-new      # Battery with INA228
  $0 --uninstall display        # Remove display driver + overlay + udev rule
  $0 --uninstall calibration    # Stop logger service + drop calibration logs
  $0 --uninstall all            # Remove everything (typed YES to confirm)
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
# ── Uninstall ───────────────────────────────────────────────────────────────────
# Destructive companion to install.sh. Each uninstall_<component> helper
# reverses the corresponding install_<component> helper. Components are
# uninstalled in dependency order: calibration (depends on battery tools)
# before battery, button before wrapper, etc.
#
# Safety: --uninstall <anything> requires a typed "YES" before any action,
# even in non-interactive mode. This protects against accidental
# `sudo pibrick-tools --uninstall all` from a misconfigured cron job.

do_uninstall() {
	local targets="$1"

	if [ -z "$targets" ]; then
		error "--uninstall requires at least one component"
		usage
		return 1
	fi

	# Must be root (we touch /etc, kernel modules, systemd units).
	if [ "$(id -u)" != "0" ]; then
		error "--uninstall must be run as root (sudo)"
		return 1
	fi

	# Detection — warn if the component looks uninstalled.
	local missing=""
	for comp in $targets; do
		case "$comp" in
		display)    panel_artifact >/dev/null 2>&1 || { [ ! -f /etc/pibrick.panel ] && [ ! -f /etc/systemd/system/pibrick.service ] && missing="$missing display"; } ;;
		battery)    { lsmod 2>/dev/null | grep -q bq25890_battery || [ ! -f /etc/modprobe.d/pibrick-battery.conf ]; } && missing="$missing battery" ;;
		calibration) [ ! -f /etc/systemd/system/pibrick-battery-calibration.service ] && missing="$missing calibration" ;;
		upower)     [ ! -f /usr/libexec/upowerd ] && missing="$missing upower" ;;
		button)     { [ ! -f /usr/local/bin/pibrickbtn ] && [ ! -f /etc/systemd/system/pibrickbtn.service ]; } && missing="$missing button" ;;
		wrapper)    [ ! -f /usr/local/bin/pibrick-tools ] && missing="$missing wrapper" ;;
		esac
	done
	if [ -n "$missing" ]; then
		warn "These components look uninstalled already:$missing"
	fi

	echo
	echo -e "${BOLD}=== piBrick Uninstaller ===${RESET}"
	echo "About to remove:"
	for comp in $targets; do
		echo "  - $comp"
	done
	echo
	echo "This will:"
	echo "  - unload kernel modules"
	echo "  - remove installed kernel modules from /lib/modules/.../kernel/"
	echo "  - remove /etc/systemd/system/pibrick*.service and disable them"
	echo "  - remove /etc/modprobe.d/pibrick-battery.conf"
	echo "  - remove /etc/pibrick.panel / /etc/pibrick.display-refresh"
	echo "  - remove /etc/udev/rules.d/99-pibrick-display.rules"
	echo "  - remove /etc/cron.d/pibrick-battery-soc"
	echo "  - remove Python helpers from $PIBRICK_TOOLS_DIR"
	echo "  - restore /usr/libexec/upowerd from .bak-pibrick-* (if present)"
	echo "  - remove /usr/local/bin/pibrick-tools + bash completion"
	echo
	echo "Type exactly:  YES"
	printf "> "
	local reply
	read -r reply || reply=""
	if [ "$reply" != "YES" ]; then
		echo "Aborted."
		return 130
	fi
	echo

	# Uninstall in dependency order regardless of the order the user typed.
	local ordered="calibration battery display upower button wrapper"
	for comp in $ordered; do
		case " $targets " in
		*" $comp "*)
			echo
			echo -e "${BOLD}--- Removing $comp ---${RESET}"
			uninstall_"$comp" || warn "Failed to remove $comp (continuing)"
			;;
		esac
	done

	# Final depmod so the next modprobe doesn't see a phantom bq25890_battery.
	if lsmod 2>/dev/null | grep -q bq25890_battery; then
		modprobe -r bq25890_battery 2>/dev/null || true
	fi
	depmod -a 2>/dev/null || true

	echo
	success "Uninstall complete. A reboot is recommended."
}

# ── uninstall: display panel ────────────────────────────────────────────────────
uninstall_display() {
	info "Uninstalling display driver..."

	# Stop + disable the service
	if systemctl is-active --quiet pibrick.service 2>/dev/null; then
		systemctl stop pibrick.service || true
	fi
	systemctl disable pibrick.service 2>/dev/null || true

	# Use the Makefile's `remove` target to scrub all known overlays and
	# config.txt entries — same logic as a panel switch. Building isn't
	# required because `remove` only deletes.
	if [ -f "$PIBRICK_LIB/Makefile" ]; then
		(cd "$PIBRICK_LIB" && make remove 2>&1 | sed 's/^/    /')
	fi

	# Drop the panel-config + refresh config files we created.
	rm -f /etc/pibrick.panel
	rm -f /etc/pibrick.display-refresh

	# Drop the udev rule that grants display-on/off to the user.
	rm -f /etc/udev/rules.d/99-pibrick-display.rules

	# Drop the systemd unit. `make remove` doesn't touch /etc/systemd/system.
	rm -f /etc/systemd/system/pibrick.service
	systemctl daemon-reload || true

	success "Display driver uninstalled"
}

# ── uninstall: battery driver ───────────────────────────────────────────────────
uninstall_battery() {
	info "Uninstalling battery driver..."

	# Stop services that depend on the driver / sysfs.
	for svc in pibrick-battery-calibration.service \
	           pibrick-battery-soc-persist.service \
	           pibrick-battery-load-soc.service; do
		systemctl stop "$svc" 2>/dev/null || true
		systemctl disable "$svc" 2>/dev/null || true
	done

	# Unload module before removing .ko
	if lsmod 2>/dev/null | grep -q bq25890_battery; then
		modprobe -r bq25890_battery 2>/dev/null || \
			warn "bq25890_battery still in use; module file removed but module is still loaded"
	fi

	# Remove the .ko file using the same Makefile target as install.
	if [ -f "$PIBRICK_LIB/battery/Makefile" ]; then
		(cd "$PIBRICK_LIB/battery" && make remove 2>&1 | sed 's/^/    /')
	fi

	# Drop modprobe config
	rm -f /etc/modprobe.d/pibrick-battery.conf

	# Drop SOC persistence state
	rm -f /var/lib/bq25890_battery/soc_persist

	# Drop the cron job
	rm -f /etc/cron.d/pibrick-battery-soc

	# Drop the SOC helper script + its services
	rm -f "$PIBRICK_TOOLS_DIR/pibrick-battery-load-soc.sh"
	rm -f /etc/systemd/system/pibrick-battery-load-soc.service
	rm -f /etc/systemd/system/pibrick-battery-soc-persist.service

	systemctl daemon-reload || true
	depmod -a 2>/dev/null || true

	success "Battery driver uninstalled"
}

# ── uninstall: calibration ──────────────────────────────────────────────────────
# Stops the logger service and removes the calibrated OCV artifacts + scripts.
# Kept separate from `battery` because users may want to disable logging
# without rebuilding the kernel module.
uninstall_calibration() {
	info "Uninstalling calibration tooling..."

	# Stop + disable the logger service.
	if systemctl is-active --quiet pibrick-battery-calibration.service 2>/dev/null; then
		systemctl stop pibrick-battery-calibration.service || true
	fi
	systemctl disable pibrick-battery-calibration.service 2>/dev/null || true
	rm -f /etc/systemd/system/pibrick-battery-calibration.service
	systemctl daemon-reload || true

	# Drop the calibrated OCV artifacts and the entire log dir if user agrees
	# implicitly (the YES prompt at the top of do_uninstall already covers it).
	if [ -d /var/log/bq25890_battery ]; then
		warn "Removing /var/log/bq25890_battery/ (calibration CSV + logs + status JSON)"
		rm -rf /var/log/bq25890_battery
	fi

	# Drop the calibrator/logger scripts. battery_set.py / battery-soc-persist.py
	# are kept because they are useful diagnostic tools even with no driver
	# loaded (matches the policy of install_calibration).
	rm -f "$PIBRICK_TOOLS_DIR/battery-calibration-logger.py"
	rm -f "$PIBRICK_TOOLS_DIR/battery-auto-calibrator.py"

	success "Calibration tooling uninstalled"
}

# ── uninstall: UPower KDE fix ───────────────────────────────────────────────────
# Restores /usr/libexec/upowerd from the most recent .bak-pibrick-* backup
# the install script created when it patched UPower.
uninstall_upower() {
	info "Uninstalling UPower KDE fix..."

	local UPowerD=/usr/libexec/upowerd
	if [ ! -f "$UPowerD" ]; then
		warn "upowerd not found at $UPowerD — nothing to restore"
		return 0
	fi

	# Sanity check: only restore if the current binary is patched.
	if ! grep -q "piBrick:" "$UPowerD" 2>/dev/null; then
		warn "upowerd does not look patched — leaving alone"
		return 0
	fi

	# Pick the most recent backup.
	local bak
	bak=$(ls -t "$UPowerD".bak-pibrick-* 2>/dev/null | head -n 1)
	if [ -z "$bak" ] || [ ! -f "$bak" ]; then
		warn "No .bak-pibrick-* backup of upowerd found."
		warn "The patched binary remains. To fully revert, install the"
		warn "matching upower package from your distro (apt reinstall upower)."
		return 0
	fi

	info "Restoring upowerd from $bak"
	cp -f "$bak" "$UPowerD"
	chmod +x "$UPowerD"
	restart_upower

	success "UPower restored from $bak"
}

# ── uninstall: button service ───────────────────────────────────────────────────
# Removes the button service installed by button-service/install.sh.
uninstall_button() {
	info "Uninstalling button service..."

	# Stop + disable
	if systemctl is-active --quiet pibrickbtn.service 2>/dev/null; then
		systemctl stop pibrickbtn.service || true
	fi
	systemctl disable pibrickbtn.service 2>/dev/null || true

	# Remove unit + binary
	rm -f /etc/systemd/system/pibrickbtn.service
	rm -f /usr/local/bin/pibrickbtn

	# Drop the config tree (only if it looks like ours)
	if [ -d /etc/pibrick ]; then
		rm -rf /etc/pibrick
	fi

	systemctl daemon-reload || true

	success "Button service uninstalled"
}

# ── uninstall: pibrick-tools wrapper ────────────────────────────────────────────
# Removes the /usr/local/bin/pibrick-tools shim and bash completion.
uninstall_wrapper() {
	info "Uninstalling pibrick-tools wrapper..."

	rm -f /usr/local/bin/pibrick-tools
	rm -f /etc/bash_completion.d/pibrick-tools
	# Some systems use /usr/share/bash-completion/completions/
	rm -f /usr/share/bash-completion/completions/pibrick-tools

	success "pibrick-tools wrapper removed"
}

# Helper: return 0 if the display driver looks installed.
panel_artifact() {
	local p
	for p in vc4-kms-dsi-pibrick vc-548inch vc4-5inch; do
		if [ -f "/boot/firmware/overlays/$p.dtbo" ] || \
		   [ -f "/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/panel/panel-pibrick.ko" ]; then
			return 0
		fi
	done
	return 1
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
	--uninstall)
		shift
		[ $# -eq 0 ] && { error "--uninstall requires argument"; usage; exit 1; }
		# Record which components to remove, then exit early via do_uninstall.
		UNINSTALL_EXPLICIT=1
		UNINSTALL_TARGETS=
		for comp in $(echo "$1" | tr ',' ' '); do
			case "$comp" in
			all)
				UNINSTALL_TARGETS="$UNINSTALL_TARGETS display battery calibration upower button wrapper"
				;;
			display|battery|calibration|upower|button|wrapper)
				UNINSTALL_TARGETS="$UNINSTALL_TARGETS $comp"
				;;
			*)
				error "Unknown --uninstall component: $comp"
				usage
				exit 1
				;;
			esac
		done
		# Trim leading/trailing whitespace
		UNINSTALL_TARGETS=$(echo "$UNINSTALL_TARGETS" | xargs)
		# Confirm before destructive operations
		do_uninstall "$UNINSTALL_TARGETS"
		exit $?
		;;
	--apply-calibration)
		# Forward remaining args: e.g. `--yes`, `--no-ina228`,
		# `--no-rebuild` to battery-auto-calibrator.py.
		shift 2>/dev/null || true
		apply_calibration "$@"
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
	--version)
		echo "pibrick-driver installer"
		echo "  source: $PIBRICK_SRC"
		echo "  install path: $PIBRICK_LIB"
		echo "  wrapper: $PIBRICK_WRAPPER"
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
	# Non-interactive (no terminal): install all components.
	if [ ! -t 0 ] && [ -z "$INSTALL_EXPLICIT" ]; then
		info "No terminal detected. Installing all components."
		INSTALL_DISPLAY=1
		INSTALL_BATTERY_NEW=1
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
		--delete-excluded
		# Exclude build artifacts from the copy so they don't accumulate
		# stale entries in PIBRICK_LIB. The make-based build creates these
		# in-place and they don't belong in a source-tree copy.
		--exclude='*.o'
		--exclude='*.ko'
		--exclude='*.mod'
		--exclude='*.cmd'
		--exclude='*.dtbo'
		--exclude='.git/'
		--exclude='__pycache__/'
		--exclude='.trellis/'
		--exclude='.cursor/'
		--exclude='AGENTS.md'
	)
	if [ ! -d "$PIBRICK_SRC" ]; then
		warn "Source tree not found at $PIBRICK_SRC; skipping source sync"
		return 0
	fi
	if [ "$(cd "$PIBRICK_SRC" && pwd -P)" != "$PIBRICK_LIB" ]; then
		(cd "$PIBRICK_SRC" && rsync "${rsync_opts[@]}" . "$PIBRICK_LIB/")
	fi
	# rsync preserves the source file's mode; ensure install.sh and
	# build.sh are executable when copied to PIBRICK_LIB.
	chmod +x "$PIBRICK_LIB/install.sh" 2>/dev/null || true
	chmod +x "$PIBRICK_LIB/build.sh" 2>/dev/null || true
}

# ── Install tools ───────────────────────────────────────────────────────────────
install_tools() {
	mkdir -p "$PIBRICK_TOOLS"

	# Battery tools. Resolve against $PIBRICK_LIB so the installer works
	# from any cwd (e.g. when re-run after a previous system-wide install).
	for script in battery_set.py battery-check.py battery-soc-persist.py \
	              battery-calibration-logger.py battery-auto-calibrator.py; do
		if [ -f "$PIBRICK_LIB/battery/$script" ]; then
			cp "$PIBRICK_LIB/battery/$script" "$PIBRICK_TOOLS/"
			chmod +x "$PIBRICK_TOOLS/$script"
			success "Installed: $script"
		fi
	done
}

# ── Service install helper ─────────────────────────────────────────────────────
# Substitutes __PIBRICK_TOOLS__ and __PIBRICK_LIB__ placeholders with the
# resolved install paths and writes the result to /etc/systemd/system/.
install_service() {
	local src="$1"
	local dst="/etc/systemd/system/$(basename "$src")"

	if [ ! -f "$src" ]; then
		return 1
	fi

	# Substitute both placeholders with the resolved install paths. Use a
	# unique delimiter for sed to avoid clobbering any literal slashes in
	# the resolved paths.
	sed -e "s|__PIBRICK_TOOLS__|$PIBRICK_TOOLS_DIR|g" \
	    -e "s|__PIBRICK_LIB__|$PIBRICK_LIB|g" \
	    "$src" > "$dst"
	chmod 644 "$dst"

	systemctl daemon-reload
}

# ── Install battery driver (with INA228) ───────────────────────────────────────
install_battery() {
	info "Installing Battery Driver (bq25895 + INA228)..."

	# Copy tools (Python helpers always go to $PIBRICK_TOOLS_DIR)
	install_tools

	# Kernel module build/install requires root.
	# In per-user mode, skip and instruct the user how to complete the install.
	if [ "$(id -u)" != "0" ]; then
		warn "Not running as root — skipping kernel module build/install."
		warn "To install the kernel module, re-run as root:"
		warn "    sudo bash $PIBRICK_LIB/install.sh --install battery-new"
		warn "Python tools are available at: $PIBRICK_TOOLS_DIR"
		return 0
	fi

	# Build and install module with INA228 support
	cd "$PIBRICK_LIB/battery"
	make clean
	# INA228 support is enabled by default in Makefile.
	# PIBRICK_USER_HOME tells the Makefile where to install Python helpers
	# (it writes to the system service file with the resolved path).
	PIBRICK_USER_HOME="$PIBRICK_TOOLS_DIR" make
	PIBRICK_USER_HOME="$PIBRICK_TOOLS_DIR" make install

	# Config
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery.conf" ]; then
		# Strip any legacy persist_soc=N from a previously-installed
		# config — it races with udev-trigger and was the root cause of
		# the 0%-display-after-boot failure mode. Modern install uses
		# the writable `coulomb_uah` sysfs attribute instead, seeded at
		# boot by pibrick-battery-load-soc.service.
		if [ -f /etc/modprobe.d/pibrick-battery.conf ]; then
			if grep -qE '(^|[[:space:]])persist_soc=' /etc/modprobe.d/pibrick-battery.conf; then
				warn "Stripping stale 'persist_soc=' from /etc/modprobe.d/pibrick-battery.conf"
				sed -i -E 's/(^|[[:space:]])persist_soc=[0-9]+//g; s/[[:space:]]+$//' \
					/etc/modprobe.d/pibrick-battery.conf
			fi
		fi
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery.conf" \
			/etc/modprobe.d/pibrick-battery.conf
	fi

	# SOC persistence
	mkdir -p /var/lib/bq25890_battery
	mkdir -p "$PIBRICK_TOOLS_DIR"

	# Clear any stale SOC=0% from a previous session — it would cause
	# the boot loader to seed 0% on first boot and recreate the
	# feedback loop the user just hit. The new persist script refuses
	# to write 0% on its own (and the boot loader verifies against
	# current voltage), but a leftover 0% from an old install still
	# needs cleaning up.
	if [ -f /var/lib/bq25890_battery/soc_persist ] && \
	   grep -q '^soc=0$' /var/lib/bq25890_battery/soc_persist; then
		warn "Removing stale /var/lib/bq25890_battery/soc_persist (was soc=0)"
		rm -f /var/lib/bq25890_battery/soc_persist
	fi

	# Install SOC load-soc helper script (runs at boot to seed coulomb_uah).
	# It lives under $PIBRICK_TOOLS_DIR so the service file (which has the
	# path baked in at install time) can find it. The file in $PIBRICK_LIB
	# is the source-of-truth copy that is pushed via git.
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-load-soc.sh" ]; then
		install -m 755 "$PIBRICK_LIB/battery/pibrick-battery-load-soc.sh" \
			"$PIBRICK_TOOLS_DIR/pibrick-battery-load-soc.sh"
	fi

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-load-soc.service" ]; then
		install_service "$PIBRICK_LIB/battery/pibrick-battery-load-soc.service"
		systemctl enable pibrick-battery-load-soc.service
		success "SOC load-on-boot service enabled"
	fi

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" ]; then
		install_service "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service"
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
	PIBRICK_USER_HOME="$PIBRICK_TOOLS_DIR" make
	PIBRICK_USER_HOME="$PIBRICK_TOOLS_DIR" make install

	# Config
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery.conf" ]; then
		# Strip any legacy persist_soc=N from a previously-installed
		# config — it races with udev-trigger and was the root cause of
		# the 0%-display-after-boot failure mode. Modern install uses
		# the writable `coulomb_uah` sysfs attribute instead, seeded at
		# boot by pibrick-battery-load-soc.service.
		if [ -f /etc/modprobe.d/pibrick-battery.conf ]; then
			if grep -qE '(^|[[:space:]])persist_soc=' /etc/modprobe.d/pibrick-battery.conf; then
				warn "Stripping stale 'persist_soc=' from /etc/modprobe.d/pibrick-battery.conf"
				sed -i -E 's/(^|[[:space:]])persist_soc=[0-9]+//g; s/[[:space:]]+$//' \
					/etc/modprobe.d/pibrick-battery.conf
			fi
		fi
		install -m 644 "$PIBRICK_LIB/battery/pibrick-battery.conf" \
			/etc/modprobe.d/pibrick-battery.conf
	fi

	# SOC persistence
	mkdir -p /var/lib/bq25890_battery
	mkdir -p "$PIBRICK_TOOLS_DIR"

	# Clear any stale SOC=0% from a previous session — it would cause
	# the boot loader to seed 0% on first boot and recreate the
	# feedback loop the user just hit. The new persist script refuses
	# to write 0% on its own (and the boot loader verifies against
	# current voltage), but a leftover 0% from an old install still
	# needs cleaning up.
	if [ -f /var/lib/bq25890_battery/soc_persist ] && \
	   grep -q '^soc=0$' /var/lib/bq25890_battery/soc_persist; then
		warn "Removing stale /var/lib/bq25890_battery/soc_persist (was soc=0)"
		rm -f /var/lib/bq25890_battery/soc_persist
	fi

	# Install SOC load-soc helper script (runs at boot to seed coulomb_uah).
	# It lives under $PIBRICK_TOOLS_DIR so the service file (which has the
	# path baked in at install time) can find it. The file in $PIBRICK_LIB
	# is the source-of-truth copy that is pushed via git.
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-load-soc.sh" ]; then
		install -m 755 "$PIBRICK_LIB/battery/pibrick-battery-load-soc.sh" \
			"$PIBRICK_TOOLS_DIR/pibrick-battery-load-soc.sh"
	fi

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-load-soc.service" ]; then
		install_service "$PIBRICK_LIB/battery/pibrick-battery-load-soc.service"
		systemctl enable pibrick-battery-load-soc.service
		success "SOC load-on-boot service enabled"
	fi

	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service" ]; then
		install_service "$PIBRICK_LIB/battery/pibrick-battery-soc-persist.service"
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

	# Calibration mode requires battery_set.py / battery-check.py for the
	# user to inspect driver state alongside the logger. Copy the full
	# battery tools bundle (idempotent — safe to call repeatedly).
	install_tools

	# Service and log dir installation requires root
	if [ "$(id -u)" != "0" ]; then
		warn "Not running as root — skipping systemd service install."
		warn "To enable the calibration logger service, re-run as root."
		return 0
	fi

	# Create log directory
	mkdir -p /var/log/bq25890_battery

	# Install service. Source the .service file from PIBRICK_LIB so it
	# works whether install.sh was run from the source tree (PWD=.) or
	# already from /usr/lib/pibrick.
	if [ -f "$PIBRICK_LIB/battery/pibrick-battery-calibration.service" ]; then
		install_service "$PIBRICK_LIB/battery/pibrick-battery-calibration.service"
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

	# Copy and install. Use install_service so __PIBRICK_LIB__ /
	# __PIBRICK_TOOLS__ placeholders are resolved for both per-user and
	# system-wide layouts.
	if install_service "$PIBRICK_LIB/pibrick.service"; then
		chmod +x "$PIBRICK_LIB/build.sh"
		systemctl enable pibrick.service
	else
		warn "Failed to install pibrick.service"
	fi

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

# ── Install /usr/local/bin/pibrick-tools wrapper ───────────────────────────────
install_pibrick_wrapper() {
	if [ ! -f "$PIBRICK_SRC/tools/pibrick-tools.sh" ]; then
		return 0
	fi
	info "Installing pibrick-tools wrapper at $PIBRICK_WRAPPER..."
	install -m 0755 "$PIBRICK_SRC/tools/pibrick-tools.sh" "$PIBRICK_WRAPPER"
	success "Wrapper installed: $PIBRICK_WRAPPER"
}

# ── Install bash completion for pibrick-tools ───────────────────────────────────
install_bash_completion() {
	local src_completion="$PIBRICK_SRC/tools/pibrick-tools.bash-completion"
	if [ ! -f "$src_completion" ]; then
		return 0
	fi
	local dest_dir=""
	# Prefer /usr/share/bash-completion/completions on Debian/Ubuntu
	if [ -d /usr/share/bash-completion/completions ]; then
		dest_dir=/usr/share/bash-completion/completions
	elif [ -d /etc/bash_completion.d ]; then
		dest_dir=/etc/bash_completion.d
	fi
	if [ -z "$dest_dir" ]; then
		warn "No bash-completion directory found; skipping"
		return 0
	fi
	info "Installing bash completion to $dest_dir/pibrick-tools..."
	install -m 0644 "$src_completion" "$dest_dir/pibrick-tools"
	success "Bash completion installed (restart shell or 'source' it manually)"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
	# Refuse to run as non-root for any subcommand that modifies the
	# system. Read-only commands (status, help) are allowed without sudo.
	local needs_root=1
	for arg in "$@"; do
		case "$arg" in
			--status|--status-calibration|--battery-status|--version|-h|--help|help)
				needs_root=0 ;;
			--install|--uninstall|--enable-calibration|--disable-calibration|--apply-calibration|--battery-config|--battery-check|--enable-upower|--disable-upower)
				needs_root=1; break ;;
		esac
	done

	if [ "$needs_root" = "1" ] && [ "$(id -u)" != "0" ]; then
		echo "pibrick install.sh: this command modifies the system." >&2
		echo "Please re-run with sudo:" >&2
		echo "  sudo $0 $*" >&2
		exit 1
	fi

	choose_components "$@"

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

	# Install the global /usr/local/bin/pibrick-tools wrapper so users
	# don't have to remember the install.sh path under /usr/lib/pibrick.
	# Also install bash completion if a completion dir is available.
	if [ -f "$PIBRICK_SRC/tools/pibrick-tools.sh" ]; then
		install_pibrick_wrapper
		install_bash_completion
	fi

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
	echo "Use \`pibrick-tools\` for everything from now on:"
	echo "  sudo pibrick-tools --battery-status"
	echo "  sudo pibrick-tools --status-calibration"
	echo "  sudo pibrick-tools --enable-calibration"
	echo "  sudo pibrick-tools --disable-calibration"
	echo "  sudo pibrick-tools --apply-calibration"
	echo "  sudo pibrick-tools --battery-config charge_full_uah 3800 mAh --persist"
	echo "  sudo pibrick-tools --install <component>"
	echo "  sudo pibrick-tools --uninstall <component|all>   # reverse an install"
	echo
	echo "Run \`pibrick-tools --help\` for the full command list."
	echo
	[ -n "$INSTALL_DISPLAY" ] && echo "Reboot to apply display changes: sudo reboot"
}

main "$@"
