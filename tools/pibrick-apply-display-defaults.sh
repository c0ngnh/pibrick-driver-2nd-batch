#!/bin/bash
# Apply piBrick display defaults on graphical login (saved refresh rate).
set -euo pipefail

REFRESH="${PIBRICK_DEFAULT_REFRESH:-90}"
if [ -f /etc/pibrick.display-refresh ]; then
	REFRESH="$(tr -d '[:space:]' < /etc/pibrick.display-refresh)"
fi
SETTINGS=/usr/local/bin/pibrick-display-settings

[ -x "$SETTINGS" ] || exit 0

# Wait for the compositor and Mutter DisplayConfig to come up.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if "$SETTINGS" --refresh "$REFRESH" 2>/dev/null; then
		exit 0
	fi
	sleep 2
done

exit 0
