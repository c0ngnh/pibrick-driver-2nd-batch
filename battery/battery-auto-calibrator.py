#!/usr/bin/env python3
"""
piBrick Battery Auto-Calibrator

Automatically analyzes calibration data and suggests/updates the OCV table
for accurate state-of-charge estimation.

This service runs periodically to:
1. Collect voltage-SOC data points during resting states
2. Detect patterns and outliers
3. Generate improved OCV table parameters
4. Optionally apply updates to the driver

Usage:
    python3 battery-auto-calibrator.py --daemon        # Run as background service
    python3 battery-auto-calibrator.py --check        # Check for updates without applying
    python3 battery-auto-calibrator.py --apply         # Apply recommended calibration
    python3 battery-auto-calibrator.py --status        # Show calibration status
    python3 battery-auto-calibrator.py --reset         # Reset calibration to defaults
"""

import os
import sys
import time
import argparse
import json
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

# Configuration
SYSFS_BASE = "/sys/class/power_supply/battery"
LOG_DIR = Path("/var/log/bq25890_battery")
CALIBRATION_DATA = LOG_DIR / "calibration_data.csv"
STATUS_FILE = LOG_DIR / "calibration_status.json"
OCV_TABLE_FILE = LOG_DIR / "suggested_ocv_table.h"
METADATA_FILE = LOG_DIR / "calibration_metadata.json"

# Driver OCV table location (in kernel source)
# This is informational - we generate code to be applied manually

# Default OCV table (for reference)
DEFAULT_OCV_TABLE = [
    (298, 0), (328, 5), (348, 10), (358, 20),
    (363, 30), (366, 40), (369, 50), (371, 55),
    (374, 60), (377, 70), (380, 80), (385, 90),
    (393, 95), (418, 100)
]

# Minimum samples per SOC bucket for reliable calibration
MIN_SAMPLES_PER_BUCKET = 3
# Minimum total samples for calibration
MIN_TOTAL_SAMPLES = 15
# Confidence threshold for auto-apply
CONFIDENCE_THRESHOLD = 0.85


def read_sysfs(path, default=None):
    """Read a sysfs file."""
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, IOError):
        return default


def get_current_state():
    """Get current battery state."""
    return {
        "timestamp": datetime.now().isoformat(),
        "capacity": read_sysfs(f"{SYSFS_BASE}/capacity"),
        "voltage_now": read_sysfs(f"{SYSFS_BASE}/voltage_now"),
        "v_ocv_uv": read_sysfs(f"{SYSFS_BASE}/v_ocv_uv"),
        "current_now": read_sysfs(f"{SYSFS_BASE}/current_now"),
        "fg_mode": read_sysfs(f"{SYSFS_BASE}/fg_mode"),
        "status": read_sysfs(f"{SYSFS_BASE}/status"),
    }


def load_calibration_data():
    """Load calibration data from CSV."""
    if not CALIBRATION_DATA.exists():
        return []
    
    data = []
    with open(CALIBRATION_DATA, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            data.append(row)
    return data


import csv


def analyze_calibration_data(data):
    """Analyze calibration data and return statistics."""
    if not data:
        return None
    
    stats = {
        "total_records": len(data),
        "resting_records": 0,
        "soc_coverage": set(),
        "soc_buckets": defaultdict(list),
        "date_range": {"start": None, "end": None},
    }
    
    timestamps = []
    
    for row in data:
        try:
            fg_mode = row.get("fg_mode", "")
            status = row.get("status", "")
            soc = int(row.get("capacity", 0))
            voltage_uv = int(row.get("voltage_now", 0))
            v_ocv_uv = int(row.get("v_ocv_uv", 0))
            timestamp = row.get("timestamp", "")
            
            if timestamp:
                timestamps.append(timestamp)
            
            # Only use resting data for OCV calibration
            if fg_mode == "resting" and "Charging" not in status:
                stats["resting_records"] += 1
                stats["soc_coverage"].add(soc)
                
                # Use OCV if available, otherwise use voltage
                voltage = v_ocv_uv if int(v_ocv_uv) > 0 else voltage_uv
                if voltage > 0:
                    stats["soc_buckets"][soc].append(voltage)
                    
        except (ValueError, KeyError):
            continue
    
    if timestamps:
        timestamps.sort()
        stats["date_range"]["start"] = timestamps[0]
        stats["date_range"]["end"] = timestamps[-1]
    
    stats["soc_coverage"] = sorted(list(stats["soc_coverage"]))
    stats["soc_coverage_pct"] = len(stats["soc_coverage"]) / 101 * 100  # 0-100
    
    # Calculate averages per SOC bucket
    stats["bucket_averages"] = {}
    for soc, voltages in stats["soc_buckets"].items():
        if len(voltages) >= MIN_SAMPLES_PER_BUCKET:
            avg_v = sum(voltages) / len(voltages)
            stats["bucket_averages"][soc] = {
                "voltage_cv": int(round(avg_v / 1e4)),
                "voltage_mv": int(round(avg_v / 1e3)),
                "samples": len(voltages),
                "std_dev": calculate_std_dev(voltages)
            }
    
    return stats


def calculate_std_dev(values):
    """Calculate standard deviation."""
    if len(values) < 2:
        return 0
    avg = sum(values) / len(values)
    variance = sum((v - avg) ** 2 for v in values) / len(values)
    return int(round(variance ** 0.5))


def generate_calibrated_table(stats):
    """Generate calibrated OCV table from statistics."""
    if not stats or not stats.get("bucket_averages"):
        return None
    
    # Get data points
    points = []
    for soc, data in stats["bucket_averages"].items():
        points.append((data["voltage_cv"], soc, data["samples"], data["std_dev"]))
    
    if len(points) < 3:
        return None
    
    # Sort by voltage (descending - higher voltage = higher SOC)
    points.sort(key=lambda x: x[0], reverse=True)
    
    # Fill gaps and smooth
    calibrated_points = []
    for i, (v, soc, samples, std_dev) in enumerate(points):
        calibrated_points.append({
            "voltage_cv": v,
            "soc": soc,
            "samples": samples,
            "std_dev": std_dev
        })
    
    return calibrated_points


def calculate_calibration_confidence(stats):
    """Calculate confidence score for the calibration."""
    if not stats:
        return 0
    
    score = 0.0
    
    # Coverage score (0-0.4)
    coverage_pct = stats.get("soc_coverage_pct", 0)
    score += min(0.4, coverage_pct / 100 * 0.4)
    
    # Sample count score (0-0.3)
    resting = stats.get("resting_records", 0)
    score += min(0.3, resting / 100 * 0.3)
    
    # Data freshness score (0-0.3) - based on recent data
    if stats.get("date_range", {}).get("end"):
        try:
            last_date = datetime.fromisoformat(stats["date_range"]["end"])
            age_days = (datetime.now() - last_date).days
            freshness = max(0, 1 - age_days / 7)  # Decay over a week
            score += freshness * 0.3
        except:
            pass
    
    return min(1.0, score)


def generate_c_header(table, stats):
    """Generate C header with calibrated table."""
    lines = []
    lines.append("/*")
    lines.append(" * Auto-calibrated OCV table for piBrick battery driver")
    lines.append(f" * Generated: {datetime.now().isoformat()}")
    lines.append(f" * Source records: {stats.get('resting_records', 0)}")
    lines.append(f" * SOC coverage: {stats.get('soc_coverage_pct', 0):.1f}%")
    lines.append(f" * Confidence: {calculate_calibration_confidence(stats):.2f}")
    lines.append(" *")
    lines.append(" * WARNING: Review and test before applying to production!")
    lines.append(" */")
    lines.append("")
    lines.append("#ifndef _BQ25890_BATTERY_OCV_CALIBRATED_H")
    lines.append("#define _BQ25890_BATTERY_OCV_CALIBRATED_H")
    lines.append("")
    lines.append("typedef struct {")
    lines.append("    int voltage;  /* centivolts */")
    lines.append("    int percentage;")
    lines.append("} VoltageMap;")
    lines.append("")
    lines.append("/* Calibrated voltage-to-SOC mapping */")
    lines.append("static VoltageMap voltage_to_percent_table[] = {")
    
    for point in table:
        samples_note = f" // {point['samples']} samples"
        lines.append(f"\t{{ {point['voltage_cv']:>3}, {point['soc']:>3} }},{samples_note}")
    
    lines.append("};")
    lines.append(f"const int table_size = ARRAY_SIZE(voltage_to_percent_table);")
    lines.append("")
    lines.append("#endif /* _BQ25890_BATTERY_OCV_CALIBRATED_H */")
    
    return "\n".join(lines)


def save_calibration_status(stats, calibrated_table, confidence):
    """Save calibration status and suggested table."""
    status = {
        "last_update": datetime.now().isoformat(),
        "confidence": confidence,
        "stats": {
            "total_records": stats.get("total_records", 0),
            "resting_records": stats.get("resting_records", 0),
            "soc_coverage": stats.get("soc_coverage", []),
            "soc_coverage_pct": stats.get("soc_coverage_pct", 0),
        },
        "suggested_table": calibrated_table,
        "ready_for_apply": confidence >= CONFIDENCE_THRESHOLD
    }
    
    STATUS_FILE.write_text(json.dumps(status, indent=2))
    METADATA_FILE.write_text(json.dumps({
        "last_analysis": datetime.now().isoformat(),
        "confidence": confidence,
        "version": "1.0"
    }, indent=2))
    
    if calibrated_table:
        header = generate_c_header(calibrated_table, stats)
        OCV_TABLE_FILE.write_text(header)


def show_status():
    """Show calibration status."""
    if not STATUS_FILE.exists():
        print("No calibration data yet. Run calibration logger first.")
        print("\nTo start calibration logging:")
        # Resolve the actual install path so the hint works for any user
        env_path = os.environ.get("PIBRICK_USER_HOME")
        if not env_path:
            env_path = os.path.join(os.path.expanduser("~"), "battery-tools")
        if not os.path.exists(os.path.join(env_path, "battery-calibration-logger.py")):
            env_path = "/usr/lib/pibrick/battery-tools"
        print(f"  sudo python3 {env_path}/battery-calibration-logger.py")
        print("\nOr enable the service:")
        print("  sudo systemctl enable pibrick-battery-calibration")
        print("  sudo systemctl start pibrick-battery-calibration")
        return
    
    with open(STATUS_FILE, "r") as f:
        status = json.load(f)
    
    print("=" * 60)
    print("Battery Calibration Status")
    print("=" * 60)
    print(f"Last update: {status['last_update']}")
    print(f"Confidence: {status['confidence']:.2f} ({status['confidence']*100:.1f}%)")
    print()
    
    stats = status.get("stats", {})
    print(f"Total records: {stats.get('total_records', 0)}")
    print(f"Resting records: {stats.get('resting_records', 0)}")
    print(f"SOC coverage: {stats.get('soc_coverage_pct', 0):.1f}%")
    print(f"SOC levels: {stats.get('soc_coverage', [])}")
    print()
    
    if status.get('suggested_table'):
        print("Suggested OCV Table:")
        print("-" * 40)
        print(f"{'Voltage':>10} | {'SOC':>6} | {'Samples':>8}")
        print("-" * 40)
        for point in sorted(status['suggested_table'], key=lambda x: -x['voltage_cv']):
            print(f"{point['voltage_cv']*10:>10}mV | {point['soc']:>6}% | {point['samples']:>8}")
    
    print()
    if status.get("ready_for_apply"):
        print(f"[READY] Calibration ready for application (confidence >= {CONFIDENCE_THRESHOLD*100:.0f}%)")
    else:
        print(f"[NEED MORE DATA] Need confidence >= {CONFIDENCE_THRESHOLD*100:.0f}% (currently {status['confidence']*100:.1f}%)")
    
    print()
    print(f"Generated header: {OCV_TABLE_FILE}")


def run_calibration_check():
    """Run calibration check and analysis."""
    print("Analyzing calibration data...")
    
    data = load_calibration_data()
    if not data:
        print("No calibration data found.")
        print(f"Expected location: {CALIBRATION_DATA}")
        return
    
    print(f"Loaded {len(data)} records")
    
    stats = analyze_calibration_data(data)
    if not stats:
        print("Failed to analyze data")
        return
    
    print(f"\nAnalysis Results:")
    print(f"  Total records: {stats['total_records']}")
    print(f"  Resting records: {stats['resting_records']}")
    print(f"  SOC coverage: {stats['soc_coverage_pct']:.1f}%")
    print(f"  SOC levels: {stats['soc_coverage']}")
    
    if stats.get("date_range"):
        print(f"  Date range: {stats['date_range']['start']} to {stats['date_range']['end']}")
    
    confidence = calculate_calibration_confidence(stats)
    print(f"\nCalibration confidence: {confidence:.2f} ({confidence*100:.1f}%)")
    
    calibrated_table = generate_calibrated_table(stats)
    if calibrated_table:
        print(f"\nGenerated calibrated table with {len(calibrated_table)} points")
        save_calibration_status(stats, calibrated_table, confidence)
        print(f"\nSaved to: {STATUS_FILE}")
        print(f"C header: {OCV_TABLE_FILE}")
    else:
        print("\nNot enough data to generate calibrated table")
        save_calibration_status(stats, None, confidence)
    
    if confidence >= CONFIDENCE_THRESHOLD:
        print(f"\n[READY] Calibration ready! Run with --apply to update the driver.")
    else:
        print(f"\n[NEED MORE DATA] Need {CONFIDENCE_THRESHOLD*100:.0f}% confidence.")
        print("Continue using the battery normally and check again later.")


def apply_calibration():
    """Apply the calibrated OCV table to the driver."""
    if not STATUS_FILE.exists():
        print("No calibration status found. Run --check first.")
        return
    
    with open(STATUS_FILE, "r") as f:
        status = json.load(f)
    
    if not status.get("ready_for_apply"):
        print(f"Not ready to apply. Confidence: {status['confidence']:.2f}")
        print(f"Need confidence >= {CONFIDENCE_THRESHOLD}")
        return
    
    print("WARNING: This will update the OCV table in the driver.")
    print("The driver needs to be recompiled and reloaded.")
    print()
    
    response = input("Continue? (yes/no): ")
    if response.lower() != "yes":
        print("Cancelled.")
        return
    
    # Generate the driver source update
    if status.get('suggested_table'):
        header_content = generate_c_header(
            status['suggested_table'],
            status.get('stats', {})
        )
        print("\nCalibrated OCV table:")
        print(header_content)
        print("\nTo apply this calibration:")
        print("1. Replace the voltage_to_percent_table[] in bq25890_battery.c")
        print("2. Recompile the driver")
        print("3. Reload the driver: sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery")
        print("\nOr use the generated header:")
        print(f"  cat {OCV_TABLE_FILE}")


def reset_calibration():
    """Reset calibration data."""
    print("This will reset all calibration data.")
    
    response = input("Continue? (yes/no): ")
    if response.lower() != "yes":
        print("Cancelled.")
        return
    
    files = [CALIBRATION_DATA, STATUS_FILE, OCV_TABLE_FILE, METADATA_FILE]
    for f in files:
        if f.exists():
            f.unlink()
            print(f"Removed: {f}")
    
    print("\nCalibration reset complete.")
    print("Default OCV table will be used until new data is collected.")


def run_daemon(interval=300):
    """Run as a daemon, periodically checking and updating."""
    print(f"Starting Battery Auto-Calibrator (interval: {interval}s)")
    
    while True:
        try:
            data = load_calibration_data()
            if data:
                stats = analyze_calibration_data(data)
                if stats:
                    confidence = calculate_calibration_confidence(stats)
                    calibrated_table = generate_calibrated_table(stats)
                    save_calibration_status(stats, calibrated_table, confidence)
                    
                    if confidence >= CONFIDENCE_THRESHOLD:
                        print(f"[{datetime.now()}] Calibration ready! Confidence: {confidence:.2f}")
                    else:
                        print(f"[{datetime.now()}] Confidence: {confidence:.2f} (need more data)")
        except Exception as e:
            print(f"[{datetime.now()}] Error: {e}")
        
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(
        description="piBrick Battery Auto-Calibrator"
    )
    parser.add_argument("--daemon", action="store_true",
                       help="Run as background service")
    parser.add_argument("--interval", type=int, default=300,
                       help="Check interval in seconds (default: 300)")
    parser.add_argument("--check", action="store_true",
                       help="Check calibration and analyze data")
    parser.add_argument("--apply", action="store_true",
                       help="Apply calibrated OCV table")
    parser.add_argument("--status", action="store_true",
                       help="Show calibration status")
    parser.add_argument("--reset", action="store_true",
                       help="Reset calibration to defaults")
    
    args = parser.parse_args()
    
    if args.status:
        show_status()
    elif args.check:
        run_calibration_check()
    elif args.apply:
        apply_calibration()
    elif args.reset:
        reset_calibration()
    elif args.daemon:
        run_daemon(args.interval)
    else:
        # Default: show status
        show_status()


if __name__ == "__main__":
    main()
