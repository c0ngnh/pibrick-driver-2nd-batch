#!/bin/sh
# piBrick Battery SOC Boot Loader
#
# Seeds the running kernel driver via the writable `coulomb_uah` sysfs
# attribute. Coulomb remaining capacity is RAM-only: after reboot it is
# -1 / 0 until something writes this node. If we leave it at 0, the
# first INA228 sample publishes 0% even when the cell is at 4.1 V.
#
# Seed source, in order:
#   1. /var/lib/bq25890_battery/soc_persist, if it is in range and not
#      obviously stale vs the driver's OCV table.
#   2. Otherwise the SOC from ocv_soc_pct (driver table), falling back
#      to a coarse voltage lookup if that sysfs node is missing.
#
# Stale persist: empty-looking SOC (<15%) while voltage implies 15+
# points more, or a large OCV gap while not charging. While charging,
# a mid-pack persist is trusted because terminal voltage is inflated.

# NOTE: do not `set -e` — this script handles many "expected" missing
# conditions (no persist file, no driver, no voltage yet) and must exit
# cleanly in all of them.

SOC_PERSIST_FILE="/var/lib/bq25890_battery/soc_persist"
SYSFS_COULOMB="/sys/bus/i2c/devices"
SYSFS_VOLTAGE="/sys/class/power_supply/battery/voltage_now"
SYSFS_CHARGE_FULL="/sys/class/power_supply/battery/charge_full"
SYSFS_OCV_SOC="/sys/class/power_supply/battery/ocv_soc_pct"
SYSFS_STATUS="/sys/class/power_supply/battery/status"
STALE_DELTA=15
STALE_LOW=15

log() {
    echo "pibrick-battery-load-soc: $*"
}

# Coarse OCV→SOC table (centivolts). Used only when ocv_soc_pct is absent.
ocv_pct_from_cv() {
    awk -v cv="$1" 'BEGIN{
        split("330 337 340 344 348 352 356 360 365 370 375 380 385 390 395 400 410", v)
        split("  0   2   9  18  24  30  35  43  51  55  63  73  78  88  94  96 100", p)
        IMPLIED=0
        for (i=1; i<=length(v); i++) {
            if (v[i] <= cv) { IMPLIED = p[i] }
            else             { print IMPLIED; exit }
        }
        print IMPLIED
    }'
}

# Wait for the driver to expose coulomb_uah (udev-trigger may still be
# racing us). Capped at 15 s so we don't hang on misconfig.
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
    log "bq25890 driver did not come up; skipping SOC seed"
    exit 0
fi

log "found coulomb_uah at $COULOMB_FILE"

# Voltage can lag the sysfs node by a sample; wait briefly so the OCV
# fallback is not 0% because voltage_now was still unset.
VOLTAGE_UV=0
i=0
while [ $i -lt 20 ]; do
    VOLTAGE_UV=$(cat "$SYSFS_VOLTAGE" 2>/dev/null || echo 0)
    case "$VOLTAGE_UV" in
        ''|*[!0-9-]*) VOLTAGE_UV=0 ;;
    esac
    if [ "$VOLTAGE_UV" -ge 1000000 ] && [ "$VOLTAGE_UV" -le 5000000 ]; then
        break
    fi
    i=$((i + 1))
    sleep 0.25
done

IMPLIES_PCT="-1"
if [ -r "$SYSFS_OCV_SOC" ]; then
    OCV_RAW=$(cat "$SYSFS_OCV_SOC" 2>/dev/null || echo "")
    case "$OCV_RAW" in
        ''|*[!0-9-]*) ;;
        *)
            if [ "$OCV_RAW" -ge 0 ] && [ "$OCV_RAW" -le 100 ]; then
                IMPLIES_PCT="$OCV_RAW"
            fi
            ;;
    esac
fi
if [ "$IMPLIES_PCT" = "-1" ]; then
    if [ "$VOLTAGE_UV" -ge 1000000 ] && [ "$VOLTAGE_UV" -le 5000000 ]; then
        CV=$((VOLTAGE_UV / 10000))
        IMPLIES_PCT=$(ocv_pct_from_cv "$CV")
    else
        log "could not read voltage_now (got '$VOLTAGE_UV')"
    fi
fi

STATUS=$(cat "$SYSFS_STATUS" 2>/dev/null || echo "")
CHARGING=0
case "$STATUS" in
    [Cc]harging) CHARGING=1 ;;
esac

SOC=""
if [ -r "$SOC_PERSIST_FILE" ]; then
    SOC=$(awk -F= '/^soc=/{print $2; exit}' "$SOC_PERSIST_FILE" 2>/dev/null || true)
    case "$SOC" in
        ''|*[!0-9]*)
            log "invalid persisted value; ignoring $SOC_PERSIST_FILE"
            SOC=""
            ;;
        *)
            if [ "$SOC" -lt 0 ] || [ "$SOC" -gt 100 ]; then
                log "persisted SOC $SOC out of range; ignoring"
                SOC=""
            fi
            ;;
    esac
else
    log "no persisted SOC at $SOC_PERSIST_FILE"
fi

persist_is_stale() {
    # $1 persist $2 implies
    _p=$1
    _i=$2
    if [ "$_i" = "-1" ]; then
        return 1
    fi
    _d=$((_i - _p))
    if [ "$_d" -lt "$STALE_DELTA" ]; then
        return 1
    fi
    if [ "$_p" -lt "$STALE_LOW" ]; then
        return 0
    fi
    if [ "$CHARGING" -eq 1 ]; then
        return 1
    fi
    return 0
}

SEED_SOC=""
SEED_SRC=""
if [ -n "$SOC" ]; then
    if persist_is_stale "$SOC" "$IMPLIES_PCT"; then
        log "persisted SOC=$SOC% looks stale (voltage ${VOLTAGE_UV}uV implies ${IMPLIES_PCT}%); discarding"
        rm -f "$SOC_PERSIST_FILE"
        if [ "$IMPLIES_PCT" != "-1" ]; then
            SEED_SOC="$IMPLIES_PCT"
            SEED_SRC="OCV"
        fi
    else
        if [ "$IMPLIES_PCT" != "-1" ]; then
            log "sanity check OK: persisted SOC=$SOC%, voltage implies ${IMPLIES_PCT}%"
        fi
        SEED_SOC="$SOC"
        SEED_SRC="persist"
    fi
elif [ "$IMPLIES_PCT" != "-1" ]; then
    SEED_SOC="$IMPLIES_PCT"
    SEED_SRC="OCV"
fi

if [ -z "$SEED_SOC" ]; then
    log "no persist and no voltage; leaving coulomb unseeded for the driver OCV path"
    exit 0
fi

CHARGE_FULL=$(cat "$SYSFS_CHARGE_FULL" 2>/dev/null || echo 0)
case "$CHARGE_FULL" in
    ''|*[!0-9]*) CHARGE_FULL=0 ;;
esac
if [ "$CHARGE_FULL" -le 0 ]; then
    log "could not read charge_full; aborting seed"
    exit 0
fi

UAH=$((SEED_SOC * CHARGE_FULL / 100))

if echo "$UAH" > "$COULOMB_FILE" 2>/dev/null; then
    log "seeded coulomb_uah=$UAH uAh (SOC=$SEED_SOC%) from $SEED_SRC"
else
    log "failed to write $COULOMB_FILE (driver may be busy)"
    exit 1
fi

exit 0
