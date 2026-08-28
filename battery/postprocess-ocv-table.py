#!/usr/bin/env python3
"""Postprocess the auto-calibrator's suggested OCV table.

The calibrator emits multiple (voltage_cv, soc) entries per voltage —
one per cluster of samples that disagreed about SOC at that voltage.
The driver's lookup is a bsearch-left that returns p1 from the first
matching entry, so duplicate-voltage rows are dead code (only the
first one per voltage is ever picked).

This script:
  1. Reads the calibrator's suggested_ocv_table.h.
  2. Groups by voltage_cv, picking the dominant SOC (highest sample
     count, ties broken by lower SOC).
  3. Sorts ascending by voltage.
  4. Sanity-checks monotonicity (higher voltage should give higher
     or equal SOC) and reports any inversions.
  5. Writes a clean C-array ready to paste into bq25890_battery.c,
     plus a CSV for sanity checking.
"""

import re
import sys
import csv
from pathlib import Path
from collections import defaultdict


def parse_calibrator_output(path):
    """Return list of (voltage_cv, soc, samples) tuples.

    Two regex passes: the first picks voltage and soc, the second
    extracts the trailing "// N samples" count when present. Splitting
    them keeps the regex simple and avoids the gotcha where a single
    optional non-capturing group makes the match succeed without
    consuming the trailing text.
    """
    out = []
    pat_pair = re.compile(r"\{\s*(\d+)\s*,\s*(\d+)\s*\}")
    pat_samples = re.compile(r"//\s*(\d+)\s*samples")
    with open(path) as f:
        for line in f:
            m = pat_pair.search(line)
            if not m:
                continue
            v = int(m.group(1))
            s = int(m.group(2))
            ms = pat_samples.search(line)
            n = int(ms.group(1)) if ms else 0
            out.append((v, s, n))
    return out


def dominant_per_voltage(rows):
    """Group by voltage, pick highest-samples SOC per group."""
    by_v = defaultdict(list)
    for v, s, n in rows:
        by_v[v].append((s, n))
    out = []
    for v in sorted(by_v):
        # Sort by (-samples, soc): prefer most samples, ties to lower SOC
        # (matches the calibrator's per-bucket "highest vote" selection).
        candidates = sorted(by_v[v], key=lambda x: (-x[1], x[0]))
        s, n = candidates[0]
        out.append((v, s, n))
    return out


def enforce_monotonic(table):
    """Return (cleaned, fixed_count).

    For each row whose SOC is below the previous row's SOC, raise it to
    the previous SOC.  This produces a non-decreasing curve which is
    the only shape the driver's bsearch-left lookup can interpret
    correctly (and the only physically reasonable OCV->SOC mapping for
    a LiPo: as voltage recovers, SOC must not go down).
    """
    cleaned = []
    prev_s = 0
    fixed = 0
    for v, s, n in table:
        if s < prev_s:
            cleaned.append((v, prev_s, n))
            fixed += 1
        else:
            cleaned.append((v, s, n))
            prev_s = s
    return cleaned, fixed


def check_monotonic(table):
    """Return list of (i, prev_v, prev_s, v, s) for any SOC drop."""
    inversions = []
    prev_v, prev_s = None, None
    for i, (v, s, _) in enumerate(table):
        if prev_s is not None and s < prev_s:
            inversions.append((i, prev_v, prev_s, v, s))
        prev_v, prev_s = v, s
    return inversions


def emit_c_array(table, samples_total, coverage_pct, confidence):
    """Emit a C literal for the dominant table, sorted ascending."""
    lines = []
    lines.append("/*")
    lines.append(" * Postprocessed OCV table for piBrick battery driver")
    lines.append(" *")
    lines.append(" * Generated from the calibrator's raw output by collapsing")
    lines.append(" * duplicate-voltage rows to the dominant SOC (highest sample")
    lines.append(" * count). The raw output had multiple (voltage_cv, soc)")
    lines.append(" * entries per voltage, but the driver's bsearch-left lookup")
    lines.append(" * only ever returns the first matching row, so the others")
    lines.append(" * were dead code.")
    lines.append(" *")
    lines.append(f" * Source records: {samples_total}")
    lines.append(f" * SOC coverage: {coverage_pct:.1f}%")
    lines.append(f" * Confidence: {confidence:.2f}")
    lines.append(" *")
    lines.append(" * Replace the voltage_to_percent_table[] block in")
    lines.append(" * bq25890_battery.c with the array below.")
    lines.append(" */")
    lines.append("static VoltageMap voltage_to_percent_table[] = {")
    for v, s, n in table:
        lines.append(f"\t{{ {v:>3}, {s:>3} }},  /* {n} samples */")
    lines.append("};")
    return "\n".join(lines) + "\n"


def emit_csv(table, path):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["voltage_cv", "voltage_v", "soc_pct", "samples"])
        for v, s, n in table:
            w.writerow([v, v / 100.0, s, n])


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            f"usage: {sys.argv[0]} <input.h> <output.h> <output.csv> "
            f"<meta.json>\n"
        )
        sys.exit(1)

    in_h, out_h, out_csv, meta_json = sys.argv[1:5]

    rows = parse_calibrator_output(in_h)
    if not rows:
        sys.stderr.write(f"no rows parsed from {in_h}\n")
        sys.exit(2)

    table = dominant_per_voltage(rows)

    inversions = check_monotonic(table)
    if inversions:
        sys.stderr.write("non-monotonic in raw dominant table:\n")
        for i, pv, ps, v, s in inversions:
            sys.stderr.write(
                f"  row {i}: prev ({pv}, {ps}%) -> ({v}, {s}%)  (SOC dropped)\n"
            )
        sys.stderr.write("applying monotonic-floor fix (raise SOC to previous max)\n")
        table, fixed = enforce_monotonic(table)
        sys.stderr.write(f"  raised {fixed} row(s)\n")
    else:
        fixed = 0

    # Pull metadata from the calibration_status.json next to the file.
    import json
    meta = json.loads(Path(meta_json).read_text())
    samples_total = meta.get("stats", {}).get("resting_records", 0)
    coverage_pct = meta.get("stats", {}).get("soc_coverage_pct", 0)
    confidence = meta.get("confidence", 0)

    Path(out_h).write_text(emit_c_array(table, samples_total, coverage_pct, confidence))
    emit_csv(table, out_csv)

    print(f"input rows:   {len(rows)}")
    print(f"output rows:  {len(table)}  (one per voltage)")
    print(f"inversions:   {len(inversions)}")
    print(f"voltage range: {table[0][0]} - {table[-1][0]} cV")
    print(f"SOC range:     {table[0][1]} - {table[-1][1]} %")
    print(f"wrote {out_h}")
    print(f"wrote {out_csv}")


if __name__ == "__main__":
    main()
