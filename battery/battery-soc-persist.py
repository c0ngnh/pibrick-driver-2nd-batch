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


def read_capacity():
    """Read current SOC from the driver."""
    try:
        with open(SYSFS_CAPACITY, "r") as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError, PermissionError):
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

    if save_persisted_soc(capacity):
        if not args.quiet:
            print(f"Saved SOC: {capacity}%")
    else:
        if not args.quiet:
            print(f"Error: Failed to save SOC", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
