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

Without INA228 (proxy integrator, noisier current sensing):
    python3 battery-auto-calibrator.py --check --no-ina228
    python3 battery-auto-calibrator.py --apply --no-ina228 --yes

The --no-ina228 flag tightens the sample filter to |current_now| <= 10 mA,
restricts fg_mode to 'resting', and lowers the minimum samples per bucket
and confidence threshold so a calibration can complete after 2-3 charge
cycles instead of requiring 1 full cycle of mixed activity. The driver
also bumps BQ25890_FG_V_OCV_TAU_SEC when no INA228 is detected, which
makes the OCV tracker smoother at the cost of slower convergence.
"""

import os
import sys
import csv
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

# Minimum samples per SOC bucket for reliable calibration.
# In --no-ina228 mode this is lowered to 2 because the proxy integrator
# produces noisier v_ocv_uv readings; we compensate by collecting more
# total samples (see MIN_TOTAL_SAMPLES).
MIN_SAMPLES_PER_BUCKET = 3
# Minimum total samples for calibration. In --no-ina228 mode this is
# raised because each cycle yields fewer clean resting samples.
MIN_TOTAL_SAMPLES = 15
# Confidence threshold for auto-apply. Lowered in --no-ina228 mode
# because coverage scores will plateau (one cycle can't sample every
# SOC bucket) and we still want auto-apply to fire after 2-3 cycles.
CONFIDENCE_THRESHOLD = 0.85
# In --no-ina228 mode, filter more aggressively on current_now: keep
# only samples where |current_now| <= 10 mA. The BQ25895 proxy current
# has higher noise at low currents, so we want samples that are
# demonstrably at true resting state. INA228 measurements don't need
# this filter — its 20-bit ADC resolves down to 1.5 uA already.
NO_INA228_MAX_REST_CURRENT_UA = 10_000
# In --no-ina228 mode, also accept a stricter set of fg_mode values.
# The proxy integrator can report "active" spuriously during short
# spikes; with INA228 we can trust the live current. Without it we
# insist on at least the driver calling us "resting".
NO_INA228_ACCEPTED_FG_MODES = ("resting",)
# In --no-ina228 mode, the BQ25890_FG_V_OCV_TAU_SEC is doubled by the
# kernel to give a slower, smoother OCV tracker. We mirror that
# behaviour here by raising the per-bucket std-dev tolerance for
# admission: a 60s vs 120s tracker gives 1.4x the smoothing so the
# natural std-dev of bucket members is also 1.4x larger.
NO_INA228_BUCKET_STDDEV_UV = 30_000  # 30 mV vs ~20 mV with INA228


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


def analyze_calibration_data(data, no_ina228=False):
    """Analyze calibration data and return statistics.

    When no_ina228=True:
      - Lower MIN_SAMPLES_PER_BUCKET to 2 (the proxy integrator is noisier)
      - Raise MIN_TOTAL_SAMPLES to compensate (need more cycles)
      - Filter samples by |current_now| <= 10 mA (true resting state only)
      - Restrict to fg_mode == 'resting' (reject proxy spurious 'active')
      - Loosen bucket std-dev tolerance to mirror the slower OCV tracker
    """
    if not data:
        return None

    min_samples = 2 if no_ina228 else MIN_SAMPLES_PER_BUCKET
    min_total = 30 if no_ina228 else MIN_TOTAL_SAMPLES
    max_rest_ua = NO_INA228_MAX_REST_CURRENT_UA if no_ina228 else None
    accept_fg_modes = NO_INA228_ACCEPTED_FG_MODES if no_ina228 else None

    stats = {
        "total_records": len(data),
        "resting_records": 0,
        "filtered_records": 0,
        "no_ina228": no_ina228,
        "soc_coverage": set(),
        "soc_buckets": defaultdict(list),
        "date_range": {"start": None, "end": None},
    }

    timestamps = []

    for row in data:
        try:
            # Skip rows with missing essential data (corrupted/incomplete rows)
            capacity_val = row.get("capacity")
            if capacity_val is None or capacity_val == "":
                continue

            fg_mode = row.get("fg_mode", "")
            status = row.get("status", "")
            soc = int(capacity_val)
            voltage_uv = int(row.get("voltage_now", 0))
            v_ocv_uv = int(row.get("v_ocv_uv", 0))
            current_ua_str = row.get("current_now", "0") or "0"
            try:
                current_ua = int(current_ua_str)
            except (ValueError, TypeError):
                current_ua = 0
            timestamp = row.get("timestamp", "")

            if timestamp:
                timestamps.append(timestamp)

            # Base filter: resting + not charging
            is_resting = (fg_mode == "resting") and ("Charging" not in status)
            if not is_resting:
                continue

            # Stricter filter for no-INA228 mode
            if no_ina228:
                if accept_fg_modes and fg_mode not in accept_fg_modes:
                    continue
                if max_rest_ua is not None and abs(current_ua) > max_rest_ua:
                    continue
            stats["resting_records"] += 1
            stats["soc_coverage"].add(soc)

            # Use OCV if available, otherwise use voltage
            voltage = v_ocv_uv if int(v_ocv_uv) > 0 else voltage_uv
            if voltage > 0:
                stats["soc_buckets"][soc].append((voltage, current_ua))

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
    for soc, samples in stats["soc_buckets"].items():
        voltages = [v for v, _ in samples]
        if len(voltages) >= min_samples:
            avg_v = sum(voltages) / len(voltages)
            std_dev = calculate_std_dev(voltages)
            # In --no-ina228 mode, reject buckets with too-wide a spread;
            # the slower OCV tracker smooths but cannot magic away a
            # misclassified sample.
            if no_ina228 and std_dev > NO_INA228_BUCKET_STDDEV_UV:
                continue
            stats["bucket_averages"][soc] = {
                "voltage_cv": int(round(avg_v / 1e4)),
                "voltage_mv": int(round(avg_v / 1e3)),
                "samples": len(voltages),
                "std_dev": std_dev,
            }

    # Save min_samples so the CLI can report it
    stats["_min_samples_per_bucket"] = min_samples
    stats["_min_total_samples"] = min_total

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
    
    # Sort by voltage ASCENDING. The driver's bq25890_calc_lipo_percentage()
    # walks voltage_to_percent_table and assumes v[0] is the LOWEST voltage
    # (= 0%) and v[size-1] is the HIGHEST (= 100%). A descending table
    # makes the first guard `voltage <= v[0]` match for almost every
    # voltage and force SOC=0% forever. See the comment block above
    # voltage_to_percent_table in bq25890_battery.c for the full
    # rationale.
    points.sort(key=lambda x: x[0])
    
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


def save_calibration_status(stats, calibrated_table, confidence, confidence_threshold=None):
    """Save calibration status and suggested table.

    The status JSON is always overwritten (it's cheap and reflects "the
    latest analysis"). The suggested_ocv_table.h, however, is the actual
    artifact we'd feed into --apply, so we only overwrite it when the new
    analysis clears the confidence threshold — otherwise a fresh, low-
    confidence run would clobber a previously-good table. The apply
    path is gated on `ready_for_apply` regardless, so this is belt-and-
    suspenders, but it keeps the .h file trustworthy as a "best known
    calibration" even when run mid-cycle.
    """
    if confidence_threshold is None:
        confidence_threshold = CONFIDENCE_THRESHOLD
    status = {
        "last_update": datetime.now().isoformat(),
        "confidence": confidence,
        "confidence_threshold": confidence_threshold,
        "no_ina228": stats.get("no_ina228", False),
        "stats": {
            "total_records": stats.get("total_records", 0),
            "resting_records": stats.get("resting_records", 0),
            "soc_coverage": stats.get("soc_coverage", []),
            "soc_coverage_pct": stats.get("soc_coverage_pct", 0),
        },
        "suggested_table": calibrated_table,
        "ready_for_apply": confidence >= confidence_threshold
    }

    STATUS_FILE.write_text(json.dumps(status, indent=2))
    METADATA_FILE.write_text(json.dumps({
        "last_analysis": datetime.now().isoformat(),
        "confidence": confidence,
        "confidence_threshold": confidence_threshold,
        "no_ina228": stats.get("no_ina228", False),
        "version": "1.1"
    }, indent=2))

    # Only overwrite the .h file if the new analysis meets the threshold.
    # See docstring above for the rationale.
    if calibrated_table and confidence >= confidence_threshold:
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
    threshold = status.get("confidence_threshold", CONFIDENCE_THRESHOLD)
    no_ina228 = status.get("no_ina228", False)
    print(f"Mode: {'no-INA228' if no_ina228 else 'INA228'}")
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
        print(f"[READY] Calibration ready for application (confidence >= {threshold*100:.0f}%)")
    else:
        print(f"[NEED MORE DATA] Need confidence >= {threshold*100:.0f}% (currently {status['confidence']*100:.1f}%)")
        if no_ina228:
            print("(no-INA228 mode: typically needs 2-3 charge cycles)")

    print()
    print(f"Generated header: {OCV_TABLE_FILE}")


def run_calibration_check(no_ina228=False):
    """Run calibration check and analysis.

    no_ina228=True lowers MIN_SAMPLES_PER_BUCKET and CONFIDENCE_THRESHOLD
    and applies stricter sample filtering (|current_now| <= 10 mA,
    fg_mode must be 'resting'). See analyze_calibration_data() for details.
    """
    print("Analyzing calibration data...")

    data = load_calibration_data()
    if not data:
        print("No calibration data found.")
        print(f"Expected location: {CALIBRATION_DATA}")
        return

    print(f"Loaded {len(data)} records")

    stats = analyze_calibration_data(data, no_ina228=no_ina228)
    if not stats:
        print("Failed to analyze data")
        return

    confidence_threshold = 0.70 if no_ina228 else CONFIDENCE_THRESHOLD

    print(f"\nAnalysis Results (mode: {'no-INA228' if no_ina228 else 'INA228'}):")
    print(f"  Total records: {stats['total_records']}")
    print(f"  Resting records: {stats['resting_records']}")
    print(f"  SOC coverage: {stats['soc_coverage_pct']:.1f}%")
    print(f"  SOC levels: {stats['soc_coverage']}")
    print(f"  Min samples per bucket: {stats['_min_samples_per_bucket']}")
    print(f"  Min total samples: {stats['_min_total_samples']}")

    if stats.get("date_range"):
        print(f"  Date range: {stats['date_range']['start']} to {stats['date_range']['end']}")

    confidence = calculate_calibration_confidence(stats)
    print(f"\nCalibration confidence: {confidence:.2f} ({confidence*100:.1f}%)")

    calibrated_table = generate_calibrated_table(stats)
    if calibrated_table:
        print(f"\nGenerated calibrated table with {len(calibrated_table)} points")
        save_calibration_status(stats, calibrated_table, confidence,
                                confidence_threshold=confidence_threshold)
        print(f"\nSaved to: {STATUS_FILE}")
        print(f"C header: {OCV_TABLE_FILE}")
    else:
        print("\nNot enough data to generate calibrated table")
        save_calibration_status(stats, None, confidence,
                                confidence_threshold=confidence_threshold)

    if confidence >= confidence_threshold:
        print(f"\n[READY] Calibration ready! Run with --apply to update the driver.")
    else:
        print(f"\n[NEED MORE DATA] Need {confidence_threshold*100:.0f}% confidence.")
        if no_ina228:
            print("Without INA228 you typically need 2-3 full charge cycles")
            print("to gather enough clean samples; continue using the device")
            print("and check again later.")
        else:
            print("Continue using the battery normally and check again later.")


def apply_calibration(rebuild=True, yes=False):
    """Apply the calibrated OCV table to the driver source.

    Steps performed:
      1. Locate bq25890_battery.c and the calibration status JSON.
      2. Invoke tools/update-ocv-table.py to patch the table in place.
      3. Optionally rebuild and reload the kernel module.

    The whole workflow is idempotent — running it on an up-to-date driver
    is a no-op. Pass yes=True (or answer the confirmation prompt) to skip
    the interactive gate.
    """
    if not STATUS_FILE.exists():
        print("No calibration status found. Run --check first.")
        return False

    with open(STATUS_FILE, "r") as f:
        status = json.load(f)

    if not status.get("ready_for_apply"):
        threshold = status.get("confidence_threshold", CONFIDENCE_THRESHOLD)
        print(f"Not ready to apply. Confidence: {status['confidence']:.2f}")
        print(f"Need confidence >= {threshold}")
        return False

    print("WARNING: This will update the OCV table in the driver.")
    print("The driver needs to be recompiled and reloaded.")
    print()

    if not yes:
        response = input("Continue? (yes/no): ")
        # Accept "y", "Y", "yes", "Yes", "YES"; anything else = cancel.
        if response.lower() not in ("yes", "y"):
            print("Cancelled.")
            return False

    # Resolve the repo root from this script's location so the call works
    # whether the script was installed under /usr/lib/pibrick/battery-tools
    # or /home/<user>/battery-tools or run from the source tree.
    script_dir = Path(__file__).resolve().parent
    # First try the install location for `update-ocv-table.py` (it ships
    # next to this script).
    update_tool = script_dir / "update-ocv-table.py"
    if not update_tool.exists():
        # Fall back: scan common layouts for the source tree (which has
        # both the tool and the driver source).
        repo_root_candidates = [
            script_dir.parent,                 # ../.. (when installed in battery-tools)
            script_dir,                         # tools/ lives here for in-tree runs
            Path("/usr/lib/pibrick"),           # system-wide fallback
        ]
        repo_root = None
        for cand in repo_root_candidates:
            if (cand / "tools" / "update-ocv-table.py").exists() and \
               (cand / "battery" / "bq25890_battery.c").exists():
                repo_root = cand
                break
        if repo_root is not None:
            update_tool = repo_root / "tools" / "update-ocv-table.py"
    if not update_tool.exists():
        sys.exit(f"Cannot find update-ocv-table.py (searched next to {script_dir} and /usr/lib/pibrick)")

    cmd = [sys.executable, str(update_tool),
           "--status", str(STATUS_FILE)]
    # If we also found a driver source tree, pass --driver so the source
    # gets patched in place. Without it, the tool just prints the new
    # table (--no-rebuild mode).
    driver_source = None
    search_dirs = [
        script_dir.parent,                  # ../.. (when installed in battery-tools)
        Path("/usr/lib/pibrick"),            # system-wide install root
        script_dir,                          # same dir as script (e.g. tools/)
    ]
    # Allow override via env var so a non-default install layout works.
    user_home = os.environ.get("PIBRICK_USER_HOME")
    if user_home:
        search_dirs.append(Path(user_home))
    # When invoked via `sudo`, HOME is /root, but SUDO_USER points at the
    # original user (often the developer who cloned the repo).
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        search_dirs.append(Path(f"/home/{sudo_user}") / "pibrick-driver-2nd-batch")
        search_dirs.append(Path(f"/home/{sudo_user}") / "battery-tools")
    if os.environ.get("HOME"):
        search_dirs.append(Path(os.environ["HOME"]) / "pibrick-driver-2nd-batch")
        search_dirs.append(Path(os.environ["HOME"]) / "battery-tools")

    for cand in search_dirs:
        candidate = cand / "battery" / "bq25890_battery.c"
        if candidate.exists():
            driver_source = candidate
            break
    if driver_source is not None:
        cmd += ["--driver", str(driver_source)]
    print("Running:", " ".join(cmd))
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        print(f"update-ocv-table.py failed with exit code {rc}")
        return False
    repo_root = driver_source.parent.parent if driver_source else None

    if not rebuild:
        print("\nDriver source patched. Skipping rebuild (--no-rebuild).")
        print("Reload manually: sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery")
        return True

    # Rebuild + reload. The Makefile lives at battery/Makefile and exposes
    # the standard `make` invocation we already use in install.sh. If we
    # couldn't find the repo root (running from a system-wide install with
    # no source tree), the rebuild step is skipped and the user is told
    # what to run manually.
    if repo_root is None:
        print("\nRepo source not available at expected path; skipping rebuild.")
        print("Reload manually: sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery")
        return True

    makefile = repo_root / "battery" / "Makefile"
    if not makefile.exists():
        print(f"Makefile not found at {makefile}; skipping rebuild.")
        return True

    print("\nRebuilding driver...")
    rc = subprocess.call(["make", "-C", str(repo_root / "battery")])
    if rc != 0:
        print(f"make failed with exit code {rc}")
        return False

    print("\nReloading driver...")
    rc = subprocess.call(["modprobe", "-r", "bq25890_battery"])
    if rc != 0:
        # INA228 stays loaded if the bq25890 module unload failed for any
        # reason (e.g., busy). Tell the user explicitly rather than silent.
        print("Warning: failed to unload bq25890_battery (in use?). Skipping reload.")
        return False
    rc = subprocess.call(["modprobe", "bq25890_battery"])
    if rc != 0:
        print("Warning: failed to load bq25890_battery. Check `dmesg | tail`.")
        return False

    print("\n[OK] Calibration applied and driver reloaded.")
    return True


def reset_calibration():
    """Reset calibration data."""
    print("This will reset all calibration data.")
    
    response = input("Continue? (yes/no): ")
    if response.lower() not in ("yes", "y"):
        print("Cancelled.")
        return
    
    files = [CALIBRATION_DATA, STATUS_FILE, OCV_TABLE_FILE, METADATA_FILE]
    for f in files:
        if f.exists():
            f.unlink()
            print(f"Removed: {f}")
    
    print("\nCalibration reset complete.")
    print("Default OCV table will be used until new data is collected.")


def run_daemon(interval=300, no_ina228=False):
    """Run as a daemon, periodically checking and updating."""
    print(f"Starting Battery Auto-Calibrator "
          f"(interval: {interval}s, mode: {'no-INA228' if no_ina228 else 'INA228'})")

    while True:
        try:
            data = load_calibration_data()
            if data:
                stats = analyze_calibration_data(data, no_ina228=no_ina228)
                if stats:
                    confidence = calculate_calibration_confidence(stats)
                    calibrated_table = generate_calibrated_table(stats)
                    save_calibration_status(stats, calibrated_table, confidence,
                                            confidence_threshold=(0.70 if no_ina228 else CONFIDENCE_THRESHOLD))

                    threshold = 0.70 if no_ina228 else CONFIDENCE_THRESHOLD
                    if confidence >= threshold:
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
    parser.add_argument("--yes", "-y", action="store_true",
                       help="Skip the confirmation prompt for --apply")
    parser.add_argument("--no-rebuild", action="store_true",
                       help="With --apply, only patch the source; skip make + modprobe")
    parser.add_argument("--status", action="store_true",
                       help="Show calibration status")
    parser.add_argument("--reset", action="store_true",
                       help="Reset calibration to defaults")

    parser.add_argument("--no-ina228", action="store_true",
                       help="Tune thresholds for hardware without INA228. Lowers "
                            "MIN_SAMPLES_PER_BUCKET (3->2) and CONFIDENCE_THRESHOLD "
                            "(0.85->0.70), filters samples to |current_now|<=10mA, "
                            "and rejects fg_mode != 'resting'. Expect to need 2-3 "
                            "full charge cycles instead of 1.")
    args = parser.parse_args()

    if args.status:
        show_status()
    elif args.check:
        run_calibration_check(no_ina228=args.no_ina228)
    elif args.apply:
        apply_calibration(rebuild=not args.no_rebuild, yes=args.yes)
    elif args.reset:
        reset_calibration()
    elif args.daemon:
        run_daemon(args.interval, no_ina228=args.no_ina228)
    else:
        # Default: show status
        show_status()


if __name__ == "__main__":
    main()
