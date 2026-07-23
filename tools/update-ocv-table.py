#!/usr/bin/env python3
"""Update the driver OCV table with a calibrated, monotonic mapping.

Reads /var/log/bq25890_battery/calibration_status.json, generates a smooth,
monotonically non-increasing voltage-to-SOC table (one entry per 5 % SOC
bucket), then patches bq25890_battery.c in place.

Usage:
    sudo python3 update-ocv-table.py [--driver PATH] [--status PATH]

Defaults:
    --driver battery/bq25890_battery.c (relative to repo root)
    --status /var/log/bq25890_battery/calibration_status.json
"""

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DRIVER = REPO_ROOT / "battery" / "bq25890_battery.c"
DEFAULT_STATUS = Path("/var/log/bq25890_battery/calibration_status.json")

START_MARKER = "static VoltageMap voltage_to_percent_table[] = {"
END_MARKER = "};"


def load_calibration(status_path: Path):
    """Return list of {voltage_cv: int, soc: int} from the calibration JSON."""
    with open(status_path) as f:
        data = json.load(f)
    table = data.get("suggested_table", [])
    if not table:
        raise SystemExit(f"No suggested_table found in {status_path}")
    return [(p["soc"], p["voltage_cv"]) for p in table]


def build_monotonic_table(soc_voltage):
    """Average voltages into 5 % SOC buckets, enforce monotonicity.

    Returns list of (soc, voltage_cv) sorted by voltage DESCENDING (the
    order the driver's bq25890_calc_lipo_percentage() expects). Within a
    flat plateau the higher SOC comes first so that lookup walks from
    'top charge' downward.
    """
    if not soc_voltage:
        raise SystemExit("Empty calibration data")

    # Group into 5% buckets by averaging nearby samples.
    bucketed = {}
    for soc, v in soc_voltage:
        bucket = int(soc // 5) * 5
        bucketed.setdefault(bucket, []).append(v)

    averaged = []
    for bucket in sorted(bucketed):
        avg = int(round(sum(bucketed[bucket]) / len(bucketed[bucket])))
        averaged.append((bucket, avg))

    # Pass 1: enforce non-decreasing with aggressive smoothing. The raw
    # calibration data is noisy at the low-SOC tail (the device rarely
    # sees <20 % SOC on a daily charge cycle, so each sample is from a
    # small set of cycles). Snap any drop up to the running max — LiPo
    # cells are guaranteed monotone over the whole SOC range, so any
    # non-monotonicity in the raw data is noise.
    monotone = []
    prev_v = 0
    for soc, v in averaged:
        if v < prev_v:
            v = prev_v
        monotone.append((soc, v))
        prev_v = v

    # Sort by voltage DESCENDING, then by SOC DESCENDING for tie-breaking
    # so equal-voltage buckets land in 'higher SOC first' order.
    monotone.sort(key=lambda x: (-x[1], -x[0]))
    return monotone


def render_table_c(monotone):
    """Render the C source block for the OCV table."""
    lines = [
        "static VoltageMap voltage_to_percent_table[] = {",
    ]
    for soc, v in monotone:
        lines.append(f"\t{{ {v}, {soc:>3} }},")
    lines.append("};")
    return "\n".join(lines)


def patch_driver(driver_path: Path, table_block: str) -> bool:
    """Replace the voltage_to_percent_table[] block in the driver source.

    Returns True if the file was modified, False if no replacement happened.
    """
    content = driver_path.read_text()
    start = content.find(START_MARKER)
    if start == -1:
        raise SystemExit(f"Could not find '{START_MARKER}' in {driver_path}")

    # Find the closing "};" — we want the first one that follows the start.
    end = content.find(END_MARKER, start)
    if end == -1:
        raise SystemExit(f"Could not find closing '{END_MARKER}' after table")

    end += len(END_MARKER)

    # Detect what comes immediately after the closing "};" so we preserve
    # the original separator (single newline vs blank line) instead of
    # doubling up every time we run.
    trailing = ""
    after = content[end:end + 2]
    if after.startswith("\n\n"):
        trailing = "\n"  # blank line separator
    elif after.startswith("\n"):
        trailing = ""  # single newline, leave it as-is

    new_content = content[:start] + table_block + trailing + content[end:]
    if new_content == content:
        return False
    driver_path.write_text(new_content)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--driver", type=Path, default=DEFAULT_DRIVER,
                        help=f"Path to bq25890_battery.c (default: {DEFAULT_DRIVER})")
    parser.add_argument("--status", type=Path, default=DEFAULT_STATUS,
                        help=f"Calibration status JSON (default: {DEFAULT_STATUS})")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the new table without modifying the driver")
    args = parser.parse_args()

    if not args.status.exists():
        sys.exit(f"Calibration status not found: {args.status}\n"
                 "Run battery-auto-calibrator.py --check first.")

    soc_voltage = load_calibration(args.status)
    print(f"Loaded {len(soc_voltage)} SOC/voltage points from {args.status}")

    monotone = build_monotonic_table(soc_voltage)
    table_block = render_table_c(monotone)

    print(f"\nGenerated {len(monotone)}-point monotonic OCV table:")
    print(table_block)

    if args.dry_run:
        print("\n(--dry-run: driver not modified)")
        return

    if not args.driver.exists():
        sys.exit(f"Driver source not found: {args.driver}")

    if patch_driver(args.driver, table_block):
        print(f"\nPatched: {args.driver}")
    else:
        print(f"\nDriver already up to date: {args.driver}")


if __name__ == "__main__":
    main()
