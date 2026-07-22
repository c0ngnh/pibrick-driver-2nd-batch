#!/usr/bin/env python3
"""
Battery/INA228 interactive parameter setter.

Usage:
    sudo python3 battery_set.py                 # Interactive mode
    sudo python3 battery_set.py <param> <value> # Non-interactive
"""

import os
import sys
import argparse

BASE_POWER = "/sys/class/power_supply/battery"
BASE_MODULE = "/sys/module/bq25890_battery/parameters"

PARAMS = {
    # Module parameters (need driver reload)
    "charge_full_uah": {
        "desc": "Battery design capacity",
        "unit": "mAh",
        "unit_hint": "mAh",
        "is_module": True,
        "read_only": False,
        "reload_needed": True,
    },
    "ina228_shunt_uohm": {
        "desc": "INA228 shunt resistance",
        "unit": "mΩ",
        "unit_hint": "mΩ",
        "is_module": True,
        "read_only": False,
        "reload_needed": True,
    },
    "ina228_max_current_ua": {
        "desc": "INA228 max current range",
        "unit": "mA",
        "unit_hint": "mA",
        "is_module": True,
        "read_only": False,
        "reload_needed": True,
    },
    "discharge_current_ua": {
        "desc": "Avg discharge current (time-to-empty estimate)",
        "unit": "mA",
        "unit_hint": "mA",
        "is_module": True,
        "read_only": False,
        "reload_needed": True,
    },
    # Sysfs (immediate effect)
    "coulomb_uah": {
        "desc": "Coulomb counter (reset battery SOC estimate)",
        "unit": "mAh",
        "unit_hint": "mAh",
        "is_module": False,
        "read_only": False,
        "reload_needed": False,
    },
}

UNIT_SCALES = {
    "uAh": 1,       "mAh": 1_000,      "Ah":  1_000_000,
    "uA":  1,       "mA":  1_000,      "A":   1_000_000,
    "uV":  1,       "mV":  1_000,      "V":   1_000_000,
    "uΩ":  1,       "mΩ":  1_000,      "Ω":   1_000_000,
    "mW":  1,
}

INTERNAL_SCALES = {  # for sysfs writing
    "uAh": 1,       "mAh": 1_000,      "Ah":  1_000_000,
    "uA":  1,       "mA":  1_000,      "A":   1_000_000,
    "uV":  1,       "mV":  1_000,      "V":   1_000_000,
    "uΩ":  1,       "mΩ":  1_000,      "Ω":   1_000_000,
}


def sysfs_path(name):
    p = PARAMS[name]
    if p["is_module"]:
        return f"{BASE_MODULE}/{name}"
    return f"{BASE_POWER}/{name}"


def read_param(name):
    path = sysfs_path(name)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return f.read().strip()
    except PermissionError:
        return None


def write_param(name, value):
    path = sysfs_path(name)
    with open(path, "w") as f:
        f.write(str(int(value)))
        f.write("\n")


def parse_value(value_str, unit_hint):
    # Try splitting unit from numeric part
    for unit in sorted(INTERNAL_SCALES.keys(), key=len, reverse=True):
        if value_str.lower().endswith(unit.lower()):
            num_str = value_str[:-len(unit)].strip()
            return float(num_str) * INTERNAL_SCALES[unit]
    # No unit given — use hint
    scale = INTERNAL_SCALES.get(unit_hint, 1)
    return float(value_str) * scale


def fmt_readable(name, raw_val):
    p = PARAMS[name]
    unit = p["unit"]
    if raw_val is None:
        return "(not available)", "(not available)"
    try:
        raw = int(raw_val)
    except ValueError:
        return raw_val, raw_val
    scale = INTERNAL_SCALES.get(unit, 1)
    display = raw / scale
    if scale >= 1_000_000:
        return f"{display:.3f} {unit}", str(raw)
    elif scale >= 1_000:
        return f"{display:.1f} {unit}", str(raw)
    return f"{display} {unit}", str(raw)


def interactive():
    print("\n=== piBrick Battery Parameter Setter ===\n")

    # Show current values first
    print("Current values:\n")
    print(f"  {'Parameter':<30}  {'Current':<15}  {'Path'}")
    print(f"  {'-'*30}  {'-'*15}  {'-'*40}")
    for name, p in PARAMS.items():
        path = sysfs_path(name)
        val_str, _ = fmt_readable(name, read_param(name))
        marker = " (RO)" if p.get("read_only") else ""
        print(f"  {name:<30}  {val_str:<15}  {path}{marker}")

    print()
    print("Which parameter do you want to change?")
    for i, name in enumerate(PARAMS, 1):
        print(f"  {i}) {name}")
    print(f"  0) Quit")

    while True:
        try:
            choice = input("\nEnter number: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

        if choice == "0":
            return
        try:
            idx = int(choice) - 1
            name = list(PARAMS.keys())[idx]
            break
        except (ValueError, IndexError):
            print("Invalid choice. Enter a number from the list.")

    p = PARAMS[name]
    unit = p["unit"]
    unit_hint = p["unit_hint"]

    current_raw, current_str = fmt_readable(name, read_param(name))
    print(f"\n{p['desc']} ({name})")
    print(f"  Current value: {current_str} {unit}")
    print(f"  Unit hint: {unit_hint}")

    if p.get("reload_needed"):
        print(f"  Note: This requires driver reload to take effect.")

    while True:
        try:
            val_input = input(f"\nNew value (in {unit_hint}, or with unit): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

        if not val_input:
            print("No value entered.")
            continue

        # Validate: parse the input
        try:
            value = parse_value(val_input, unit_hint)
        except ValueError:
            print(f"Invalid number: '{val_input}'. Try again.")
            continue

        # Sanity check
        if value < 0:
            print("Value cannot be negative.")
            continue

        print(f"\n  Setting {name} = {value:.0f} ({val_input})")
        try:
            write_param(name, value)
            print("  -> Done!")
        except PermissionError:
            print("  -> ERROR: permission denied. Run with sudo.")
            return
        except FileNotFoundError:
            print(f"  -> ERROR: path not found. Is the driver loaded?")
            return
        except Exception as e:
            print(f"  -> ERROR: {e}")
            return

        if p.get("reload_needed"):
            print()
            print("  Driver reload required:")
            print("    sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery")
        return


def noninteractive(name, value_str):
    if name not in PARAMS:
        print(f"Unknown parameter: {name}")
        print("Use 'python3 battery_set.py --list' to see available parameters.")
        sys.exit(1)

    p = PARAMS[name]
    if p.get("read_only"):
        val = read_param(name)
        print(f"{name} = {fmt_readable(name, val)[0]}  (read-only)")
        sys.exit(1)

    try:
        value = parse_value(value_str, p["unit_hint"])
    except ValueError:
        print(f"Invalid value: {value_str}")
        sys.exit(1)

    print(f"Setting {name} = {value:.0f} {p['unit']}")

    try:
        write_param(name, value)
        print("Done.")
    except PermissionError:
        print("ERROR: permission denied. Run with sudo.")
        sys.exit(1)
    except FileNotFoundError:
        print(f"ERROR: path not found. Is the driver loaded?")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    if p.get("reload_needed"):
        print()
        print("Driver reload required:")
        print("  sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery")


def show_all():
    print("\n=== Current Values ===\n")
    print(f"  {'Parameter':<30}  {'Current':<15}  Effect")
    print(f"  {'-'*30}  {'-'*15}  {'-'*10}")
    for name, p in PARAMS.items():
        val_str, _ = fmt_readable(name, read_param(name))
        effect = "immediate" if not p.get("reload_needed") else "reload"
        marker = " (RO)" if p.get("read_only") else ""
        print(f"  {name:<30}  {val_str:<15}  {effect}{marker}")


def list_params():
    print("\n=== Settable Parameters ===\n")
    for name, p in PARAMS.items():
        cur, raw = fmt_readable(name, read_param(name))
        note = "reload" if p.get("reload_needed") else "immediate"
        print(f"  {name}")
        print(f"    {p['desc']}")
        print(f"    Current: {cur}  [{note}]")
        print()


def main():
    parser = argparse.ArgumentParser(description="piBrick battery parameter setter")
    parser.add_argument("param", nargs="?", help="Parameter name")
    parser.add_argument("value", nargs="?", help="New value")
    parser.add_argument("--list", action="store_true", help="List all parameters")
    args = parser.parse_args()

    if args.list:
        list_params()
        return

    if args.param is None:
        if os.isatty(sys.stdin.fileno()):
            interactive()
        else:
            print("No TTY detected. Use non-interactive mode:")
            print("  python3 battery_set.py <param> <value>")
            print("  python3 battery_set.py --list")
            sys.exit(1)
        return

    if args.value is None:
        # Read-only query
        if args.param in PARAMS:
            val = read_param(args.param)
            print(f"{args.param} = {fmt_readable(args.param, val)[0]}")
        else:
            print(f"Unknown parameter: {args.param}")
            sys.exit(1)
        return

    noninteractive(args.param, args.value)


if __name__ == "__main__":
    main()
