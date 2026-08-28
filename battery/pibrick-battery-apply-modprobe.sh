#!/bin/sh
# piBrick Battery Modprobe-Parameters Runtime Applier
#
# Reads /etc/modprobe.d/pibrick-battery.conf and applies every
# `options bq25890_battery name=value` pair to the running driver
# via /sys/module/bq25890_battery/parameters/<name>.
#
# Why this script exists:
#   The bq25890_battery module is loaded by udev-trigger as soon as the
#   I2C client appears, which happens BEFORE systemd-modules-load.service
#   has a chance to consult /etc/modprobe.d.  As a result, the `options`
#   directives are silently ignored at boot and every persisted value
#   (charge_full_uah, discharge_avg_ua, ...) reverts to its in-kernel
#   default — typically the wrong value for the attached pack.
#
#   The earlier "rmmod bq25890_battery && modprobe bq25890_battery" reload
#   trick was abandoned: it races with udev-trigger and was the root
#   cause of the 0%-display-after-boot failure mode on PocketCM5.  This
#   script takes the safer "post-load sysfs write" path, mirroring how
#   pibrick-battery-load-soc.sh seeds coulomb_uah.
#
# Idempotent: safe to run multiple times.  Skips parameters whose sysfs
# node does not exist (driver not loaded or stale option name).
#
# Per modprobe.d semantics, when several `options MODNAME ...` lines
# target the same module, each is treated as a complete override — so
# shared names between lines are NOT merged, the LAST line's value
# wins entirely.  We mirror that behaviour: we process options lines
# in order and only commit the LAST assignment for each name.
#
# Exit codes:
#   0  - all present-and-writable params applied (driver may also be absent)
#   1  - driver never appeared under /sys/module within 30 s

CONF="/etc/modprobe.d/pibrick-battery.conf"
MODULE_DIR="/sys/module/bq25890_battery/parameters"
MAX_WAIT_ITER=120   # 120 * 0.25 s = 30 s

log() {
    echo "pibrick-battery-apply-modprobe: $*"
}

# Nothing to do if the conf file is absent.
if [ ! -r "$CONF" ]; then
    log "no $CONF; nothing to apply"
    exit 0
fi

# Wait for the module to show up under /sys/module.  The driver is
# auto-loaded by udev-trigger and may not be ready when this unit
# starts; we poll until it appears or we time out.
i=0
while [ "$i" -lt "$MAX_WAIT_ITER" ]; do
    if [ -d "$MODULE_DIR" ]; then
        break
    fi
    i=$((i + 1))
    sleep 0.25
done

if [ ! -d "$MODULE_DIR" ]; then
    log "bq25890_battery module did not appear under /sys/module within 30 s; skipping"
    exit 1
fi

# Parse the conf into a "name -> last_value" map.  Lines we accept:
#   - blank lines
#   - comments (`# ...` or `#options ...`)
#   - `options bq25890_battery name=value [name=value ...]`
# Anything else is ignored.
#
# Output: two columns "name<TAB>value", one per name that was set.
map_output=$(
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^options[[:space:]]+bq25890_battery[[:space:]]+/ {
            rest = $0
            sub(/^options[[:space:]]+bq25890_battery[[:space:]]+/, "", rest)
            n = split(rest, toks, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                eq = index(toks[i], "=")
                if (eq > 1) {
                    nm = substr(toks[i], 1, eq - 1)
                    vl = substr(toks[i], eq + 1)
                    last[nm] = vl
                }
            }
            next
        }
        END {
            for (k in last) printf "%s\t%s\n", k, last[k]
        }
    ' "$CONF"
)

applied=0
skipped=0
failures=0
while IFS="$(printf '\t')" read -r name value; do
    [ -n "$name" ] || continue
    sysfs_path="$MODULE_DIR/$name"
    if [ ! -e "$sysfs_path" ]; then
        log "skip $name (no sysfs node)"
        skipped=$((skipped + 1))
        continue
    fi
    if [ ! -w "$sysfs_path" ]; then
        log "skip $name (sysfs node not writable)"
        skipped=$((skipped + 1))
        continue
    fi
    if echo "$value" > "$sysfs_path" 2>/dev/null; then
        log "applied $name=$value"
        applied=$((applied + 1))
    else
        log "FAILED to write $name=$value to $sysfs_path"
        failures=$((failures + 1))
    fi
done <<EOF
$map_output
EOF

log "done: applied=$applied skipped=$skipped failures=$failures"
[ "$failures" -eq 0 ]
