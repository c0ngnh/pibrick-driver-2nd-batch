#!/bin/bash
# Power button short press: native shutdown/power menu for the active desktop.

exec bash /etc/pibrick/actions/run-as-session-user.sh \
	bash /etc/pibrick/actions/power-menu.sh
