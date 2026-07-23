# piBrick pocketcm5 drivers

Kernel modules and user-space helpers for the piBrick CM5 handheld (Raspberry Pi CM5 + Visionox AMOLED). The default panel is **9203** (SD5302H, PocketCM5); **9202**, **5.48 inch**, and **5 inch** variants are selectable at install time.

| Component | Path | Hardware |
|-----------|------|----------|
| Display | `panel-pibrick.9203.c`, `panel-pibrick.9202.c`, `panel-pibrick.548.c`, `panel-pibrick.5inch.c`, `dts/` | Visionox AMOLED on DSI1 — 9203 default (1080×1240 @ 90/60 Hz), each with its corresponding touch driver |
| Touch | `hyn_driver_release_qm/` | Hynitron CST66xx (`compatible = "hyn,66xx"` in DTS) |
| Battery | `battery/bq25890_battery.c` | TI BQ25895 PMIC; optional **TI INA228** high-precision current sensor (compile-time toggle) |
| Buttons | `button-service/` | GPIO daemon for power + user buttons |
| Desktop | `desktop/` | GTK taskbar battery indicator, `pibrick-display-settings` |
| Tools | `tools/` | Display settings menu, GNOME refresh helper, touch reset, OCV calibration |
| Calibration | `battery/battery-calibration-logger.py`, `battery/battery-auto-calibrator.py` | Automatic battery OCV calibration service |

This repository bundles the display, touch, battery, button, and desktop pieces into a single installable tree, targeting **Raspberry Pi OS on kernel 6.18** with **GNOME 48 (Wayland)** or **KDE Plasma Mobile**.

## Install

```bash
sudo bash ./install.sh
```

`install.sh` provides an **interactive menu** for component selection:

### Interactive Selection

```
=== piBrick Driver Installer ===

=== Display Panel Selection ===
Select your panel type:
  1) 9203 - Visionox 1080x1240 @ 90/60 Hz (PocketCM5 default) [Hynitron touch]
  2) 9202 - Visionox 1080x1240 @ 60 Hz (legacy) [Hynitron touch]
  3) 548 - 5.48 inch 1080x1920 @ 60 Hz [FocalTech touch]
  4) 5inch - 5 inch 1080x1240 @ 90/60 Hz [Hynitron touch]
  5) Skip display installation
Choose [1]: 

=== Battery Driver Selection ===
  1) Battery + INA228 (recommended) - High-precision current sensor
  2) Battery only (original) - If no INA228 hardware installed
Choose [1]: 

Install Calibration Tools (logger + auto-calibrator) [Y/n]: 
Apply UPower KDE Fix (show Charging state) [Y/n]: 
Install Button Service (pibrickbtn) [Y/n]: 
```

Each panel has its **matching touch driver**:
- **9203 / 9202 / 5inch** → Hynitron CST66xx (`hyn,66xx`)
- **548** (5.48 inch) → FocalTech (`edt-ft5406`)

### Non-Interactive Installation

Install specific components using `--install`:

```bash
# Install everything
sudo bash ./install.sh --install all

# Install display with interactive panel selection
sudo bash ./install.sh --install display

# Install battery with INA228 support
sudo bash ./install.sh --install battery-new

# Install original battery (bq25895 only, no INA228)
sudo bash ./install.sh --install battery

# Install battery + calibration tools
sudo bash ./install.sh --install battery-new,calibration

# Install UPower fix and button service
sudo bash ./install.sh --install upower,button
```

### Panel Selection

`install.sh` prompts for the panel variant and saves the choice to `/etc/pibrick.panel`. You can also pick it non-interactively:

```bash
sudo PANEL=9203  bash ./install.sh   # SD5302H (90/60 Hz, 90 Hz default)
sudo PANEL=9202  bash ./install.sh   # legacy 1080×1240 @ 60 Hz
sudo PANEL=548   bash ./install.sh   # 5.48 inch 1080×1920 @ 60 Hz (FocalTech)
sudo PANEL=5inch bash ./install.sh   # 5 inch 1080×1240 @ 90/60 Hz
```

The default refresh rate is **90 Hz** for the 9203 panel (saved to `/etc/pibrick.display-refresh` and applied on login). Use `pibrick-display-settings --refresh 60` for lower power.

### Battery Driver Selection

The battery driver **automatically detects** the INA228 hardware at runtime. There is no separate "original" build:

| Option | Description |
|--------|-------------|
| `battery-new` (default) | Battery driver — INA228 auto-detected at runtime |
| `battery` | Same as `battery-new` (alias for compatibility) |

**How it works:**
- The driver probes for INA228 at I2C address `0x40` during init
- If INA228 is found → high-precision current/power measurements enabled
- If INA228 is not found (no hardware) → driver uses BQ25895 internal current sense + load-aware estimator (no errors)
- Either way, the same `.ko` is loaded — no need to rebuild

This means **you can install `battery-new` even without INA228 hardware**; the driver gracefully falls back. The `battery` option is kept as an alias for compatibility.

### Calibration Service Management

The calibration system has **two separate functions**:

1. **Logging Service** - Collects battery data (voltage, SOC, current) for analysis
2. **Apply OCV Table** - Actually installs the calibrated table to the driver

#### Calibration Workflow

```bash
# Step 1: Enable logging (collects data continuously in background)
sudo /usr/lib/pibrick/install.sh --enable-calibration

# Step 2: Let it collect data (use your device normally for 1-2 days)
# - Resting measurements are automatically selected
# - At least 1000 samples recommended for accurate calibration

# Step 3: Check status and confidence level
sudo /usr/lib/pibrick/install.sh --status-calibration
# Look for "Confidence: 0.97 (97%)" - higher is better
# Need at least 85% confidence to apply

# Step 4: Apply the calibrated OCV table to driver (only when ready)
sudo /usr/lib/pibrick/install.sh --apply-calibration

# Step 5: Driver will be rebuilt and reloaded automatically
```

#### Command Reference

| Command | What it does |
|---------|--------------|
| `--enable-calibration` | **Starts logging service** - only collects data, does NOT modify driver |
| `--disable-calibration` | **Stops logging service** - data is preserved |
| `--status-calibration` | Shows data stats, confidence level, sample count |
| `--apply-calibration` | **Applies calibrated OCV table** - rebuilds driver |

**Important**: `--enable-calibration` only starts the data collection service. It does NOT automatically apply anything to the driver. You must manually run `--apply-calibration` when you have enough data.

#### Manual Calibration Tools

You can also use the Python tools directly:

```bash
# Check calibration status and confidence
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --status

# Generate OCV table from existing data (dry run - shows what would be applied)
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --generate

# Apply the OCV table to the driver (works with both INA228 and non-INA228 builds)
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --apply

# Force rebuild and reload driver with current OCV table
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --build-driver
```

**Note**: The `--apply-calibration` step works correctly **regardless of whether INA228 is present**. The OCV table affects the driver's voltage-to-SOC lookup, which is independent of the INA228 current sensor. The calibration data uses BQ25895's `voltage_now` (always available) — INA228 is only used for more accurate current measurements during data collection.

#### Calibration Log Files

| File | Purpose |
|------|---------|
| `/var/log/bq25890_battery/calibration_data.csv` | Raw calibration measurements |
| `/var/log/bq25890_battery/calibration.log` | Human-readable log |
| `/var/log/bq25890_battery/calibration_status.json` | Analysis results |
| `/var/log/bq25890_battery/suggested_ocv_table.h` | Generated C header for driver |

---

## What's New

### Interactive Installer (`install.sh`)

The new **interactive installer** provides a user-friendly menu for selecting components:

- **Display Driver Selection**: Choose between NEW (with INA228) or OLD (original Hyn)
- **Battery Driver**: Full battery fuel gauge with INA228 integration
- **Calibration Tools**: Automatic voltage-SOC data collection and OCV table generation
- **UPower KDE Fix**: Correct charging state display in KDE Plasma Mobile
- **Button Service**: GPIO-based power and user button handling

#### Installation Options

| Option | Description |
|--------|-------------|
| `--install all` | Install all components |
| `--install display-new` | Display with INA228 integration |
| `--install display-old` | Original Hyn display driver |
| `--install battery` | Battery driver (bq25895 + INA228) |
| `--install calibration` | Calibration logger + auto-calibrator |
| `--install upower` | UPower KDE fix |
| `--install button` | Button service |
| `--status-calibration` | Show calibration status |
| `--enable-calibration` | Start calibration logging |
| `--disable-calibration` | Stop calibration logging |
| `--apply-calibration` | Apply calibrated OCV table |

---

### Battery Driver with INA228 Integration

The battery driver (`battery/bq25890_battery.c`) has been significantly enhanced with **TI INA228** support:

#### Features

| Feature | Description |
|---------|-------------|
| **INA228 High-Precision Sensor** | 20-bit ADC for accurate current/voltage/power measurement |
| **Coulomb Counter Integration** | INA228 POWER register tracks energy with 1mW resolution |
| **Real Current Sensing** | No more proxy/estimated current - actual measurements from INA228 |
| **Power Calculation** | INA228 provides direct power measurement in mW |
| **Temperature Monitoring** | INA228 die temperature in millidegrees Celsius |
| **Bus Voltage Sensing** | INA228 bus voltage for accurate OCV readings |

#### Sysfs Interface

```
/sys/class/power_supply/battery/
├── capacity              # SOC percentage (0-100)
├── voltage_now          # Battery voltage (microvolts)
├── current_now          # Current from BQ25895 (microamps)
├── ina228_current_ua    # Precise current from INA228 (microamps)
├── ina228_bus_uv        # Bus voltage from INA228 (microvolts)
├── ina228_power_mw      # Power from INA228 (milliwatts)
├── ina228_dietemp_mdeg_c # INA228 die temperature
├── ina228_present       # INA228 presence flag
├── fg_mode              # Fuel gauge mode: charging, active, resting, full
├── charge_now           # Remaining charge (microamp-hours)
├── charge_full          # Full charge capacity (microamp-hours)
├── charge_full_design   # Design capacity (microamp-hours)
├── status              # Charging, Discharging, Full, Not Charging
├── time_to_empty_avg   # Estimated time to empty (seconds)
└── time_to_full_now   # Estimated time to full (seconds)
```

#### Battery Tools

| Tool | Purpose |
|------|---------|
| `battery_set.py` | Interactive battery parameter setter (charge_full_uah, ina228_shunt_uohm, etc.) |
| `battery-check.py` | Comprehensive battery diagnostics |
| `battery-soc-persist.py` | SOC persistence across reboots |
| `battery-calibration-logger.py` | Logs voltage-SOC data continuously |
| `battery-auto-calibrator.py` | Analyzes data and generates OCV table |

---

### Automatic Battery Calibration

The calibration system automatically builds an accurate voltage-to-SOC mapping:

#### How It Works

1. **Data Collection**: `battery-calibration-logger.py` continuously logs battery data:
   - SOC percentage
   - Voltage (from INA228)
   - Current (from INA228)
   - Fuel gauge mode (charging/active/resting)
   - Timestamp

2. **Resting State Detection**: Only resting measurements (low current, not charging) are used for OCV calibration - these give the most accurate voltage readings.

3. **Analysis**: `battery-auto-calibrator.py` processes the data:
   - Groups by SOC bucket (5% intervals)
   - Calculates average voltage per bucket
   - Generates confidence score
   - Creates calibrated OCV table

4. **Application**: The calibrated OCV table is applied to the driver for accurate SOC estimation.

#### Calibration Status

```
============================================================
Battery Calibration Status
============================================================
Last update: 2026-07-23T18:06:59
Confidence: 0.97 (97.2%)

Total records: 1497
Resting records: 1086
SOC coverage: 93.1%
SOC levels: [1, 2, 3, 4, 5, ... 92, 93, 94]
============================================================
[READY] Calibration ready for application (confidence >= 85%)
```

#### Using Calibration Data

```bash
# Check calibration status
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --status

# Analyze existing data
sudo python3 /home/congn/battery-tools/battery-auto-calibrator.py --check

# Generate OCV table from data
sudo python3 /home/congn/battery-tools/battery-calibration-logger.py --generate-ocv-table

# Apply the calibrated OCV table
sudo /usr/lib/pibrick/install.sh --apply-calibration
```

#### Calibration Log Files

| File | Purpose |
|------|---------|
| `/var/log/bq25890_battery/calibration_data.csv` | Raw calibration measurements |
| `/var/log/bq25890_battery/calibration.log` | Human-readable log |
| `/var/log/bq25890_battery/calibration_status.json` | Analysis results |
| `/var/log/bq25890_battery/suggested_ocv_table.h` | Generated C header for driver |

---

### Display

- **Panel drivers** at the repo root: `panel-pibrick.9203.c` (default), `panel-pibrick.9202.c`, `panel-pibrick.548.c`, `panel-pibrick.5inch.c`. The build picks one via `PANEL=`; `install.sh` prompts and remembers the choice in `/etc/pibrick.panel`.
- **Kernel 6.18 panel allocation** — both drivers use `devm_drm_panel_alloc()` (refcounted) instead of the deprecated `devm_kzalloc` + `drm_panel_init` pattern, which prevents a panel use-after-free on unbind / session restart.
- **Full power lifecycle** — `prepare` / `unprepare` plus `enable` / `disable` and a `shutdown` handler, with LPM-safe DSI sequencing during power transitions.
- **Selectable refresh** — 90 Hz default on 9203; 60 Hz available for lower power.
- **Color profiles** (9203) via sysfs `color_profile`: `natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft`.
- **Display on/off** via sysfs `pibrick_display_enable`. The attribute is `0644` in-driver (kernel 6.18 forbids world-writable `0666` sysfs attrs); user write access is granted at runtime by the `99-pibrick-display.rules` udev rule and the button service.
- **Backlight** as the `pibrick-backlight` class (0–1023).

### Device tree (`dts/vc4-kms-dsi-pibrick.dts`)

- DSI1, 1080×1240 panel; `hyn,66xx` touch on I2C0.
- PMIC node is `ti,bq25895` (matches the CM5 hardware) with charge-regulation voltage `4.176 V`.

### Touch (`hyn_driver_release_qm/`)

- Panel power is followed through the **mainline `drm_panel_follower` API** (gated on `CONFIG_DRM_PANEL`), so the module builds and tracks blank/unblank correctly on the Pi kernel. If panel-follower support is absent, it falls back to `dev_pm_ops` (touch stays active while awake).
- Follower callbacks (`panel_prepared` / `panel_unpreparing`) are serialised by the panel core around the real power transition, avoiding suspend/resume races.
- `hyntpdbg` `rst` performs a full resume when the controller is suspended (not just a chip reset).
- The button daemon does not reload the touch module; the display toggle sends a touch wake instead.

### Build & Packaging

- `install.sh` — interactive installer with component selection, `set -euo pipefail`, saves panel + default refresh, removes any stale `panel-pibrick.c`, runs the desktop and button-service installers, and regenerates the initramfs when `auto_initramfs=1`.
- `build.sh` — `--force` / `--no-reboot` flags, rebuilds on kernel change, synchronous install, initramfs regen.
- `Makefile` — `make amoled PANEL=9203|9202|548|5inch`; symlinks the chosen source to `panel-pibrick.c`; refuses to uninstall if the new `.ko` is missing.
- `pibrick.service` — rebuilds the out-of-tree modules automatically on kernel updates.
- `battery/Makefile` — includes calibration targets: `make install-calibration`, `make enable-calibration`, `make disable-calibration`, `make apply-calibration`.

### Desktop & Tools

- `desktop/pibrick-battery-indicator.py` taskbar battery indicator with autostart.
- `tools/pibrick-display-settings.sh`, `tools/gnome-display-rate.py`, `tools/ocv-calibrate.py`.
- Calibration tools: `battery-calibration-logger.py`, `battery-auto-calibrator.py`, `fix-ocv-table.py`

---

## UPower KDE Fix

On **KDE Plasma Mobile**, the battery indicator may show "Discharging" even while plugged in and charging. This is caused by a bug in UPower (all versions since ~0.99.x) where it overrides the battery state to `Discharging` whenever `current_now < 0` in sysfs — contradicting the actual `status` attribute.

The BQ25895 driver follows the Linux `power_supply` convention where **negative current = charging**. The fix rebuilds UPower from source with this override disabled.

**Applied automatically** by `install.sh --install battery` or `install.sh --fix-upower`. After installation, log out and back in (or reboot) for the change to propagate to the KDE battery indicator.

To apply manually on a running system:

```bash
sudo bash ./install.sh --install upower
```

To verify after install:

```bash
upower -i /org/freedesktop/UPower/devices/battery_battery | grep state
# should show: state:               charging
```

If the KDE indicator still shows "Discharging" immediately after the fix, the KDE session needs to be restarted (`sudo systemctl restart plasma-mobile` or reboot).

---

## Buttons

The GPIO button daemon lives under `button-service/` and is installed by `install.sh`.

### GPIO Wiring

| Line | Chip | Offset | Role |
|------|------|--------|------|
| Press | `gpiochip0` | 23 | Shared interrupt (pull-up, active low) |
| Select | `gpiochip10` | 20 | Distinguishes power vs user while held |

Measured levels on PocketCM5:

| State | Press (23) | Select (20) |
|-------|------------|-------------|
| Idle | 0 | 1 |
| User held | 1 | 0 |
| Power held | 0 | 0 |

Power does **not** pull line 23 low; only the user button does. The daemon decodes `press == 0 && select == 0` as power and `press == 1 && select == 0` as user.

### Default Button Actions

| Gesture | Action |
|---------|--------|
| **User short** | Toggle display (`display-on-off.sh`) |
| **User long** | Empty stub (customize `user-long.sh`) |
| **Power short** | Native desktop power menu (GNOME, KDE, XFCE, Pi OS `pishutdown`, …) |
| **Power long** | Hold `KEY_POWER` for 2 s, release on button up (Pi-style shutdown) |

### Daemon Implementation

- **libgpiod v2** C API with persistent line requests.
- Long-press threshold **2000 ms** (`LONG_PRESS_MS`); settle + release debounce + identity sampling.
- Logs to `syslog` / `journalctl -u pibrickbtn`; `--test` mode prints live GPIO levels.
- Unloads `gpio_keys` at startup; leaves the touch module alone.
- Built with `-lgpiod` (`install.sh` installs `libgpiod-dev`).
- systemd unit: `Restart=on-failure`, `Before=graphical.target`.
- Display-toggle sysfs write is enabled for the user by `99-pibrick-display.rules` (driver attr stays `0644`).

### Action Scripts

| Script | Role |
|--------|------|
| `display-on-off.sh` | Toggle panel; safe `find` with clear errors for missing node / permission denied |
| `brightness.sh` | Legacy wrapper → `pibrick-brightness up` |
| `pibrick-brightness` | Backlight up/down for labwc / Pi OS Trixie (`XF86MonBrightness*` keys) |
| `run-as-session-user.sh` | Run GUI commands as the logged-in desktop user (`loginctl` + `/run/user` fallback, `runuser` / `su`) |
| `power-menu.sh` | DE-aware power menu (GNOME, XFCE, Pi OS `pishutdown`; KDE/MATE/LXQt fallbacks) |

### Power Menu

Power short press runs `power-short.sh` → `run-as-session-user.sh` → `power-menu.sh` in the active graphical session.

| Desktop | Handler | Status |
|---------|---------|--------|
| **GNOME** (48) | `KEY_POWER` uinput tap from `pibrickbtn` (same as hardware power key) | Tested |
| **XFCE** | `xfce4-session-logout` | Supported |
| **Pi OS / labwc** | `pishutdown` | Tested |

On **GNOME 48**, the native power menu is triggered by a brief `KEY_POWER` pulse from `pibrickbtn` via uinput — the same path as a laptop power key. `power-menu.sh` is a no-op when the session bus shows `org.gnome.Shell`; opening a second D-Bus shutdown dialog (`EndSessionDialog`) conflicts with GNOME and leaves a stuck blur overlay.

Additional fallbacks (best-effort): KDE Plasma (`org.kde.LogoutPrompt`), MATE (`mate-session-save`), LXQt (`lxqt-leave`), and a simulated `XF86PowerOff` (`wtype` / `xdotool`).

Detection order:

1. Live session D-Bus (`org.gnome.Shell`, `org.kde.LogoutPrompt`) — beats a stale `XDG_CURRENT_DESKTOP` (Pi images may still export `LABWC` while GNOME runs)
2. `XDG_CURRENT_DESKTOP` name matching
3. Per-DE generic fallbacks, then simulated `XF86PowerOff`
4. `pishutdown` only when GNOME/KDE are not on the session bus

Test from a root shell (manual fallback only — the physical button is preferred on GNOME):

```bash
sudo bash /etc/pibrick/power-short.sh
```

---

## Sysfs Interfaces (Quick Reference)

| Node | Purpose |
|------|---------|
| `/sys/class/backlight/pibrick-backlight/brightness` | Backlight 0–1023 |
| `…/pibrick_display_enable` (under DSI device) | Display on/off (`0` / `1`) |
| `…/color_profile` | `natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft` (9203 only) |
| `/sys/class/power_supply/battery/` | Capacity, voltage, charging state (BQ25895 driver + INA228) |
| `/sys/class/power_supply/battery/ina228_*` | INA228 precise measurements |

### Display Settings Menu

```bash
pibrick-display-settings
```

Interactive menu for:

- **Color profile** — sysfs `color_profile` (9203 only)
- **Refresh rate** — 90 Hz default @ 1080×1240 on 9203; 60 Hz optional. The 5.48 inch panel is 60 Hz only.

Refresh-rate backend is chosen automatically:

| Desktop | Backend | Status |
|---------|--------|--------|
| **GNOME Wayland** (48) | `tools/gnome-display-rate.py` via `org.gnome.Mutter.DisplayConfig` (`python3-dbus`, else `gdbus`) | Tested |
| **Pi OS / labwc** | `wlr-randr` (rate embedded in mode, e.g. `1080x1240@90Hz`) | Supported |
| **XFCE / X11** | `xrandr` (current rate marked with `*`) | Supported |

Color profile is pure sysfs and works on every desktop. If no backend can drive the panel, the menu still reports the rate read from `/sys/class/drm/.../modes` but cannot change it.

Non-interactive:

```bash
pibrick-display-settings --profile soft
pibrick-display-settings --refresh 60
pibrick-display-settings --status
```

Low-level GNOME helper (also works over SSH when a graphical session is active):

```bash
python3 /usr/lib/pibrick/tools/gnome-display-rate.py get
python3 /usr/lib/pibrick/tools/gnome-display-rate.py set 90
python3 /usr/lib/pibrick/tools/gnome-display-rate.py debug
```

Installed by `desktop/setup-desktop.sh`:

- `/usr/local/bin/pibrick-display-settings`
- `/usr/local/bin/pibrick-touch-reset`
- `/usr/lib/pibrick/tools/gnome-display-rate.py`

Dependencies: `python3-gi`, `python3-dbus` (installed by `setup-desktop.sh` when missing).

---

## Touch Troubleshooting

Touch is driven by `hyn_ts` and follows panel power via the mainline `drm_panel_follower` API.

**Quick recovery (no rebuild):**

```bash
pibrick-touch-reset
```

This turns the panel on if needed, then sends `rst` to the driver's `hyntpdbg` sysfs node (full resume when suspended, hardware reset otherwise).

**After updating drivers**, rebuild and reload touch:

```bash
sudo bash ./install.sh
# or: cd /usr/lib/pibrick/hyn_driver_release_qm && sudo make touch install
sudo modprobe -r hyn_ts && sudo modprobe hyn_ts
```

**Diagnostics on the device:**

```bash
lsmod | grep -E 'hyn_ts|gpio_keys'
dmesg | tail -50 | grep -iE 'hyn|touch|cst66'
find /sys/bus/i2c/devices -name hyntpdbg
libinput list-devices | grep -i touch
```

If the panel never registers a follower (older kernel without `CONFIG_DRM_PANEL`), touch falls back to `dev_pm_ops` and stays active whenever the system is awake. For a stuck session without rebuilding, use `pibrick-touch-reset`.

---

## Customizing Buttons

Edit scripts under `/etc/pibrick/` (copied from `button-service/etc/pibrick/`):

| Hook | Default |
|------|---------|
| `user-short.sh` | Display on/off |
| `user-long.sh` | No-op (add your command) |
| `power-short.sh` | Desktop power menu (`power-menu.sh`) |
| Power long | Handled in `pibrickbtn.c` (uinput `KEY_POWER` hold) |

After changes: `sudo systemctl restart pibrickbtn`

GPIO test without the daemon:

```bash
sudo systemctl stop pibrickbtn
sudo /usr/local/bin/pibrickbtn --test
```

---

## Legacy Panels

**9202**, **5.48 inch** (`548`), and **5 inch** (`5inch`) drivers and matching DTS overlays live alongside the default **9203** sources. Select the panel during `install.sh` or with `PANEL=`; the choice is saved to `/etc/pibrick.panel`.

Note: the **548** overlay uses an FocalTech touch controller (`edt-ft5406`); the default **9203** / **9202** / **5 inch** overlays use Hynitron CST66xx (`hyn,66xx`). Re-run install after switching panel so the correct overlay and touch driver are built.

---

## Credits

Display, touch, and battery kernel code originates from **Ahmad Amarullah** ([amarullz.com](https://amarullz.com)). The panel selection, kernel 6.18 modernization, touch panel-follower port, INA228 integration, battery calibration system, button service, desktop indicator, and PocketCM5-specific fixes in this tree are community maintenance on top of those originals.
