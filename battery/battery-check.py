#!/usr/bin/env python3
"""
piBrick battery diagnostic check with explanations.

This tool reads all relevant fuel-gauge sysfs entries, cross-checks INA228 raw
readings against the coulomb counter, runs the LiPo OCV table, and reports
any anomalies with clear explanations.

USAGE:
    python3 battery-check.py              # Run diagnostic check
    python3 battery-check.py --explain    # Show detailed explanations for each value
    python3 battery-check.py --help       # Show this help

WHAT EACH SECTION MEANS:

    Battery Status      - Basic battery state (charging, capacity, etc.)
    Voltage             - Cell voltage readings and what they tell us
    Current / Power     - Current flow direction and magnitude
    SOC Comparison      - State-of-Charge estimates from different methods
    Diagnostic Checks   - Automated health checks with pass/fail results
    UPower / KDE State - How the desktop environment sees the battery
"""

import os
import sys
import argparse

# ── Explanation Registry ─────────────────────────────────────────────────────

EXPLANATIONS = {
    "capacity": """
        SOC percentage from fuel gauge (0-100%).
        Based on coulomb counting with voltage compensation.
        This is what the system reports to applications.
    """,
    "status": """
        Current charging state:
        - Charging:    Battery is being charged (current flowing in)
        - Discharging:  Battery is powering the device (current flowing out)
        - Full:         Battery is fully charged, charger may be maintaining
        - Not charging: Charger connected but not actively charging
    """,
    "fg_mode": """
        Fuel gauge operating mode:
        - coulomb:     Using coulomb counter (INA228) for accurate tracking
        - voltage:     Using voltage-only estimation (fallback mode)
        - resting:     Taking OCV measurement after current stopped
    """,
    "coulomb_uah": """
        Accumulated charge from the INA228 coulomb counter (µAh).
        This is the PRIMARY measurement - counts electrons flowing in/out.
        Updated continuously; represents true charge state.
    """,
    "voltage_now": """
        Current cell voltage measured at the battery terminals.
        This fluctuates with load current (IR drop across internal resistance).
        During high current: voltage drops below OCV.
        During rest: voltage recovers toward OCV.
    """,
    "v_term_uv": """
        Terminal voltage (µV) - voltage when last full measurement was taken.
        This is the reference voltage for the OCV table lookup.
        During CC (Constant Current) charging: v_term > v_now due to IR drop.
    """,
    "v_ocv_uv": """
        Open Circuit Voltage (µV) - estimated voltage at zero current.
        Calculated by adding estimated IR drop back to terminal voltage.
        Used for OCV-to-SOC lookup, which works even without rest period.
        OCV = v_term + (current * internal_R)
    """,
    "dV (v_term - v_ocv)": """
        The IR drop across the battery's internal resistance.
        During charging: positive (charging voltage raised terminal above OCV)
        During discharging: negative (discharge voltage lowered terminal below OCV)
        Large values indicate high current or high internal resistance.
    """,
    "dV (v_now - v_term)": """
        Voltage difference from last terminal voltage measurement.
        Indicates recent load changes.
        Negative during high current discharge.
        Positive during recovery after load removal.
    """,
    "current_now": """
        Instantaneous current from the charger IC (µA).
        NEGATIVE = charging (current INTO battery)
        POSITIVE = discharging (current OUT of battery)
        Note: This uses power_supply convention, opposite of electronics sign.
    """,
    "ina228_current_ua": """
        Current measured directly by the INA228 fuel gauge (µA).
        More accurate than charger IC current sensing.
        Also uses sign convention: negative = charging.
    """,
    "ina228_power_mw": """
        Power calculated by INA228 from current × voltage (mW).
        Negative during charging (power into battery).
        Positive during discharging (power out of battery).
    """,
    "implied_Rshunt": """
        Shunt resistor value implied by INA228 measurements (µΩ).
        Calculated as: |shunt_voltage| / |current| × 10^6
        Should be close to the configured value (typically 15,000 µΩ = 15 mΩ).
        Drift indicates measurement error or noise.
    """,
    "ichg_set": """
        Constant charge current setting for the charger IC (A).
        This is what the charger is configured to deliver.
        Limited by ichg_max (maximum allowed current).
    """,
    "ichg_max": """
        Maximum constant charge current allowed (A).
        Set by system to prevent overcharging based on battery temp, etc.
    """,
    "iin_lim": """
        Input current limit from USB/charger (A).
        Limits total power drawn from the charging source.
        Ensures charger adapter isn't overloaded.
    """,
    "time_to_full": """
        Estimated seconds until full charge at current rate.
        Calculated from charge current and remaining capacity.
        Inaccurate at start of charge or with changing conditions.
    """,
    "OCV at v_xxx": """
        State-of-Charge estimated from Open Circuit Voltage using LiPo OCV table.
        The table maps voltage to expected SOC based on battery discharge curve.
        Works best when battery has rested (low current).
        Δ (delta) shows difference from coulomb counter reading.
    """,
}

def explain_value(key):
    """Print explanation for a given metric key."""
    key_lower = key.lower().strip()
    for k, v in EXPLANATIONS.items():
        if k.lower() in key_lower or key_lower in k.lower():
            for line in v.strip().split('\n'):
                print(f"      {line}")
            print()
            return
    print("      (No detailed explanation available)")
    print()


# ── helpers ──────────────────────────────────────────────────────────────────

def r(path):
    try:
        return int(open(path).read().strip())
    except Exception:
        return None

def rt(path):
    try:
        return open(path).read().strip()
    except Exception:
        return None

def rf(path):
    """Read float value."""
    try:
        return float(open(path).read().strip())
    except Exception:
        return None


# ── paths ─────────────────────────────────────────────────────────────────────

BASE = "/sys/class/power_supply/battery"

FIELDS = {
    "capacity":              f"{BASE}/capacity",
    "status":               f"{BASE}/status",
    "voltage_now":          f"{BASE}/voltage_now",
    "v_term_uv":            f"{BASE}/v_term_uv",
    "v_ocv_uv":             f"{BASE}/v_ocv_uv",
    "ocv_soc_pct":          f"{BASE}/ocv_soc_pct",
    "current_now":          f"{BASE}/current_now",
    "ina228_current_ua":    f"{BASE}/ina228_current_ua",
    "ina228_power_mw":      f"{BASE}/ina228_power_mw",
    "ina228_bus_uv":        f"{BASE}/ina228_bus_uv",
    "ina228_shunt_uv":      f"{BASE}/ina228_shunt_uv",
    "charge_now":           f"{BASE}/charge_now",
    "coulomb_uah":          f"{BASE}/coulomb_uah",
    "charge_full":          f"{BASE}/charge_full",
    "fg_mode":              f"{BASE}/fg_mode",
    "capacity_level":       f"{BASE}/capacity_level",
    "charge_type":          f"{BASE}/charge_type",
    "time_to_full_now":     f"{BASE}/time_to_full_now",
    "ichg_max":             f"{BASE}/constant_charge_current_max",
    "ichg":                 f"{BASE}/constant_charge_current",
    "iin_lim":              f"{BASE}/input_current_limit",
    "power_now":            f"{BASE}/power_now",
}

def read_all():
    return {k: (r(v), rt(v)) for k, v in FIELDS.items()}


# Fallback OCV lookup for older drivers without ocv_soc_pct. Prefer the
# driver's table via /sys/class/power_supply/battery/ocv_soc_pct.

OCV_TABLE = [
    (298, 0),  (328, 5),  (348, 10), (358, 20), (363, 30), (366, 40),
    (369, 50), (371, 55), (374, 60), (377, 70), (380, 80), (385, 90),
    (393, 95), (418, 100),
]

def ocv_pct(v_uv):
    """Estimate SOC % from OCV voltage (v_uv in µV)."""
    v_tenths = v_uv // 10_000
    for i in range(len(OCV_TABLE) - 1):
        lo_v, lo_p = OCV_TABLE[i]
        hi_v, hi_p = OCV_TABLE[i + 1]
        if lo_v <= v_tenths < hi_v:
            frac = (v_tenths - lo_v) / (hi_v - lo_v)
            return lo_p + frac * (hi_p - lo_p)
    if v_tenths >= 418:
        return 100.0
    return 0.0


# ── diagnostic checks ─────────────────────────────────────────────────────────

CHECKS = []

def check(cond, msg_ok, msg_fail, explanation=None):
    """Register a check; prints PASS/FAIL with optional explanation."""
    if cond:
        CHECKS.append(f"[PASS] {msg_ok}")
        result = "PASS"
    else:
        CHECKS.append(f"[FAIL] {msg_fail}")
        result = "FAIL"

    if explanation:
        CHECKS.append(f"      ℹ {explanation}")


# ── formatting helpers ────────────────────────────────────────────────────────

def section(title, subtitle=None):
    print(f"\n{'='*65}")
    print(f" {title}")
    if subtitle:
        print(f"   {subtitle}")
    print(f"{'='*65}")


def kv(key, val, unit="", explain=False):
    print(f"  {key:<22} = {val} {unit}".rstrip())
    if explain:
        explain_value(key)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    # Parse arguments
    parser = argparse.ArgumentParser(
        description="piBrick battery diagnostic check with explanations",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
EXAMPLES:
    python3 battery-check.py           Run the diagnostic check
    python3 battery-check.py --explain Show detailed explanations for each value
        """
    )
    parser.add_argument("--explain", action="store_true",
                       help="Show detailed explanations for each value")
    parser.add_argument("--verbose", "-v", action="store_true",
                       help="Show extended diagnostic information")

    args = parser.parse_args()
    explain = args.explain
    verbose = args.verbose or explain

    d = read_all()

    # ── basic status ──────────────────────────────────────────────────────

    section("Battery Status",
            "Current charging state and capacity")

    status    = d["status"][1]
    cap       = d["capacity"][0]
    cap_lev   = d["capacity_level"][1]
    fg_mode   = d["fg_mode"][1]
    chg_type  = d["charge_type"][1]
    coulomb   = d["coulomb_uah"][0]
    full      = d["charge_full"][0]
    cap_now   = d["charge_now"][0]

    kv("status",         status, explain=explain)
    kv("fg_mode",        fg_mode, explain=explain)
    kv("capacity",        f"{cap}%" if cap is not None else "N/A", explain=explain)
    kv("capacity_level",  cap_lev, explain=explain)
    kv("charge_type",    chg_type, explain=explain)

    print()
    kv("coulomb_uah",    f"{coulomb/1e6:.3f} mAh" if coulomb is not None else "N/A", explain=explain)
    kv("charge_now",      f"{cap_now/1e6:.3f} mAh" if cap_now is not None else "N/A", explain=explain)
    kv("charge_full",     f"{full/1e6:.3f} mAh"  if full  is not None else "N/A", explain=explain)
    if coulomb is not None and full is not None and full > 0:
        kv("coulomb_pct",  f"{coulomb*100/full:.1f}%")

    if explain:
        print()
        print("      These three capacity values should be similar:")
        print("        - coulomb_uah: Direct measurement from INA228 counter")
        print("        - charge_now:  Driver's estimate (may use voltage compensation)")
        print("        - charge_full: Design capacity (set via battery_set.py)")

    # ── voltage ───────────────────────────────────────────────────────────

    section("Voltage",
            "Cell voltage measurements and what they reveal")

    v_now   = d["voltage_now"][0]
    v_term  = d["v_term_uv"][0]
    v_ocv   = d["v_ocv_uv"][0]
    ina_bus = d["ina228_bus_uv"][0]

    def vv(v, label=""):
        if v is not None:
            print(f"  {label:<20} = {v/1e6:.4f} V  ({v:,} µV)")
        else:
            print(f"  {label:<20} = N/A")
        if explain and v is not None:
            explain_value(label)

    vv(v_now,   "voltage_now")
    vv(v_term,  "v_term_uv")
    vv(v_ocv,   "v_ocv_uv")
    vv(ina_bus, "ina228_bus_uv")

    print()
    if v_term is not None and v_ocv is not None:
        diff = v_term - v_ocv
        sign = "+" if diff > 0 else ""
        print(f"  {'dV (v_term - v_ocv)':<20} = {sign}{diff/1e6:.4f} V")
        if explain:
            explain_value("dV (v_term - v_ocv)")

    if v_now is not None and v_term is not None:
        diff2 = v_now - v_term
        sign2 = "+" if diff2 > 0 else ""
        print(f"  {'dV (v_now - v_term)':<20} = {sign2}{diff2/1e6:.4f} V")
        if explain:
            explain_value("dV (v_now - v_term)")

    # ── current & power ───────────────────────────────────────────────────

    section("Current / Power (INA228)",
            "Current flow direction and magnitude - negative = charging")

    curr_now  = d["current_now"][0]
    ina_cur   = d["ina228_current_ua"][0]
    ina_pow   = d["ina228_power_mw"][0]
    ina_shunt = d["ina228_shunt_uv"][0]
    power_now = d["power_now"][0]

    def ca(v, label=""):
        if v is not None:
            sign = "+" if v > 0 else ""
            print(f"  {label:<20} = {sign}{v/1e6:.4f} A")
        else:
            print(f"  {label:<20} = N/A")
        if explain and v is not None:
            explain_value(label)

    ca(curr_now,  "current_now")
    ca(ina_cur,   "ina228_current_ua")
    if ina_pow is not None:
        print(f"  {'ina228_power_mw':<20} = {ina_pow/1e3:.4f} W")
        if explain:
            explain_value("ina228_power_mw")
    if power_now is not None:
        print(f"  {'power_now':<20} = {power_now/1e6:+.4f} W")
        if explain:
            explain_value("power_now")

    if ina_shunt is not None and ina_cur is not None and ina_shunt != 0:
        computed_r = abs(ina_shunt) / abs(ina_cur) * 1e6
        print(f"  {'implied_Rshunt':<20} = {computed_r:.1f} µΩ")
        if explain:
            explain_value("implied_Rshunt")

    ttf = d["time_to_full_now"][0]
    if ttf is not None:
        print(f"  {'time_to_full':<20} = {ttf}s = {ttf/60:.1f} min")

    ichg     = d["ichg"][0]
    ichg_max = d["ichg_max"][0]
    iin_lim  = d["iin_lim"][0]

    print()
    ca(ichg,     "ichg_set")
    ca(ichg_max, "ichg_max")
    ca(iin_lim,  "iin_lim")

    if explain:
        print()
        print("      Charge current (ichg) is limited by:")
        print("        1. ichg_max: Maximum allowed by charger IC")
        print("        2. iin_lim:  USB adapter current limit")
        print("        3. Battery temperature (reduces when cold/hot)")
        print("        4. Battery age/voltage (reduces near full)")

    # ── SOC cross-check ──────────────────────────────────────────────────

    section("SOC Comparison",
            "State-of-Charge from different measurement methods")

    if coulomb is not None and full is not None and full > 0:
        coulomb_pct = coulomb * 100 / full
        kv("coulomb_pct",  f"{coulomb_pct:.1f}%")
    else:
        coulomb_pct = None

    ocv_drv = d["ocv_soc_pct"][0]
    if ocv_drv is not None:
        kv("ocv_soc_pct", f"{ocv_drv}% (driver table)")

    ocv_vals = {
        "v_ocv": v_ocv,
        "v_term": v_term,
        "v_now": v_now,
    }
    for label, v_uv in ocv_vals.items():
        if v_uv is not None:
            pct = ocv_pct(v_uv)
            gap = (coulomb_pct - pct) if coulomb_pct is not None else None
            gap_str = f"  (Δ {gap:+.0f} pp vs coulomb)" if gap is not None else ""
            print(f"  OCV at {label}={v_uv/1e6:.3f}V -> {pct:.0f}%{gap_str}")
            if explain:
                explain_value(f"OCV at {label}")

    if explain:
        print()
        print("      SOC Estimation Methods:")
        print("        1. Coulomb counting: Integrates current over time (accurate)")
        print("           - Drifts over time, needs periodic OCV calibration")
        print("        2. OCV lookup: Maps voltage to SOC using battery curve")
        print("           - Most accurate when battery has rested")
        print("           - Less accurate during high current flow")
        print()
        print("      Δ (delta) shows the difference:")
        print("        - Positive: Coulomb counter shows MORE charge than OCV suggests")
        print("        - Negative: Coulomb counter shows LESS charge than OCV suggests")
        print("        - Large gaps (>20%%) may indicate need for calibration")

    # ── anomaly checks ────────────────────────────────────────────────────

    section("Diagnostic Checks",
            "Automated health checks - [PASS] = OK, [FAIL] = Problem detected")

    # 1. current sign during Charging
    if status == "Charging" and curr_now is not None:
        if curr_now > 0:
            print(f"[FAIL] current_now = {curr_now/1e6:.3f} A is POSITIVE while status = Charging")
            print(f"       Should be NEGATIVE (negative = current flowing INTO battery)")
        else:
            print(f"[PASS] current direction correct: charging")

    # 2. current sign during Discharging
    if status == "Discharging" and curr_now is not None:
        if curr_now < 0:
            print(f"[FAIL] current_now = {curr_now/1e6:.3f} A is NEGATIVE while status = Discharging")
            print(f"       Should be POSITIVE (current flowing OUT of battery)")
        else:
            print(f"[PASS] current direction correct: discharging")

    # 3. large OCV gap (driver table when present)
    ocv_pct_val = d["ocv_soc_pct"][0]
    if ocv_pct_val is None and v_ocv is not None:
        ocv_pct_val = ocv_pct(v_ocv)
    if coulomb_pct is not None and ocv_pct_val is not None:
        gap = coulomb_pct - ocv_pct_val
        if abs(gap) > 30:
            print(f"[FAIL] Coulomb={coulomb_pct:.0f}% vs OCV={ocv_pct_val:.0f}% — gap={gap:+.0f} pp")
            print(f"       Large gap may indicate battery needs calibration")
            print(f"       Run after full charge/discharge cycle")
        elif abs(gap) > 15:
            print(f"[WARN] Coulomb={coulomb_pct:.0f}% vs OCV={ocv_pct_val:.0f}% — gap={gap:+.0f} pp")
            print(f"       Moderate gap - calibration recommended")
        else:
            print(f"[PASS] Coulomb vs OCV aligned: gap={gap:+.0f} pp (threshold: 15)")

    # 4. terminal vs OCV during charging
    if status == "Charging" and v_term is not None and v_ocv is not None:
        delta = v_term - v_ocv
        if delta > 200_000:
            print(f"[FAIL] v_term is {delta/1e6:.3f} V above v_ocv during charging")
            print(f"       Large IR drop - possible high current or degraded battery")
        elif delta > 0:
            print(f"[PASS] v_term ({v_term/1e6:.3f}V) > v_ocv ({v_ocv/1e6:.3f}V) — expected during CC charging")
        else:
            print(f"[WARN] v_term <= v_ocv while charging — unusual")

    # 5. capacity_level vs capacity consistency
    if cap is not None and cap_lev is not None:
        if cap >= 50 and cap_lev in ("Low", "Critical"):
            print(f"[FAIL] capacity={cap}% but capacity_level={cap_lev} — inconsistent")
        elif cap >= 20 and cap_lev == "Critical":
            print(f"[WARN] capacity={cap}% but capacity_level={cap_lev} — may trigger shutdown soon")
        elif cap >= 80 and cap_lev in ("Normal", "High", "Full"):
            print(f"[PASS] capacity_level matches capacity")
        else:
            print(f"[PASS] capacity_level={cap_lev} for capacity={cap}%")

    # 6. charge_type vs status mismatch
    if status == "Charging" and chg_type in (None, "None", ""):
        print(f"[FAIL] status=Charging but charge_type={chg_type}")
    elif status == "Not charging" and chg_type not in (None, "None", ""):
        print(f"[WARN] status={status} but charge_type={chg_type}")

    # 7. power_now sign (UPower reads this for state)
    if power_now is not None:
        if status == "Charging" and power_now > 0:
            print(f"[FAIL] power_now={power_now/1e6:.4f} W is POSITIVE while charging")
            print(f"       Desktop may show wrong charging state")
        elif status == "Discharging" and power_now < 0:
            print(f"[WARN] power_now={power_now/1e6:.4f} W is NEGATIVE while discharging")

    # 8. INA228 present
    ina_present = rt(f"{BASE}/ina228_present")
    if ina_present == "1":
        print(f"[PASS] INA228 fuel gauge is present")
        if ina_cur is not None and ina_shunt is not None and ina_cur != 0:
            R = abs(ina_shunt / ina_cur * 1e6)
            if 5_000 < R < 50_000:
                print(f"[PASS] INA228 shunt consistent: R={R:.0f} µΩ (expect ~15 000 µΩ)")
            else:
                print(f"[WARN] INA228 shunt implies R={R:.0f} µΩ (expected ~15 000 µΩ)")
                print(f"       Check shunt resistor or measurement noise")
    else:
        print(f"[FAIL] INA228 not detected — FG will use proxy mode only")
        print(f"       Coulomb counter unavailable, using voltage-only estimation")

    # 9. Coulomb counter vs charge_now consistency
    if coulomb is not None and cap_now is not None and full:
        diff = abs(coulomb - cap_now)
        if diff > full * 0.15:
            print(f"[WARN] coulomb_uah ({coulomb/1e6:.1f}mAh) and charge_now ({cap_now/1e6:.1f}mAh)")
            print(f"       differ by {diff/1e6:.1f}mAh ({100*diff/full:.1f}% of capacity)")
            print(f"       May indicate calibration needed or different measurement methods")
        elif diff > full * 0.05:
            print(f"[INFO] coulomb_uah and charge_now differ by {diff/1e6:.1f}mAh")
            print(f"       Minor difference - normal for different estimation methods")

    # 10. Voltage sanity
    if v_now is not None:
        if v_now < 2_500_000:
            print(f"[FAIL] voltage_now={v_now/1e6:.2f}V is dangerously low!")
            print(f"       Battery protection may trigger immediate shutdown")
        elif v_now < 3_000_000:
            print(f"[WARN] voltage_now={v_now/1e6:.2f}V is low")
            print(f"       Consider charging soon")

    if verbose:
        print()
        print("  Additional Checks:")
        # Time to full sanity
        if ttf is not None and ttf > 86400:
            print(f"  [INFO] time_to_full={ttf/3600:.1f}h — unusually long")
        # Charge full sanity
        if full is not None and (full < 1000000 or full > 100000000):
            print(f"  [WARN] charge_full={full/1e6:.0f}mAh seems unusual")

    print()

    # ── UPower check ──────────────────────────────────────────────────────

    section("UPower / KDE State",
            "How the desktop environment sees the battery")

    print("  The desktop uses these values for tray icon, notifications, etc.")
    print()

    try:
        import subprocess
        result = subprocess.run(
            ["upower", "-i", "/org/freedesktop/UPower/devices/battery_battery"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            line = line.strip()
            if any(x in line for x in ("state:", "percentage:", "energy-rate:", "time to")):
                print(f"  {line}")
    except Exception as e:
        print(f"  (upower check failed: {e})")

    if explain:
        print()
        print("  UPower State Values:")
        print("    charging:      Battery is being charged")
        print("    discharging:   Battery is powering the device")
        print("    fully-charged: Battery is full and not discharging")
        print("    empty:        Battery is depleted")
        print()
        print("  If desktop shows different state than status above,")
        print("  the UPower daemon may need restart:")
        print("    systemctl --user restart upower")

    print()
    print("="*65)
    print(" End of diagnostic report")
    print("="*65)


if __name__ == "__main__":
    main()
