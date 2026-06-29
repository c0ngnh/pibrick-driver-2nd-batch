#!/bin/bash
# User button long press: brightness up (works on labwc via sysfs helper).
if command -v pibrick-brightness >/dev/null 2>&1; then
	exec pibrick-brightness up
fi
