#!/usr/bin/env python3
"""
piBrick Battery Calibration Logger

Logs battery data continuously to build a voltage-to-SOC calibration table.
This data is used to tune the OCV (Open Circuit Voltage) table for accurate
state-of-charge estimation.

Usage:
    python3 battery-calibration-logger.py [--interval SECONDS] [--output FILE]
    python3 battery-calibration-logger.py --analyze [--input FILE]
    python3 battery-calibration-logger.py --generate-ocv-table [--input FILE]

Logs to /var/log/bq25890_battery/calibration.log by default.
"""

import os
import sys
import time
import argparse
import csv
import json
from datetime import datetime
from pathlib import Path

# Configuration
SYSFS_BASE = "/sys/class/power_supply/battery"
LOG_DIR = Path("/var/log/bq25890_battery")
LOG_FILE = LOG_DIR / "calibration.log"
CSV_FILE = LOG_DIR / "calibration_data.csv"
METRICS_FILE = LOG_DIR / "metrics.json"

# Battery sysfs paths
SYSFS_PATHS = {
    "capacity": f"{SYSFS_BASE}/capacity",
    "voltage_now": f"{SYSFS_BASE}/voltage_now",
    "v_ocv_uv": f"{SYSFS_BASE}/v_ocv_uv",
    "current_now": f"{SYSFS_BASE}/current_now",
    "status": f"{SYSFS_BASE}/status",
    "health": f"{SYSFS_BASE}/health",
    "temp": f"{SYSFS_BASE}/temp",
    "charge_now": f"{SYSFS_BASE}/charge_now",
    "charge_full": f"{SYSFS_BASE}/charge_full",
    "charge_full_design": f"{SYSFS_BASE}/charge_full_design",
    "time_to_full_now": f"{SYSFS_BASE}/time_to_full_now",
    "time_to_empty_avg": f"{SYSFS_BASE}/time_to_empty_avg",
    "ina228_current_ua": f"{SYSFS_BASE}/ina228_current_ua",
    "ina228_bus_uv": f"{SYSFS_BASE}/ina228_bus_uv",
    "ina228_power_mw": f"{SYSFS_BASE}/ina228_power_mw",
    "ina228_dietemp_mdeg_c": f"{SYSFS_BASE}/ina228_dietemp_mdeg_c",
    "fg_mode": f"{SYSFS_BASE}/fg_mode",
}


def read_sysfs(path, default=None):
    """Read a sysfs file, returning default on error."""
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, IOError):
        return default


def read_all_metrics():
    """Read all battery metrics and return as dict."""
    metrics = {}
    for name, path in SYSFS_PATHS.items():
        value = read_sysfs(path)
        if value is not None:
            try:
                metrics[name] = int(value)
            except ValueError:
                metrics[name] = value
    return metrics


def format_metrics(metrics):
    """Format metrics for display."""
    parts = []
    if "capacity" in metrics:
        parts.append(f"SOC:{metrics['capacity']}%")
    if "voltage_now" in metrics:
        parts.append(f"V:{metrics['voltage_now']/1e6:.3f}V")
    if "current_now" in metrics:
        current_ma = metrics["current_now"] / 1e3
        parts.append(f"I:{current_ma:+.0f}mA")
    if "fg_mode" in metrics:
        parts.append(f"Mode:{metrics['fg_mode']}")
    if "status" in metrics:
        parts.append(f"Status:{metrics['status']}")
    return " ".join(parts)


def log_to_csv(metrics, csv_path):
    """Append metrics to CSV file."""
    timestamp = datetime.now().isoformat()
    row = {"timestamp": timestamp}
    row.update(metrics)
    
    file_exists = csv_path.exists()
    with open(csv_path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=row.keys())
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)


def log_to_file(metrics, log_path):
    """Append formatted metrics to log file."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    formatted = format_metrics(metrics)
    with open(log_path, "a") as f:
        f.write(f"[{timestamp}] {formatted}\n")


def run_logger(interval=10, csv_file=None, log_file=None):
    """Run the calibration logger loop."""
    csv_path = Path(csv_file) if csv_file else CSV_FILE
    log_path = Path(log_file) if log_file else LOG_FILE
    
    # Ensure log directory exists
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    
    print(f"Starting Battery Calibration Logger")
    print(f"  Interval: {interval} seconds")
    print(f"  CSV output: {csv_path}")
    print(f"  Log output: {log_path}")
    print(f"  Press Ctrl+C to stop")
    print()
    
    # Log header
    print("Timestamp                | SOC  | Voltage    | Current    | Mode     | Status")
    print("-" * 90)
    
    try:
        while True:
            metrics = read_all_metrics()
            
            # Format for display
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            soc = metrics.get("capacity", "N/A")
            voltage = metrics.get("voltage_now", 0) / 1e6
            current = metrics.get("current_now", 0) / 1e3
            mode = metrics.get("fg_mode", "N/A")
            status = metrics.get("status", "N/A")
            
            print(f"{timestamp} | {soc:>4} | {voltage:>9.3f}V | {current:>+9.0f}mA | {mode:>8} | {status}")
            
            # Log to files
            log_to_csv(metrics, csv_path)
            log_to_file(metrics, log_path)
            
            time.sleep(interval)
            
    except KeyboardInterrupt:
        print("\n\nLogger stopped.")
        print(f"\nData saved to:")
        print(f"  {csv_path}")
        print(f"  {log_path}")


def analyze_data(csv_file=None):
    """Analyze calibration data and show voltage-SOC relationship."""
    csv_path = Path(csv_file) if csv_file else CSV_FILE
    
    if not csv_path.exists():
        print(f"Error: CSV file not found: {csv_path}")
        return
    
    print(f"Analyzing data from: {csv_path}")
    print()
    
    # Read all data
    data = []
    with open(csv_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            data.append(row)
    
    if not data:
        print("No data to analyze.")
        return
    
    print(f"Total records: {len(data)}")
    print()
    
    # Collect resting measurements (most reliable for OCV calibration).
    # We exclude rows whose status string contains "Charging" to be tolerant
    # of kernel-side variants like "Charging (maintenance)".
    resting_data = []
    for row in data:
        status = row.get("status", "")
        if row.get("fg_mode") == "resting" and "Charging" not in status:
            try:
                resting_data.append({
                    "timestamp": row["timestamp"],
                    "soc": int(row.get("capacity", 0)),
                    "voltage_uv": int(row.get("voltage_now", 0)),
                    "v_ocv_uv": int(row.get("v_ocv_uv", 0)),
                    "current_ua": int(row.get("current_now", 0)),
                })
            except ValueError:
                continue
    
    print(f"Resting measurements: {len(resting_data)}")
    
    if resting_data:
        print("\nVoltage vs SOC (Resting state):")
        print("-" * 60)
        print(f"{'SOC%':>6} | {'Voltage':>10} | {'OCV':>10} | {'Current':>10}")
        print("-" * 60)
        
        # Sort by SOC
        resting_data.sort(key=lambda x: x["soc"])
        for row in resting_data:
            v_mv = row["voltage_uv"] / 1e3
            ocv_mv = row["v_ocv_uv"] / 1e3
            current_ma = row["current_ua"] / 1e3
            print(f"{row['soc']:>6} | {v_mv:>10.0f}mV | {ocv_mv:>10.0f}mV | {current_ma:>+10.0f}mA")
    
    # Group by SOC and calculate average voltage
    soc_groups = {}
    for row in data:
        try:
            soc = int(row.get("capacity", 0))
            voltage_uv = int(row.get("voltage_now", 0))
            v_ocv_uv = int(row.get("v_ocv_uv", 0))
            
            if soc not in soc_groups:
                soc_groups[soc] = {"voltages": [], "ocvs": []}
            if voltage_uv > 0:
                soc_groups[soc]["voltages"].append(voltage_uv)
            if v_ocv_uv > 0:
                soc_groups[soc]["ocvs"].append(v_ocv_uv)
        except ValueError:
            continue
    
    print("\n\nAggregated Voltage-SOC Table:")
    print("-" * 50)
    print(f"{'SOC%':>6} | {'Avg Voltage':>12} | {'Avg OCV':>12} | {'Count':>6}")
    print("-" * 50)
    
    for soc in sorted(soc_groups.keys()):
        group = soc_groups[soc]
        avg_v = sum(group["voltages"]) / len(group["voltages"]) if group["voltages"] else 0
        avg_ocv = sum(group["ocvs"]) / len(group["ocvs"]) if group["ocvs"] else 0
        count = max(len(group["voltages"]), len(group["ocvs"]))
        print(f"{soc:>6} | {avg_v/1e6:>12.4f}V | {avg_ocv/1e6:>12.4f}V | {count:>6}")


def generate_ocv_table(csv_file=None, output_file=None):
    """Generate OCV calibration table from data."""
    csv_path = Path(csv_file) if csv_file else CSV_FILE
    out_path = Path(output_file) if output_file else None
    
    if not csv_path.exists():
        print(f"Error: CSV file not found: {csv_path}")
        return
    
    print(f"Generating OCV table from: {csv_path}")
    
    # Read and filter resting data
    resting_data = []
    with open(csv_path, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("fg_mode") == "resting":
                try:
                    resting_data.append({
                        "soc": int(row.get("capacity", 0)),
                        "voltage_uv": int(row.get("voltage_now", 0)),
                        "v_ocv_uv": int(row.get("v_ocv_uv", 0)),
                    })
                except ValueError:
                    continue
    
    if len(resting_data) < 5:
        print(f"Warning: Only {len(resting_data)} resting measurements. Need more for accurate calibration.")
        print("Collect data during discharge cycles with resting periods.")
        return
    
    # Group by SOC
    soc_data = {}
    for row in resting_data:
        soc = row["soc"]
        if soc not in soc_data:
            soc_data[soc] = []
        soc_data[soc].append(row["v_ocv_uv"] if row["v_ocv_uv"] > 0 else row["voltage_uv"])
    
    # Calculate averages
    table_points = []
    for soc in sorted(soc_data.keys()):
        avg_v = sum(soc_data[soc]) / len(soc_data[soc])
        voltage_cv = int(round(avg_v / 1e4))  # Convert to centivolts
        table_points.append({"soc": soc, "voltage_cv": voltage_cv, "samples": len(soc_data[soc])})

    # IMPORTANT: sort the output table by voltage DESCENDING.
    # The driver's bq25890_calc_lipo_percentage() walks voltage_to_percent_table
    # and finds the largest voltage <= measured voltage, so the table must be
    # sorted with the highest voltage first (e.g. 100% / 4.18V at index 0, 0%
    # / 2.98V at the last index).
    table_points.sort(key=lambda x: x["voltage_cv"], reverse=True)
    
    # Generate C code for the driver
    output = []
    output.append("/*")
    output.append(" * Auto-generated OCV calibration table")
    output.append(f" * Generated: {datetime.now().isoformat()}")
    output.append(f" * Source: {csv_path}")
    output.append(f" * Data points: {len(table_points)}")
    output.append(" */")
    output.append("")
    output.append("static VoltageMap voltage_to_percent_table[] = {")
    
    for point in table_points:
        output.append(f"\t{{ {point['voltage_cv']:>3}, {point['soc']:>3} }},  // {point['samples']} samples")
    
    output.append("};")
    output.append(f"const int table_size = ARRAY_SIZE(voltage_to_percent_table);")
    
    code = "\n".join(output)
    
    if out_path:
        out_path.write_text(code)
        print(f"OCV table written to: {out_path}")
    else:
        print("\n" + code + "\n")
    
    # Also print as JSON for reference
    json_output = []
    for point in table_points:
        json_output.append({
            "voltage_cv": point["voltage_cv"],
            "soc_percent": point["soc"],
            "voltage_mv": point["voltage_cv"] * 10,
            "samples": point["samples"]
        })
    
    print("\nJSON format (for reference):")
    print(json.dumps(json_output, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description="piBrick Battery Calibration Logger",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Start logging (default 10-second interval)
    sudo python3 battery-calibration-logger.py
    
    # Log every 5 seconds
    sudo python3 battery-calibration-logger.py --interval 5
    
    # Analyze existing data
    sudo python3 battery-calibration-logger.py --analyze
    
    # Generate OCV table from data
    sudo python3 battery-calibration-logger.py --generate-ocv-table

Tips for accurate calibration:
  1. Run through several complete charge/discharge cycles
  2. Let the battery rest for at least 5 minutes at various SOC levels
  3. The resting mode (Mode:resting) provides the most accurate OCV readings
  4. More data points = better calibration
        """
    )
    parser.add_argument("--interval", type=int, default=10,
                       help="Sampling interval in seconds (default: 10)")
    parser.add_argument("--output", type=str,
                       help="Output CSV file path")
    parser.add_argument("--log", type=str,
                       help="Output log file path")
    parser.add_argument("--analyze", action="store_true",
                       help="Analyze existing calibration data")
    parser.add_argument("--generate-ocv-table", action="store_true",
                       help="Generate OCV table from calibration data")
    parser.add_argument("--input", type=str,
                       help="Input CSV file for analyze/generate-ocv-table")
    
    args = parser.parse_args()
    
    if args.analyze:
        analyze_data(args.input)
    elif args.generate_ocv_table:
        generate_ocv_table(args.input)
    else:
        if os.geteuid() != 0:
            print("Error: This script must be run as root.")
            print("Usage: sudo python3 battery-calibration-logger.py")
            sys.exit(1)
        run_logger(interval=args.interval, csv_file=args.output, log_file=args.log)


if __name__ == "__main__":
    main()
