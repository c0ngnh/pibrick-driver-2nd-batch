#!/usr/bin/env python3
"""Compare sysfs voltage + capacity against OCV lookup tables (piBrick driver vs LiPo reference)."""

from __future__ import annotations

# Mirrors battery/bq25890_battery.c (centivolts, percent)
PIBRICK_OCV = [
    (298, 0), (328, 5), (348, 10), (358, 20), (363, 30), (366, 40),
    (369, 50), (371, 55), (374, 60), (377, 70), (380, 80), (385, 90),
    (393, 95), (418, 100),
]

# Standard 1S LiPo rest curve at 4.20 V, scaled to 4.176 V full (fuel-gauge baseline).
STD_420 = [
    (300, 0), (330, 5), (350, 10), (360, 20), (365, 30), (368, 40),
    (371, 50), (373, 55), (376, 60), (379, 70), (382, 80), (387, 90),
    (395, 95), (420, 100),
]
SCALE = 4176 / 4200
REF_4176 = [(int(round(mv * SCALE)), p) for mv, p in STD_420]


def ocv_lookup(table: list[tuple[int, int]], voltage_uv: int) -> int:
    """Same math as bq25890_calc_lipo_percentage() in the driver."""
    v = voltage_uv // 10000
    if v <= table[0][0]:
        return 0
    if v >= table[-1][0]:
        return 100
    for i in range(len(table) - 1):
        v1, p1 = table[i]
        v2, p2 = table[i + 1]
        if v1 <= v < v2:
            return p1 + (v - v1) * (p2 - p1) // (v2 - v1)
    return 100


def voltage_for_percent(table: list[tuple[int, int]], pct: int) -> float:
    for i in range(len(table) - 1):
        v1, p1 = table[i]
        v2, p2 = table[i + 1]
        if p1 <= pct <= p2 and p2 != p1:
            v = v1 + (pct - p1) * (v2 - v1) // (p2 - p1)
            return v / 100.0
    return table[-1][0] / 100.0


def main() -> None:
    # Paste your own rows: (label, voltage_uv, reported_pct, status, current_ua)
    readings = [
        ("Discharge", 3_724_000, 42, "Discharging", -400_000),
        ("Charging A", 4_084_000, 75, "Charging", 1_050_000),
        ("Charging B", 4_084_000, 70, "Charging", 750_000),
    ]

    print(f"{'Label':<14} {'V':>7} {'Reported':>9} {'piBrick':>8} {'Ref4176':>8}  Note")
    print("-" * 72)
    for label, uv, rep, status, i_ua in readings:
        pb = ocv_lookup(PIBRICK_OCV, uv)
        ref = ocv_lookup(REF_4176, uv)
        note = ""
        if i_ua and i_ua > 50_000:
            note = "charging — ignore for OCV tune"
        elif status == "Discharging" and i_ua and i_ua < -100_000:
            note = "loaded — V below rest OCV"
        print(f"{label:<14} {uv/1e6:7.3f} {rep:8}% {pb:7}% {ref:7}%  {note}")

    print("\nIf 42% at 3.724 V were true rest SOC, implied rest voltage:")
    for name, tbl in [("piBrick", PIBRICK_OCV), ("Ref4.176", REF_4176)]:
        print(f"  {name}: {voltage_for_percent(tbl, 42):.3f} V")

    print("\nCollect calibration points (unplug, idle 10+ min, read sysfs):")
    print("  paste lines: voltage_uv capacity status current_ua")


if __name__ == "__main__":
    main()
