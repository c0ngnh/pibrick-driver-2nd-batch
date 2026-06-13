#!/bin/bash
# Power button short press: DE-specific menu fallback (GNOME/KDE use KEY_POWER from pibrickbtn).

bash /etc/pibrick/actions/run-as-session-user.sh \
	bash /etc/pibrick/actions/power-menu.sh &
