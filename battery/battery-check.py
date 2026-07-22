#!/usr/bin/env python3
"""
piBrick battery diagnostic check.

Reads all relevant fuel-gauge sysfs entries, cross-checks INA228 raw
readings against the coulomb counter, runs the LiPo OCV table, and
reports any anomalies.
"""

import os
import sys
import time

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

# ── paths ─────────────────────────────────────────────────────────────────────

BASE = "/sys/class/power_supply/battery"

FIELDS = {
    "capacity":            f"{BASE}/capacity",
    "status":              f"{BASE}/status",
    "voltage_now":         f"{BASE}/voltage_now",
    "v_term_uv":          f"{BASE}/v_term_uv",
    "v_ocv_uv":           f"{BASE}/v_ocv_uv",
    "current_now":         f"{BASE}/current_now",
    "ina228_current_ua":   f"{BASE}/ina228_current_ua",
    "ina228_power_mw":    f"{BASE}/ina228_power_mw",
    "ina228_bus_uv":      f"{BASE}/ina228_bus_uv",
    "ina228_shunt_uv":    f"{BASE}/ina228_shunt_uv",
    "charge_now":         f"{BASE}/charge_now",
    "coulomb_uah":        f"{BASE}/coulomb_uah",
    "charge_full":        f"{BASE}/charge_full",
    "fg_mode":            f"{BASE}/fg_mode",
    "capacity_level":      f"{BASE}/capacity_level",
    "charge_type":        f"{BASE}/charge_type",
    "time_to_full_now":   f"{BASE}/time_to_full_now",
    "ichg_max":           f"{BASE}/constant_charge_current_max",
    "ichg":               f"{BASE}/constant_charge_current",
    "iin_lim":            f"{BASE}/input_current_limit",
    "power_now":          f"{BASE}/power_now",
}

def read_all():
    return {k: (r(v), rt(v)) for k, v in FIELDS.items()}


# ── LiPo OCV table (0.1V steps, matches driver) ─────────────────────────────

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


# ── sanity limits ─────────────────────────────────────────────────────────────

CHECKS = []

def check(name, cond, msg_ok, msg_fail):
    """Register a check; prints PASS/FAIL immediately."""
    if cond:
        CHECKS.append(f"[PASS] {msg_ok}")
    else:
        CHECKS.append(f"[FAIL] {msg_fail}")


def section(title):
    print(f"\n{'='*60}")
    print(f" {title}")
    print(f"{'='*60}")


def kv(key, val, unit=""):
    print(f"  {key:<20} = {val} {unit}")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    d = read_all()

    # ── basic status ──────────────────────────────────────────────────────

    section("Battery Status")

    status    = d["status"][1]
    cap       = d["capacity"][0]
    cap_lev   = d["capacity_level"][1]
    fg_mode   = d["fg_mode"][1]
    chg_type  = d["charge_type"][1]
    coulomb   = d["coulomb_uah"][0]
    full      = d["charge_full"][0]
    cap_now   = d["charge_now"][0]

    kv("status",         status)
    kv("fg_mode",        fg_mode)
    kv("capacity",        f"{cap}%" if cap is not None else "N/A")
    kv("capacity_level",  cap_lev)
    kv("charge_type",    chg_type)

    print()
    kv("coulomb_uah",    f"{coulomb/1e6:.3f} mAh" if coulomb is not None else "N/A")
    kv("charge_now",      f"{cap_now/1e6:.3f} mAh" if cap_now is not None else "N/A")
    kv("charge_full",     f"{full/1e6:.3f} mAh"  if full  is not None else "N/A")
    if coulomb is not None and full is not None and full > 0:
        kv("coulomb_pct",  f"{coulomb*100/full:.1f}%")

    # ── voltage ───────────────────────────────────────────────────────────

    section("Voltage")

    v_now   = d["voltage_now"][0]
    v_term  = d["v_term_uv"][0]
    v_ocv   = d["v_ocv_uv"][0]
    ina_bus = d["ina228_bus_uv"][0]

    def vv(v, label=""):
        if v is not None:
            print(f"  {label:<18} = {v/1e6:.4f} V  ({v:,} µV)")
        else:
            print(f"  {label:<18} = N/A")

    vv(v_now,   "voltage_now")
    vv(v_term,  "v_term_uv")
    vv(v_ocv,   "v_ocv_uv")
    vv(ina_bus, "ina228_bus_uv")

    if v_term is not None and v_ocv is not None:
        diff = v_term - v_ocv
        sign = "+" if diff > 0 else ""
        print(f"  {'dV (v_term - v_ocv)':<18} = {sign}{diff/1e6:.4f} V")

    if v_now is not None and v_term is not None:
        diff2 = v_now - v_term
        sign2 = "+" if diff2 > 0 else ""
        print(f"  {'dV (v_now - v_term)':<18} = {sign2}{diff2/1e6:.4f} V")

    # ── current & power ───────────────────────────────────────────────────

    section("Current / Power (INA228)")

    curr_now  = d["current_now"][0]
    ina_cur   = d["ina228_current_ua"][0]
    ina_pow   = d["ina228_power_mw"][0]
    ina_shunt = d["ina228_shunt_uv"][0]
    power_now = d["power_now"][0]

    def ca(v, label=""):
        if v is not None:
            sign = "+" if v > 0 else ""
            print(f"  {label:<18} = {sign}{v/1e6:.4f} A")
        else:
            print(f"  {label:<18} = N/A")

    ca(curr_now,  "current_now")
    ca(ina_cur,   "ina228_current_ua")
    if ina_pow is not None:
        print(f"  {'ina228_power_mw':<18} = {ina_pow/1e3:.4f} W")
    if power_now is not None:
        print(f"  {'power_now':<18} = {power_now/1e6:+.4f} W")

    if ina_shunt is not None and ina_cur is not None and ina_shunt != 0:
        computed_r = abs(ina_shunt) / abs(ina_cur) * 1e6  # µΩ
        print(f"  {'implied_Rshunt':<18} = {computed_r:.1f} µΩ")

    ttf = d["time_to_full_now"][0]
    if ttf is not None:
        print(f"  {'time_to_full':<18} = {ttf}s = {ttf/60:.1f} min")

    ichg     = d["ichg"][0]
    ichg_max = d["ichg_max"][0]
    iin_lim  = d["iin_lim"][0]

    print()
    ca(ichg,     "ichg_set")
    ca(ichg_max, "ichg_max")
    ca(iin_lim,  "iin_lim")

    # ── SOC cross-check ──────────────────────────────────────────────────

    section("SOC Comparison")

    if coulomb is not None and full is not None and full > 0:
        coulomb_pct = coulomb * 100 / full
        kv("coulomb_pct",  f"{coulomb_pct:.1f}%")
    else:
        coulomb_pct = None

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

    # ── anomaly checks ────────────────────────────────────────────────────

    section("Diagnostic Checks")

    # 1. current sign during Charging
    if status == "Charging" and curr_now is not None and curr_now > 0:
        print(f"[FAIL] current_now = {curr_now/1e6:.3f} A is POSITIVE while status = Charging")
        print(f"       (Should be negative; negative = current flowing INTO battery)")

    # 2. current sign during Discharging
    if status == "Discharging" and curr_now is not None and curr_now < 0:
        print(f"[FAIL] current_now = {curr_now/1e6:.3f} A is NEGATIVE while status = Discharging")

    # 3. large OCV gap
    if coulomb_pct is not None and v_ocv is not None:
        ocv_pct_val = ocv_pct(v_ocv)
        gap = coulomb_pct - ocv_pct_val
        if abs(gap) > 30:
            print(f"[FAIL] Coulomb={coulomb_pct:.0f}% vs OCV={ocv_pct_val:.0f}% — gap={gap:+.0f} pp (threshold: 30)")
        else:
            print(f"[PASS] Coulomb={coulomb_pct:.0f}% vs OCV={ocv_pct_val:.0f}% — gap={gap:+.0f} pp")

    # 4. terminal vs OCV during charging
    if status == "Charging" and v_term is not None and v_ocv is not None:
        delta = v_term - v_ocv
        if delta > 200_000:
            print(f"[FAIL] v_term is {delta/1e6:.3f} V above v_ocv during charging — unusual!")
        elif delta > 0:
            print(f"[PASS] v_term ({v_term/1e6:.3f}V) > v_ocv ({v_ocv/1e6:.3f}V) — expected during CC charging")

    # 5. capacity_level vs capacity consistency
    if cap is not None and cap_lev is not None:
        if cap >= 50 and cap_lev in ("Low", "Critical"):
            print(f"[FAIL] capacity={cap}% but capacity_level={cap_lev} — should be Normal/High")
        elif cap >= 80 and cap_lev not in ("Normal", "High", "Full"):
            print(f"[WARN] capacity={cap}% but capacity_level={cap_lev}")

    # 6. charge_type vs status mismatch
    if status == "Charging" and chg_type in (None, "None", ""):
        print(f"[FAIL] status=Charging but charge_type={chg_type}")
    elif status == "Not charging" and chg_type not in (None, "None", ""):
        print(f"[WARN] status={status} but charge_type={chg_type}")

    # 7. power_now sign (UPower reads this for state)
    if power_now is not None:
        if status == "Charging" and power_now > 0:
            print(f"[FAIL] power_now={power_now/1e6:.4f} W is POSITIVE while charging (should be negative)")
        elif status == "Discharging" and power_now < 0:
            print(f"[WARN] power_now={power_now/1e6:.4f} W is NEGATIVE while discharging")

    # 8. INA228 present
    ina_present = rt(f"{BASE}/ina228_present")
    if ina_present == "1":
        print(f"[PASS] INA228 fuel gauge is present")
        if ina_cur is not None and ina_shunt is not None and ina_cur != 0:
            R = abs(ina_shunt / ina_cur * 1e6)
            if 5_000 < R < 50_000:  # should be ~15_000 µΩ
                print(f"[PASS] INA228 shunt consistent: R={R:.0f} µΩ (expect ~15 000 µΩ)")
            else:
                print(f"[WARN] INA228 shunt implies R={R:.0f} µΩ (expected ~15 000 µΩ)")
    else:
        print(f"[FAIL] INA228 not detected — FG will use proxy mode only")

    # 9. Coulomb counter vs charge_now consistency
    if coulomb is not None and cap_now is not None:
        diff = abs(coulomb - cap_now)
        if diff > full * 0.1 if full else False:
            print(f"[WARN] coulomb_uah ({coulomb/1e6:.1f}mAh) and charge_now ({cap_now/1e6:.1f}mAh) differ by {diff/1e6:.1f}mAh")

    print()

    # ── UPower check ──────────────────────────────────────────────────────

    section("UPower / KDE State")

    try:
        import subprocess
        result = subprocess.run(
            ["upower", "-i", "/org/freedesktop/UPower/devices/battery_battery"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            line = line.strip()
            if any(x in line for x in ("state:", "percentage:", "energy-rate:")):
                print(f"  {line}")
    except Exception as e:
        print(f"  (upower check failed: {e})")

    print()


if __name__ == "__main__":
    main()
