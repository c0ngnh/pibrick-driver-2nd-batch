#!/bin/bash
# Disable KDE PowerDevil auto-shutdown on low/critical battery.
# PocketCM5 fuel gauge can briefly report 0% under load; PowerDevil must not power off.
set -euo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/powerdevilrc"
mkdir -p "$(dirname "$CFG")"

apply_group() {
	local profile="$1"
	kwriteconfig6 --file powerdevilrc --group "${profile}[BatteryManagement][Battery]" --key PercentAction 0
	kwriteconfig6 --file powerdevilrc --group "${profile}[BatteryManagement][Battery]" --key CriticalAction 0
	kwriteconfig6 --file powerdevilrc --group "${profile}[BatteryManagement][Battery]" --key PercentLevel 2
	kwriteconfig6 --file powerdevilrc --group "${profile}[BatteryManagement][Battery]" --key CriticalLevel 1
}

if command -v kwriteconfig6 >/dev/null 2>&1; then
	apply_group "AC"
	apply_group "Battery"
	# Restart PowerDevil if a session is active.
	if command -v qdbus6 >/dev/null 2>&1; then
		qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/Battery org.kde.Solid.PowerManagement.Actions.Battery.refresh 2>/dev/null || true
	fi
	exit 0
fi

# Fallback: write powerdevilrc directly (NoAction = 0).
if ! grep -q '^\[Battery\]\[BatteryManagement\]\[Battery\]' "$CFG" 2>/dev/null; then
	cat >>"$CFG" <<'EOF'

[AC][BatteryManagement][Battery]
PercentAction=0
PercentLevel=2
CriticalAction=0
CriticalLevel=1

[Battery][BatteryManagement][Battery]
PercentAction=0
PercentLevel=2
CriticalAction=0
CriticalLevel=1
EOF
fi
