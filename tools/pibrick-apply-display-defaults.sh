#!/bin/bash
# Apply piBrick display defaults on graphical login (saved refresh rate + brightness).
set -euo pipefail

REFRESH="${PIBRICK_DEFAULT_REFRESH:-90}"
if [ -f /etc/pibrick.display-refresh ]; then
	REFRESH="$(tr -d '[:space:]' < /etc/pibrick.display-refresh)"
fi
SETTINGS=/usr/local/bin/pibrick-display-settings
PERSIST=/usr/local/bin/pibrick-persist-display-prefs.sh

[ -x "$PERSIST" ] && "$PERSIST" restore-backlight 2>/dev/null || true

# Wait for the compositor and Mutter DisplayConfig to come up.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if [ -x "$SETTINGS" ] && "$SETTINGS" --refresh "$REFRESH" 2>/dev/null; then
		[ -x "$PERSIST" ] && "$PERSIST" save-refresh "$REFRESH" 2>/dev/null || true
		[ -x "$PERSIST" ] && "$PERSIST" restore-backlight 2>/dev/null || true
		/usr/local/bin/pibrick-touch-reset 2>/dev/null || true
		exit 0
	fi
	sleep 2
done

exit 0
