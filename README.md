# piBrick pocketcm5 drivers

Kernel modules and desktop helpers for the piBrick CM5 handheld (Visionox VTDR6110 / 9203 AMOLED, BQ25895 PMIC without a fuel gauge).

This document summarizes recent battery and display work. For installation steps, see [INSTALL.md](INSTALL.md).

---

## Battery (BQ25895)

**Source:** `battery/bq25890_battery.c`  
**Hardware:** Texas Instruments BQ25895 charger only — no dedicated fuel gauge. State of charge is estimated from battery voltage (OCV table), charge current, and smoothing logic.

### Problems addressed


| Issue                                                    | Fix                                                                                                       |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Low % while charging (e.g. 4.14 V showing ~14% at 1.6 A) | Reduced IR over-correction; charging path uses seed + current integration instead of raw terminal voltage |
| % stuck low after unplug                                 | Shorter post-unplug relax window; upward correction allowed once voltage has rested                       |
| Confusing “time remaining”                               | Separate sysfs for charging vs discharging; desktop label shows **“to full”** vs **“left”**               |
| Boot calibrate resetting a good %                        | 30 s boot calibration skipped if capacity is already valid                                                |
| Time estimate mismatch                                   | `time_to_empty_avg` and `current_now` share the same assumed 1.3 A average load                           |


### Key tuning constants


| Constant                        | Value                 | Purpose                                    |
| ------------------------------- | --------------------- | ------------------------------------------ |
| `BQ25890_BATT_IR_MOHM`          | 220 mΩ                | Terminal → OCV correction while charging   |
| `BQ25890_UNPLUG_RELAX_INTERVAL` | 60 s                  | Block upward % moves right after unplug    |
| `BQ25890_CHARGE_HIGH_TERM_UV`   | 4.0 V                 | High terminal voltage while charging       |
| `BQ25890_CHARGE_SEED_FLOOR_PCT` | 40%                   | Minimum seed when V > 4.0 V                |
| `BQ25890_DISCHARGE_CURRENT_UA`  | 1.3 A                 | Assumed average load for runtime estimates |
| `BQ25890_CHARGE_FULL_UAH`       | 5000 mAh              | Nominal pack capacity                      |
| `BQ25890_FULL_RUNTIME_SEC`      | ~~13 846 s (~~3.85 h) | Derived from capacity ÷ discharge current  |


### Capacity logic (overview)

**On battery**

- Smoothed BATV → OCV lookup table
- For 60 s after unplug: % cannot increase (post-charge ghost voltage)
- After relax: % may rise only if gap ≥ 10% (stale-low correction)

**On charger**

- Seed at plug-in from compensated voltage
- ICHGR integration between refreshes (not raw voltage alone)
- Floor and stale-bump rules when terminal voltage > 4.0 V

### Sysfs / power_supply properties

Exports standard battery properties plus:

- `time_to_full_now` — remaining charge time from measured ICHGR
- `time_to_empty_avg` — remaining runtime from % × nominal full runtime

### Desktop

`desktop/pibrick-battery-indicator.py` — taskbar widget showing %, voltage, and time label:

- Charging → **“X to full”** (reads `time_to_full_now`)
- Discharging → **“X left”** (reads `time_to_empty_avg`)

Fallback formulas match the kernel driver constants.

### Optional calibration tool

`tools/ocv-calibrate.py` — helper for tuning the OCV table from measured voltage vs actual %.

### BQ25895 limitations (hardware + software)

The **BQ25895 is a charger PMIC**, not a fuel gauge. On pocketcm5 it is the only battery-related IC — there is no MAX17048 or similar. Everything the user sees as “battery %” is **reconstructed in software** from the charger’s limited ADCs and heuristics.

**What the chip can measure**


| Signal                   | Register / path      | Useful for                                |
| ------------------------ | -------------------- | ----------------------------------------- |
| Battery terminal voltage | `BATV` ADC           | OCV estimate when load is low             |
| Charge current           | `ICHGR`              | Valid mainly **while charging** from VBUS |
| VBUS / adapter presence  | `VBUSV`, status bits | Plug detection, charging state            |
| Charge control           | `ICHG`, `VREG`, etc. | Charging — not state of charge            |


**What the chip cannot do**

- **No coulomb counting** — cannot integrate mAh in/out over time in hardware
- **No discharge-current sense** — load current while on battery is unknown; driver assumes **1.3 A** average for `current_now` and `time_to_empty_avg`
- **No cell-aging model** — capacity is fixed at **5000 mAh** in software
- **No per-cell profiling** — single-cell only; pack chemistry/age is not learned automatically

**Software estimation limits** (even with our driver improvements)


| Situation                      | Limitation                                                                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Heavy CPU/GPU load**         | Terminal voltage sags below true OCV → % can read low until load drops (BATV smoothing helps, does not remove)                     |
| **While charging**             | Terminal voltage is above true OCV (IR drop + polarization) → raw voltage is misleading; we use seed + `ICHGR` integration instead |
| **Right after unplug**         | “Ghost” elevated voltage for ~1 min → % is held steady to avoid a false jump                                                       |
| **Cold / hot pack**            | No NTC in this estimate path; temperature affects OCV but is not fully compensated                                                 |
| **Time remaining (discharge)** | `time_to_empty_avg` = % × assumed runtime, not measured load — wrong if you are far above/below 1.3 A                              |
| **Time to full**               | Uses measured `ICHGR` — reasonable while CC/CV is stable; less accurate in taper/precharge                                         |
| **OCV table**                  | Tuned for this 5000 mAh 1S pack at 4.176 V full; other cells need `tools/ocv-calibrate.py`                                         |
| **Reboot**                     | % is re-derived from voltage/heuristics, not restored from NVM (no gauge to remember SOC)                                          |


These are **fundamental to charger-only designs**. The driver reduces obvious errors (low % at 4.14 V while charging, post-unplug stuck %, confusing time labels) but cannot match a dedicated fuel gauge.

### Comparison: pocketcm5 (BQ25895) vs HackberryPi (MAX17048)

HackberryPi CM5 uses a **separate MAX17048 fuel gauge** (`hackberrypi-max17048.c`) alongside its charger. pocketcm5 uses **BQ25895 only**.


|                         | **pocketcm5 — BQ25895 only**                                              | **HackberryPi — MAX17048 gauge**                               |
| ----------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------- |
| **Chips**               | One I2C device (charger)                                                  | Charger **+** MAX17048 fuel gauge                              |
| **SOC (`capacity`)**    | Software: OCV table, smoothing, charge integration                        | Hardware: `SOC` register (ModelGauge in the IC)                |
| **Voltage**             | Charger `BATV` ADC                                                        | Gauge `VCELL` register                                         |
| **Current / direction** | Charge: measured `ICHGR`; discharge: **assumed** 1.3 A                    | Gauge `CRATE` (signed charge rate) for charge vs discharge     |
| **While charging**      | % from heuristics + current integration                                   | Gauge reports SOC directly from its model                      |
| **Under load**          | Voltage sag distorts OCV lookup                                           | Gauge model handles load better than raw BATV                  |
| **Capacity / aging**    | Fixed 5000 mAh in driver                                                  | Gauge tracks pack; DT sets `battery-capacity` for `charge_now` |
| `**time_to_full_now`**  | Yes — from measured `ICHGR`                                               | Not implemented in HackberryPi driver                          |
| `**time_to_empty_avg**` | Yes — from % and assumed 1.3 A                                            | Not implemented in HackberryPi driver                          |
| **Driver complexity**   | Large (`bq25890_battery.c` — estimation, relax windows, tuning constants) | Small (~180 lines — read registers, expose properties)         |
| **Tuning**              | OCV table, IR mΩ, relax intervals, seed floors                            | `battery-capacity` in device tree; gauge self-learning         |
| **Trade-off**           | Lower BOM, one chip, more software guesswork                              | Extra IC and I2C address, more trustworthy %                   |


**MAX17048 is not perfect either** — it still needs correct pack capacity in DT, benefits from learning cycles, and can drift if chemistry or load differs from its model. But it is **designed** to answer “how full is the cell?” whereas the BQ25895 is **designed** to answer “how do I charge the cell safely?”.

**Why pocketcm5 cannot simply use the HackberryPi driver:** there is no MAX17048 on the board. Improving battery UX here means better **software estimation** on top of the BQ25895, or a **hardware revision** adding a fuel gauge.

---

## Display (Visionox VTDR6110 / 9203)

**Canonical source:** `panel-pibrick.9203.c`  
**Built as:** `panel-pibrick.c` (copied by Makefile before compile)  
**Panel:** 1080×1240 AMOLED, DSI, `pibrick-backlight`

### Problems/minor adjustments:


| Area          | Change                                                                                              |
| ------------- | --------------------------------------------------------------------------------------------------- |
| Lifecycle     | `on()` runs vendor init only; `enable()` does sleep exit + display on (no duplicate wake in `on()`) |
| Build         | Makefile copies `panel-pibrick.9203.c` → `panel-pibrick.c` on every `make modules`                  |
| Refresh rate  | **60 Hz** preferred mode; **90 Hz** alternate mode                                                  |
| Backlight     | **30%** default at registration and in init DCS `0x51` (no full-brightness boot flash)              |
| Sysfs cleanup | Both `color_profile` and `pibrick_display_enable` removed in driver `remove()`                      |
| Color profile | Default `natural` in probe; store applies only when display is enabled                              |
| Dead code     | Legacy init sequences kept under `#if 0` (not compiled)                                             |


### Configuration (`panel-pibrick.9203.c`)

```
_AMOLED_REFRESH_RATE      60 Hz (preferred)
_AMOLED_REFRESH_RATE_ALT  90 Hz (secondary)
_AMOLED_HDISPLAY × _AMOLED_VDISPLAY   1080 × 1240
_AMOLED_BACKLIGHT_MAX     1023
_AMOLED_BACKLIGHT_DEFAULT 30% (306)
```

Init brightness uses the same DCS encoding as `mipi_dsi_dcs_set_display_brightness_large()` via `DCS_BRIGHTNESS_MSB` / `DCS_BRIGHTNESS_LSB` macros.

### DRM panel lifecycle

```
prepare  → regulators, reset, vendor init (visionox_vtdr6110_on)
enable   → exit sleep, display on
disable  → display off, enter sleep
unprepare → panel off, reset high, regulators off
```

### Sysfs


| Attribute                | Path (under DSI device)      | Description                                                        |
| ------------------------ | ---------------------------- | ------------------------------------------------------------------ |
| `color_profile`          | `.../color_profile`          | `natural`, `vivid`, `srgb`, `warm`, `cold`/`cool`, `night`, `soft` |
| `pibrick_display_enable` | `.../pibrick_display_enable` | Debug hook: `0`/`1` to disable/enable panel                        |


Example:

```bash
echo cool > $(find /sys -name color_profile | grep dsi)
```

### Device tree

`dts/vc4-kms-dsi-pibrick.dts` — 1080×1240 timing, touch coordinates, overlay for Pi firmware.

---

## Install and verify

```bash
sudo bash ./install.sh
sudo reboot
```

### Battery

```bash
cat /sys/class/power_supply/battery/{voltage_now,capacity,current_now,status,time_to_full_now,time_to_empty_avg}
```

### Display

**1. Module installed**

```bash
ls -l /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/panel/panel-pibrick.ko
```

**2. Resolution** — `modes` lists size only, not refresh rate:

```bash
cat /sys/class/drm/card*/card*/modes | head -1
# expect: 1080x1240
```

**3. Refresh rate** — use debugfs or `modetest` (the driver marks 60 Hz as preferred):

```bash
sudo cat /sys/kernel/debug/dri/0/state | grep -E 'mode|refresh|clock' -A2
```

```bash
modetest -c 2>/dev/null | grep -A3 1080x1240
```

**4. Backlight** — driver default is **306** (30% of 1023). Desktop or saved session settings may lower it after boot (e.g. ~205 ≈ 20% is normal if you adjusted brightness before):

```bash
cat /sys/class/backlight/pibrick-backlight/{brightness,max_brightness}
# max_brightness: 1023, brightness at first boot: 306

# reset to driver default:
echo 306 | sudo tee /sys/class/backlight/pibrick-backlight/brightness
```

**5. Panel probe** — healthy boot looks like `panel-pibrick` attached and `drm-rp1-dsi` bound with `fb0`:

```bash
dmesg | grep -iE 'panel-pibrick|drm-rp1-dsi'
```

Harmless messages you can ignore:

- `Fixed dependency cycle(s)` — common DSI panel ↔ host DT cycle
- `supply vddio/vci/vdd not found, using dummy regulator` — regulators not named in DT
- `pibrick.service is marked executable` — fix with `sudo chmod 644 /etc/systemd/system/pibrick.service`

---

## Key files


| File                                   | Role                                                       |
| -------------------------------------- | ---------------------------------------------------------- |
| `battery/bq25890_battery.c`            | BQ25895 battery / charger driver                           |
| `panel-pibrick.9203.c`                 | Canonical AMOLED panel driver (9203)                       |
| `Makefile`                             | Copies `.9203.c` → `panel-pibrick.c`, builds module + DTBO |
| `install.sh` / `build.sh`              | Install and kernel module build                            |
| `desktop/pibrick-battery-indicator.py` | Taskbar battery % and time readout                         |
| `desktop/setup-desktop.sh`             | Desktop autostart setup                                    |
| `dts/vc4-kms-dsi-pibrick.dts`          | Display overlay source                                     |


