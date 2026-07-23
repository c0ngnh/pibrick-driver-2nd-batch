#!/bin/sh
# piBrick Battery SOC Boot Loader
#
# Reads the persisted SOC from /var/lib/bq25890_battery/soc_persist (written
# previously by the shutdown hook or cron) and seeds the running kernel
# driver via the writable `coulomb_uah` sysfs attribute.
#
# IMPORTANT: This script uses the sysfs attribute, NOT modprobe.d injection.
# Two reasons:
#   1. udev loads the bq25890_battery module during device discovery,
#      often before systemd-modules-load.service runs — so the old
#      "rewrite modprobe.d, hope the driver reloads" approach was racy
#      and caused the 0%-display-after-boot failure mode on PocketCM5.
#   2. Writing sysfs coulomb_uah is atomic w.r.t. the driver state
#      machine: we set bq->fg_disch_remain_uah directly, no module
#      reload required.
#
# Sanity check: when seeded, we compare the persisted SOC to the SOC
# implied by the current battery voltage using the driver's OCV->SOC
# table. If the voltages disagree strongly (e.g. voltage is healthy
# 3.8 V but the persisted file says 0 %), we refuse to load the stale
# value and let the driver seed from OCV instead. This breaks the
# feedback loop where a 0% boot value keeps saving 0%.
#
# Idempotent and safe to run on any system where the driver may or may
# not be present (e.g. different hardware clones of this repo).

# NOTE: do not `set -e` — this script handles many "expected" missing
# conditions (no persist file, no driver, no voltage yet) and must exit
# cleanly in all of them.

SOC_PERSIST_FILE="/var/lib/bq25890_battery/soc_persist"
# sysfs attr is on the i2c_client (not power_supply child).
SYSFS_COULOMB="/sys/bus/i2c/devices"
SYSFS_VOLTAGE="/sys/class/power_supply/battery/voltage_now"
SYSFS_CHARGE_FULL="/sys/class/power_supply/battery/charge_full"

log() {
    # Surface in journal when run from systemd.
    echo "pibrick-battery-load-soc: $*"
}

# Nothing to do if there is no persisted value yet.
if [ ! -r "$SOC_PERSIST_FILE" ]; then
    log "no persisted SOC at $SOC_PERSIST_FILE; letting driver seed from OCV"
    exit 0
fi

# Parse and validate "soc=N".
SOC=$(awk -F= '/^soc=/{print $2; exit}' "$SOC_PERSIST_FILE" 2>/dev/null || true)
case "$SOC" in
    ''|*[!0-9]*) log "invalid persisted value; ignoring"; exit 0 ;;
esac
if [ "$SOC" -lt 0 ] || [ "$SOC" -gt 100 ]; then
    log "persisted SOC $SOC out of range; ignoring"
    exit 0
fi

# Wait briefly for the driver to expose coulomb_uah (udev-trigger may
# still be racing us). Capped at 15 s so we don't hang on misconfig.
COULOMB_FILE=""
i=0
while [ $i -lt 60 ]; do
    if [ -d "$SYSFS_COULOMB" ]; then
        for d in "$SYSFS_COULOMB"/*/; do
            [ -d "$d" ] || continue
            if [ -r "${d}name" ] && grep -qi 'bq2589' "${d}name" 2>/dev/null; then
                if [ -w "${d}coulomb_uah" ]; then
                    COULOMB_FILE="${d}coulomb_uah"
                    break 2
                fi
            fi
        done
    fi
    i=$((i + 1))
    sleep 0.25
done

if [ -z "$COULOMB_FILE" ]; then
    log "bq25890 driver did not come up; skipping SOC seed (will seed from OCV on next boot)"
    exit 0
fi

log "found coulomb_uah at $COULOMB_FILE"

# Sanity check: compare persisted SOC against the SOC implied by the
# current battery voltage. We use a tiny awk helper that mirrors the
# driver's static OCV->SOC table so the sanity check matches the
# driver's behavior. Keeping this in sync with bq25890_battery.c
# voltage_to_percent_table (the table is sorted voltage-DESC).
# Tolerance: persisted value is "stale" if voltage implies a SOC at
# least 15 points higher. (A 0% persisted with a 3.8 V battery is
# definitely stale; a 70% persisted with a 3.85 V battery can wait
# for the next coulomb integration tick to converge.)
VOLTAGE_UV=$(cat "$SYSFS_VOLTAGE" 2>/dev/null || echo 0)
CHARGE_FULL=$(cat "$SYSFS_CHARGE_FULL" 2>/dev/null || echo 0)
if [ -z "$VOLTAGE_UV" ] || [ "$VOLTAGE_UV" -lt 1000000 ] || [ "$VOLTAGE_UV" -gt 5000000 ]; then
    log "could not read voltage_now (got '$VOLTAGE_UV'); skipping sanity check"
    IMPLIES_PCT="-1"
else
    # Convert uV -> centivolts, then look up in the OCV table.
    CV=$((VOLTAGE_UV / 10000))
    IMPLIES_PCT=$(awk -v cv="$CV" 'BEGIN{
        # Voltages in centivolts, sorted ASCENDING. Keep in sync with
        # bq25890_battery.c voltage_to_percent_table — the driver uses
        # ascending voltage: low V = 0 %, high V = 100 %. Lookup returns
        # the SOC for the largest entry with V <= cv (bsearch-left).
        #
        # AUTO-GENERATED MIRROR of the current driver table — keep in
        # sync whenever voltage_to_percent_table is updated. The last
        # "max V" entry (here 418) is treated as 100 % so any higher
        # voltage is also reported as 100 %.
        split("330 332 332 333 340 340 343 348 350 358 364 369 373 375 379 383 386 391 394 418", v)
        split("  0   5  10  15  20  25  30  35  40  45  50  55  60  65  70  75  80  85  90 100", p)
        IMPLIED=0
        for (i=1; i<=length(v); i++) {
            if (v[i] <= cv) { IMPLIED = p[i] }
            else             { print IMPLIED; exit }
        }
        print IMPLIED
    }')
fi

if [ "$IMPLIES_PCT" != "-1" ]; then
    DELTA=$((IMPLIES_PCT - SOC))
    if [ "$DELTA" -ge 15 ]; then
        log "persisted SOC=$SOC% looks stale (voltage ${VOLTAGE_UV}uV implies ${IMPLIES_PCT}%); discarding"
        # Remove the stale file so we don't keep replaying it.
        rm -f "$SOC_PERSIST_FILE"
        exit 0
    fi
    log "sanity check OK: persisted SOC=$SOC%, voltage implies ${IMPLIES_PCT}%, delta=${DELTA}"
fi

# Convert SOC% to coulomb_uah (micro-amp-hours). Cap to design capacity
# to avoid clamping (coulomb_uah store clamps to charge_full_uah).
if [ -z "$CHARGE_FULL" ] || [ "$CHARGE_FULL" -le 0 ]; then
    log "could not read charge_full; aborting seed"
    exit 0
fi
UAH=$((SOC * CHARGE_FULL / 100))

if echo "$UAH" > "$COULOMB_FILE" 2>/dev/null; then
    log "seeded coulomb_uah=$UAH uAh (SOC=$SOC%) from $SOC_PERSIST_FILE"
else
    log "failed to write $COULOMB_FILE (driver may be busy)"
    exit 1
fi

exit 0
