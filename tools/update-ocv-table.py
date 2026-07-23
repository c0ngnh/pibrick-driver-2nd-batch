#!/usr/bin/env python3
"""Update driver OCV table with calibrated values - properly sorted."""

driver_path = "/usr/lib/pibrick/battery/bq25890_battery.c"

# Read driver source
with open(driver_path, "r") as f:
    content = f.read()

# New calibrated table (voltage ASCENDING = lowest first)
# This matches the original driver format
new_table = '''/* HELPERS */
typedef struct {
    int voltage;
    int percentage;
} VoltageMap;

/*
 * Calibrated OCV Table - piBrick PocketCM5 - 2026-07-23
 * Based on 1086 resting measurements (97% confidence)
 * Voltage in centivolts, sorted ascending (lowest first)
 */
static VoltageMap voltage_to_percent_table[] = {
	{ 327,  10 },  // 34 samples
	{ 330,   0 },  // 46 samples
	{ 332,   5 },  // 53 samples
	{ 333,  15 },  // 41 samples
	{ 338,  20 },  // 47 samples
	{ 341,  25 },  // 56 samples
	{ 343,  30 },  // 45 samples
	{ 348,  35 },  // 52 samples
	{ 350,  40 },  // 46 samples
	{ 358,  45 },  // 49 samples
	{ 364,  50 },  // 79 samples
	{ 369,  55 },  // 116 samples
	{ 373,  60 },  // 61 samples
	{ 375,  65 },  // 60 samples
	{ 379,  70 },  // 54 samples
	{ 383,  75 },  // 62 samples
	{ 386,  80 },  // 58 samples
	{ 390,  85 },  // 63 samples
	{ 394,  90 },  // 69 samples
};
const int table_size = ARRAY_SIZE(voltage_to_percent_table);'''

# Find the original HELPERS block with typedef and old table
start_marker = "/* HELPERS */\ntypedef struct"
end_marker = "const int table_size = ARRAY_SIZE(voltage_to_percent_table);"

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx != -1 and end_idx != -1:
    end_idx += len(end_marker)
    new_content = content[:start_idx] + new_table + "\n\n" + content[end_idx:]
    
    with open(driver_path, "w") as f:
        f.write(new_content)
    print("OCV table updated successfully")
    print(f"Driver: {driver_path}")
else:
    print("Could not find table boundaries")
