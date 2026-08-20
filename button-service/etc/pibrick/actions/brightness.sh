#!/bin/bash
# Legacy wrapper for brightness control
# Usage: brightness.sh [up|down|status|set <value>]
exec /usr/local/bin/pibrick-brightness "${@:-up}"
