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
# Refuse to persist values that obviously don't match the battery.
# Below this voltage (uV) the cell is critically discharged and writing
# any value to the file risks the "0% boot loop" — the driver will
# happily report 0% while charging is happening (it integrates from
# OCV) and cron will dutifully persist that 0% forever.
MIN_SAVE_VOLTAGE_UV = 3_300_000   # ~3.30 V (LiPo ~10% SOC)
# Also refuse to write 0% explicitly — even at higher voltages, a
# 0% report usually means the coulomb counter has desynced, not that
# the cell is truly empty. The user should explicitly clear or
# re-seed via `battery_set.py coulomb_uah <value>` if they really
# want to mark it empty.
REFUSE_PCT = 0


def read_sysfs(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, IOError):
        return None


def read_capacity():
    """Read current SOC from the driver."""
    raw = read_sysfs(SYSFS_CAPACITY)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


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

    # Ensure directory exists
    os.makedirs(os.path.dirname(SOC_PERSIST_FILE), exist_ok=True)

    try:
        with open(SOC_PERSIST_FILE, "w") as f:
            f.write(f"soc={soc}\n")
        return True
    except (IOError, PermissionError) as e:
        print(f"Error saving SOC: {e}", file=sys.stderr)
        return False


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
                       help="Bypass the 0%%/low-voltage safety checks and "
                            "persist the driver's current reading anyway. "
                            "Use only when you're sure the cell really is at 0%%.")
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

    # Default: save current SOC
    capacity = read_capacity()
    if capacity is None:
        if not args.quiet:
            print("Error: Cannot read current SOC", file=sys.stderr)
        sys.exit(1)

    # Refuse to write 0% — that's almost always a stale coulomb-counter
    # reading, not a real "the cell is empty" reading. Persisting 0%
    # causes a feedback loop where the next boot shows 0%, which gets
    # persisted again, forever.
    if capacity == REFUSE_PCT and not args.force:
        if not args.quiet:
            print(f"Refusing to persist SOC=0% (looks like stale coulomb reading). "
                  f"Use --force to override.", file=sys.stderr)
        sys.exit(2)

    # Refuse to persist when voltage is critically low. At < 3.3 V the
    # driver may legitimately report 0% while charging is already
    # happening; saving that value prevents the next boot from picking
    # up the higher SOC after a partial charge cycle.
    if not args.force:
        voltage = read_sysfs(SYSFS_VOLTAGE)
        if voltage is not None:
            try:
                uv = int(voltage)
            except ValueError:
                uv = 0
            if uv < MIN_SAVE_VOLTAGE_UV and capacity < 10:
                if not args.quiet:
                    print(f"Refusing to persist SOC={capacity}% at voltage "
                          f"{uv} uV (cell near-empty; driver reading is unreliable). "
                          f"Use --force to override.", file=sys.stderr)
                sys.exit(2)

    if save_persisted_soc(capacity):
        if not args.quiet:
            print(f"Saved SOC: {capacity}%")
    else:
        if not args.quiet:
            print(f"Error: Failed to save SOC", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
