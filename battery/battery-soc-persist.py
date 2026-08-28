#!/usr/bin/env python3
"""
piBrick SOC Persistence Helper

Saves the current SOC to /var/lib/bq25890_battery/soc_persist for
consistency across reboots.

This script should be run:
  1. Periodically (e.g., every 5 minutes via cron)
  2. On system shutdown (via systemd service)
  3. After battery_set.py changes coulomb_uah

Usage:
    python3 battery-soc-persist.py       # Save current SOC
    python3 battery-soc-persist.py --load # Print persisted SOC (for debugging)
    python3 battery-soc-persist.py --reset # Clear persisted SOC
"""

import os
import sys
import argparse

SOC_PERSIST_FILE = "/var/lib/bq25890_battery/soc_persist"
SYSFS_CAPACITY = "/sys/class/power_supply/battery/capacity"
SYSFS_VOLTAGE = "/sys/class/power_supply/battery/voltage_now"
SYSFS_STATUS = "/sys/class/power_supply/battery/status"
SYSFS_OCV_SOC = "/sys/class/power_supply/battery/ocv_soc_pct"
# Refuse to persist values that obviously don't match the battery.
# Below this voltage (uV) the cell is critically discharged and writing
# any value to the file risks the "0% boot loop".
MIN_SAVE_VOLTAGE_UV = 3_300_000   # ~3.30 V (LiPo ~10% SOC)
REFUSE_PCT = 0
# Same stale rule as pibrick-battery-load-soc.sh: empty-looking SOC with
# a healthy cell, or a large OCV gap while not charging.
STALE_DELTA_PCT = 15
STALE_LOW_PCT = 15


def read_sysfs(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, IOError):
        return None


def read_int_sysfs(path):
    raw = read_sysfs(path)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def read_capacity():
    """Read current SOC from the driver."""
    return read_int_sysfs(SYSFS_CAPACITY)


def ocv_pct_from_voltage_uv(voltage_uv):
    """Coarse fallback if ocv_soc_pct sysfs is missing (older driver)."""
    if voltage_uv is None or voltage_uv < 1_000_000 or voltage_uv > 5_000_000:
        return None
    cv = voltage_uv // 10000
    table = (
        (330, 0), (337, 2), (340, 9), (344, 18), (348, 24),
        (352, 30), (356, 35), (360, 43), (365, 51), (370, 55),
        (375, 63), (380, 73), (385, 78), (390, 88), (395, 94),
        (400, 96), (410, 100),
    )
    implied = 0
    for v, p in table:
        if v <= cv:
            implied = p
        else:
            break
    return implied


def read_ocv_soc():
    """SOC implied by the driver's OCV table (preferred) or voltage fallback."""
    pct = read_int_sysfs(SYSFS_OCV_SOC)
    if pct is not None and 0 <= pct <= 100:
        return pct
    return ocv_pct_from_voltage_uv(read_int_sysfs(SYSFS_VOLTAGE))


def is_charging():
    status = read_sysfs(SYSFS_STATUS)
    return status is not None and status.lower() == "charging"


def soc_is_stale(capacity, ocv_pct, charging):
    """True if capacity looks like an empty coulomb counter, not a real SOC."""
    if capacity is None or ocv_pct is None:
        return False
    delta = ocv_pct - capacity
    if delta < STALE_DELTA_PCT:
        return False
    if capacity < STALE_LOW_PCT:
        return True
    if charging:
        return False
    return True


def load_persisted_soc():
    """Load persisted SOC from file."""
    try:
        with open(SOC_PERSIST_FILE, "r") as f:
            content = f.read().strip()
            if content.startswith("soc="):
                soc = int(content.split("=")[1])
                if 0 <= soc <= 100:
                    return soc
    except (FileNotFoundError, ValueError, PermissionError):
        pass
    return None


def save_persisted_soc(soc):
    """Save SOC to persistence file."""
    if soc is None or not (0 <= soc <= 100):
        return False

    os.makedirs(os.path.dirname(SOC_PERSIST_FILE), exist_ok=True)

    try:
        with open(SOC_PERSIST_FILE, "w") as f:
            f.write(f"soc={soc}\n")
        return True
    except (IOError, PermissionError) as e:
        print(f"Error saving SOC: {e}", file=sys.stderr)
        return False


def persist_allowed(capacity, force=False):
    """Return (ok, reason). reason is set when ok is False."""
    if capacity is None or not (0 <= capacity <= 100):
        return False, "Cannot read current SOC"
    if force:
        return True, None
    if capacity == REFUSE_PCT:
        return False, (
            "Refusing to persist SOC=0% (looks like stale coulomb reading). "
            "Use --force to override."
        )
    voltage = read_int_sysfs(SYSFS_VOLTAGE)
    if voltage is not None and voltage < MIN_SAVE_VOLTAGE_UV and capacity < 10:
        return False, (
            f"Refusing to persist SOC={capacity}% at voltage {voltage} uV "
            f"(cell near-empty; driver reading is unreliable). "
            f"Use --force to override."
        )
    ocv_pct = read_ocv_soc()
    if soc_is_stale(capacity, ocv_pct, is_charging()):
        return False, (
            f"Refusing to persist SOC={capacity}% "
            f"(voltage implies {ocv_pct}%; looks like empty coulomb). "
            f"Use --force to override."
        )
    return True, None


def main():
    parser = argparse.ArgumentParser(
        description="piBrick SOC Persistence Helper"
    )
    parser.add_argument("--load", action="store_true",
                       help="Load and print persisted SOC")
    parser.add_argument("--reset", action="store_true",
                       help="Reset (clear) persisted SOC")
    parser.add_argument("--quiet", "-q", action="store_true",
                       help="Suppress output")
    parser.add_argument("--force", action="store_true",
                       help="Bypass 0%%/stale-vs-voltage safety checks and "
                            "persist the driver's current reading anyway.")
    args = parser.parse_args()

    if args.load:
        soc = load_persisted_soc()
        if soc is not None:
            print(f"Persisted SOC: {soc}%")
        else:
            print("No persisted SOC found")
        return

    if args.reset:
        try:
            if os.path.exists(SOC_PERSIST_FILE):
                os.remove(SOC_PERSIST_FILE)
                if not args.quiet:
                    print("Persisted SOC cleared")
            else:
                if not args.quiet:
                    print("No persisted SOC file to clear")
        except (IOError, PermissionError) as e:
            print(f"Error clearing SOC: {e}", file=sys.stderr)
            sys.exit(1)
        return

    capacity = read_capacity()
    ok, reason = persist_allowed(capacity, force=args.force)
    if not ok:
        if not args.quiet:
            print(f"Error: {reason}" if reason and reason.startswith("Cannot")
                  else reason, file=sys.stderr)
        sys.exit(1 if reason and reason.startswith("Cannot") else 2)

    if save_persisted_soc(capacity):
        if not args.quiet:
            print(f"Saved SOC: {capacity}%")
    else:
        if not args.quiet:
            print("Error: Failed to save SOC", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
