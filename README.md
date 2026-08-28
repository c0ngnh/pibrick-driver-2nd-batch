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
| Autorotation | `autorotation-service/` | MMA8451Q accelerometer-based automatic screen rotation |
| Plasma Mobile | `install.sh` | KWin black-Recent/fix (kde-mobile-desktop) + charging state (upower) on Pi V3D |
| Extras | `extras/` | Optional install components (Phosh-on-Pi5 libwlroots fix, Oh My Zsh setup) |

This repository bundles the display, touch, battery, button, and desktop pieces into a single installable tree, targeting **Raspberry Pi OS on kernel 6.18** with **GNOME 48 (Wayland)** or **KDE Plasma Mobile**.

## Install

The installer always installs **system-wide** (under `/usr/lib/pibrick/`).
It requires `sudo` because it builds kernel modules, writes to `/etc/modprobe.d/`,
and reloads drivers. There is no per-user mode.

```bash
git clone https://github.com/c0ngnh/pibrick-driver-2nd-batch.git
cd pibrick-driver-2nd-batch
sudo bash ./install.sh
```

The interactive menu lets you pick which components to install. The default
selects everything (display, battery, calibration, button service).

UPower KDE Fix and Plasma Mobile KWin Fix require KDE Plasma to be installed.
Install KDE first, then the fixes:

```bash
sudo pibrick-tools --install kde-mobile-desktop  # Install + enable KDE Plasma + SDDM
sudo pibrick-tools --install upower       # UPower charging state fix
sudo pibrick-tools --install plasma-mobile-black-recent-fix  # KWin black-screen fix
```

**Only one display panel is installed at a time.** When you opt into the
display category, the installer prompts for a single panel variant
(`9203`, `9202`, `548`, or `5inch`) and the Makefile builds + installs
exactly one `panel-pibrick.ko` plus one overlay (`vc4-kms-dsi-pibrick`,
`vc-548inch`, or `vc4-5inch`). The `install` target's `remove` step
scrubs all known overlays from `/boot/firmware/overlays` and strips any
stale `dtoverlay=…` lines from `config.txt` before writing the new
overlay, so switching panels between installs is safe. The chosen
panel is persisted in `/etc/pibrick.panel` so subsequent `pibrick-tools`
operations (rebuilds, calibration rebuilds) reuse it.

After install finishes, a global `pibrick-tools` command is available in
`/usr/local/bin/`. From now on, you manage everything with that one command —
no need to remember paths under `/usr/lib/pibrick/`:

```bash
sudo pibrick-tools --battery-status          # Show all params + persisted config
sudo pibrick-tools --battery-config          # Interactive parameter setter
sudo pibrick-tools --battery-config charge_full_uah 4800 mAh --persist
sudo pibrick-tools --status-calibration      # Calibration status / confidence
sudo pibrick-tools --enable-calibration      # Start logging
sudo pibrick-tools --disable-calibration     # Stop logging
sudo pibrick-tools --apply-calibration       # Apply calibrated OCV table
sudo pibrick-tools --check                   # Re-analyze CSV → refresh status JSON
sudo pibrick-tools --install <component>     # Add another component later
sudo pibrick-tools --autorotation-lock left   # Lock to landscape-left
sudo pibrick-tools --autorotation-unlock     # Resume auto-rotation
sudo pibrick-tools --autorotation-status     # Show autorotation status
sudo pibrick-tools --help                    # Full command reference
```

The `--install` flag takes any combination of components:

```bash
sudo pibrick-tools --install all                # Core components (display, battery-new, calibration, button)
sudo pibrick-tools --install display            # Display + touch (uses saved panel or defaults to 9203)
sudo pibrick-tools --install battery-new        # Battery driver (bq25895 + INA228 auto-detect)
sudo pibrick-tools --install calibration        # Calibration logger + auto-calibrator
sudo pibrick-tools --install upower             # UPower KDE charging-state fix
sudo pibrick-tools --install button             # GPIO button service
sudo pibrick-tools --install autorotation       # MMA8451Q accelerometer autorotation
sudo pibrick-tools --install kde-mobile-desktop         # Install + enable KDE Plasma + SDDM (run first)
sudo pibrick-tools --install plasma-mobile-black-recent-fix      # KWin black-screen fix (requires kde-mobile-desktop)
sudo pibrick-tools --install battery-new,calibration   # Comma-separated, multiple at once
```

### Uninstall

To reverse an install, run the uninstaller with the same component name(s)
you originally installed. It must be run as root (sudo). Before any action it
prints a list of what will be removed and asks you to type `YES` exactly —
this guard runs even in non-interactive mode, so an accidental
`sudo pibrick-tools --uninstall all` from a misconfigured cron job is safe.

```bash
# Remove a single component
sudo pibrick-tools --uninstall display
sudo pibrick-tools --uninstall battery
sudo pibrick-tools --uninstall calibration
sudo pibrick-tools --uninstall upower
sudo pibrick-tools --uninstall button
sudo pibrick-tools --uninstall autorotation
sudo pibrick-tools --uninstall kde-mobile-desktop
sudo pibrick-tools --uninstall plasma-mobile-black-recent-fix
sudo pibrick-tools --uninstall wrapper

# Remove several components at once (comma-separated, same as --install)
sudo pibrick-tools --uninstall display,battery,calibration

# Remove everything that pibrick-tools has installed on this system
sudo pibrick-tools --uninstall all
```

Components are removed in dependency order regardless of the order you
type: `calibration` → `battery` → `display` → `upower` → `kde-mobile-desktop` →
`plasma-mobile-black-recent-fix` → `button` → `autorotation` → `wrapper`. The UPower fix is restored from the most recent
`/usr/libexec/upowerd.bak-pibrick-*` (beside whichever binary was detected) backup (created at install time), so
the stock UPower from your distro comes back. If no backup exists the
patched binary is left in place and you'll be told to run
`sudo apt reinstall upower`.

After uninstalling the display or battery driver, **reboot** for the
kernel to forget the unloaded module (the uninstaller only stops services,
unloads the module if it isn't busy, and removes the `.ko` file). A
`success "Uninstall complete. A reboot is recommended."` message at the
end of the run is your cue.

**Files the uninstaller touches per component:**

| Component | What it removes |
|---|---|
| `display` | `pibrick.service`, `/lib/modules/<kernel>/kernel/drivers/gpu/drm/panel/panel-pibrick.ko`, all three known overlays, `dtoverlay=…` lines in `/boot/firmware/config.txt`, `/etc/pibrick.panel`, `/etc/pibrick.display-refresh`, `/etc/udev/rules.d/99-pibrick-display.rules` |
| `battery` | `bq25890_battery.ko`, `/etc/modprobe.d/pibrick-battery.conf`, `/var/lib/bq25890_battery/soc_persist`, `/etc/cron.d/pibrick-battery-soc`, `pibrick-battery-{load-soc,soc-persist,apply-modprobe}.service` units, `/usr/lib/pibrick/battery/pibrick-battery-load-soc.sh`, `/usr/lib/pibrick/battery/pibrick-battery-apply-modprobe.sh`. `pibrick-battery-calibration.service` is removed by the `calibration` component |
| `calibration` | `pibrick-battery-calibration.service`, the entire `/var/log/bq25890_battery/` directory (CSV, logs, `suggested_ocv_table.h`, `calibration_status.json`), `battery-calibration-logger.py`, `battery-auto-calibrator.py`. `battery_set.py` / `battery-soc-persist.py` are **kept** as they are useful diagnostics even with no driver loaded |
| `upower` | Restores `/usr/libexec/upowerd` from the most recent `.bak-pibrick-*` backup |
| `kde-mobile-desktop` | SDDM config, `/etc/sddm.conf.d/kde-plasma-mobile.conf`, KWin drop-ins; `kde-standard`/`sddm` packages left in place |
| `button` | `pibrickbtn.service`, `/usr/local/bin/pibrickbtn`, `/etc/pibrick/` |
| `wrapper` | `/usr/local/bin/pibrick-tools`, bash completion files |

> **Note.** The uninstaller removes individual files it installed inside `/usr/lib/pibrick/` (e.g. the battery helpers, autorotation service) but leaves the tree itself intact. The tree is regenerated on every `--install` run, and keeping it around lets you re-run the installer without first cloning the repo. To remove it, run `sudo rm -rf /usr/lib/pibrick` manually.

Each panel has its **matching touch driver**:
- **9203 / 9202 / 5inch** → Hynitron CST66xx (`hyn,66xx`)
- **548** (5.48 inch) → FocalTech (`edt-ft5406`)

### Panel Selection

`install.sh` prompts for the panel variant and saves the choice to `/etc/pibrick.panel`. You can also pick it non-interactively:

```bash
sudo PANEL=9203  bash ./install.sh   # SD5302H (90/60 Hz, 90 Hz default)
sudo PANEL=9202  bash ./install.sh   # legacy 1080×1240 @ 60 Hz
sudo PANEL=548   bash ./install.sh   # 5.48 inch 1080×1920 @ 60 Hz (FocalTech)
sudo PANEL=5inch bash ./install.sh   # 5 inch 1080×1240 @ 90/60 Hz
```

The default refresh rate is **90 Hz** for the 9203 panel (saved to `/etc/pibrick.display-refresh` and applied on login). Use `pibrick-display-settings --refresh 60` for lower power.

### Install Layout

The installer always installs to **system-wide** locations:

| Path | Contents |
|------|----------|
| `/usr/lib/pibrick/` | Source tree: kernel modules, Python helpers, service files |
| `/usr/lib/pibrick/battery/` | Battery Python helpers (`battery_set.py`, `battery-auto-calibrator.py`, ...) |
| `/usr/local/bin/pibrick-tools` | Global wrapper — `pibrick-tools` from any directory |
| `/etc/modprobe.d/pibrick-battery.conf` | Battery driver parameters persisted across reboots |
| `/etc/systemd/system/pibrick-battery-*.service` | Battery services (load-SOC, persist-SOC, calibration) |

The wrapper at `/usr/local/bin/pibrick-tools` is a thin shim that forwards
every argument to `/usr/lib/pibrick/install.sh`. You never need to call
`install.sh` directly — `sudo pibrick-tools <command>` always works.

**Persistent override** (system-wide): Create `/etc/pibrick.conf` with:

```bash
# /etc/pibrick.conf
PIBRICK_USER_HOME=/home/alice/battery
```

When `sudo` runs `install.sh`, `$HOME` becomes `/root`. The installer detects
this via `$SUDO_USER` and uses the **original user's home** so per-user installs
still work as expected.

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

Use `sudo pibrick-tools` for everything — the global wrapper installed
by `sudo bash ./install.sh` lets you forget about paths.

```bash
# Step 1: Enable logging (collects data continuously in background)
sudo pibrick-tools --enable-calibration

# Step 2: Let it collect data (use your device normally for 1-2 days)
# - Resting measurements are automatically selected
# - At least 1000 samples recommended for accurate calibration

# Step 3: Check status and confidence level
sudo pibrick-tools --status-calibration
# Look for "Confidence: 0.97 (97%)" - higher is better
# Need at least 85% confidence to apply

# Step 4: Apply the calibrated OCV table to driver (only when ready)
sudo pibrick-tools --apply-calibration

# Step 5: Driver will be rebuilt and reloaded automatically
```

#### Command Reference

| Command | What it does |
|---------|--------------|
| `--enable-calibration` | **Starts logging service** - only collects data, does NOT modify driver |
| `--disable-calibration` | **Stops logging service** - data is preserved |
| `--status-calibration` | Shows data stats, confidence level, sample count |
| `--apply-calibration` | **Applies calibrated OCV table** - rebuilds driver. Accepts `--yes`, `--no-rebuild`, `--no-ina228` (see [Calibration section](#automatic-battery-calibration)). |

**Important**: `--enable-calibration` only starts the data collection service. It does NOT automatically apply anything to the driver. You must manually run `--apply-calibration` when you have enough data.

#### Calibrating Without INA228 Hardware

If your PocketCM5 board does **not** have the TI INA228 high-precision current
sensor installed, the driver falls back to a load-aware proxy integrator. The
proxy reads the BQ25895's internal current sense, which is noisier than INA228.
This affects calibration as follows:

- The driver auto-detects the missing INA228 at probe time and **doubles the
  OCV tracker time constant** from 60 s to 120 s (`fg_v_ocv_tau_sec`). A
  slower tracker gives smoother `v_ocv_uv` readings, which the auto-calibrator
  relies on for bucketing samples by SOC. You will see this in `dmesg`:
  `No INA228 detected: OCV tracker tau bumped to 120 s`.
- The auto-calibrator accepts a `--no-ina228` flag that lowers its internal
  thresholds and applies stricter sample filtering (see below).
- Because each resting-state sample is noisier, you typically need **2-3 full
  charge cycles** to accumulate enough clean samples, versus **1 cycle** when
  INA228 is present.

```bash
# 1. Enable logging as usual
sudo pibrick-tools --enable-calibration

# 2. Use the device normally through 2-3 full charge cycles
#    (one charge cycle = drain to ~10 % then full charge to 100 %).
#    Each cycle adds a few hundred clean resting samples.

# 3. Check status. With --no-ina228 the threshold drops to 70 % and
#    min samples per bucket drops to 2.
sudo pibrick-tools --status-calibration
#    Or directly:
sudo pibrick-tools --check --no-ina228

# 4. Apply the calibrated OCV table
sudo pibrick-tools --apply-calibration --yes
```

What `--no-ina228` changes internally:

| Setting | With INA228 | Without INA228 (`--no-ina228`) |
|---------|-------------|--------------------------------|
| `MIN_SAMPLES_PER_BUCKET` | 3 | **2** |
| `MIN_TOTAL_SAMPLES` | 15 | **30** |
| `CONFIDENCE_THRESHOLD` | 0.85 | **0.70** |
| Sample filter | `fg_mode == "resting"` and not charging | `fg_mode == "resting"` only (stricter) |
| Current filter | none | **\|current_now\| ≤ 10 mA** |
| Bucket std-dev filter | none (any spread) | **std-dev ≤ 30 mV** |
| OCV tracker tau (`fg_v_ocv_tau_sec`) | 60 s (compile-time) | **120 s** (auto-detected at probe) |
| Charge cycles needed | 1 | **2-3** |

The current filter (`|current_now| ≤ 10 mA`) only matters at boot for
admission, not for the final OCV value. A truly idle PocketCM5 with the
screen off draws < 5 mA from the BQ25895, so the filter rejects samples
captured during user activity (which are noisy and would skew the bucket).
The std-dev filter on each bucket rejects samples where the OCV tracker
was still settling after a load spike.

If you want a different OCV tracker time constant than the auto-detected
value (e.g. you have INA228 but want slower convergence), you can force it
in `/etc/modprobe.d/pibrick-battery.conf`:

```
options bq25890_battery fg_v_ocv_tau_sec_override=90
```

The auto-detect only applies when `fg_v_ocv_tau_sec_override` is left at -1
(the default).

#### Manual Calibration Tools

`pibrick-tools` is the recommended way to drive calibration. If you need
direct access to the Python helpers (e.g. for scripting), they live under
`/usr/lib/pibrick/battery/`:

```bash
# Direct call to the auto-calibrator (system-wide install)
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --status

# Same, via the wrapper:
sudo pibrick-tools --status-calibration

# Generate OCV table from existing data (dry run - shows what would be applied)
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --check

# Apply the OCV table to the driver (works with both INA228 and non-INA228 builds)
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --apply

# Without INA228 (uses the stricter thresholds and filters described above):
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --check --no-ina228
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --apply --no-ina228 --yes
```

**Note**: The `--apply-calibration` step works correctly **regardless of whether INA228 is present**. The OCV table affects the driver's voltage-to-SOC lookup, which is independent of the INA228 current sensor. The calibration data uses BQ25895's `voltage_now` (always available) — INA228 is only used for more accurate current measurements during data collection.

### Battery Driver Customization

The battery driver exposes 10+ module parameters (battery capacity, INA228 shunt, discharge profiles, etc.). You can read and modify them via `sudo pibrick-tools`.

#### Show Current Status & Persisted Config

```bash
sudo pibrick-tools --battery-status
```

This shows:
- Current driver values (live, from sysfs / module parameters)
- Values persisted to `/etc/modprobe.d/pibrick-battery.conf` (survive reboot)
- Driver compile-time defaults (for reference)
- Quick SOC readout from power_supply

#### Interactive Configuration (recommended for first-time setup)

```bash
sudo pibrick-tools --battery-config
```

This launches the **interactive setter** which lets you:
- Choose any of the 10 parameters to view/edit
- See current value, driver default, units
- Get warned about persistence behavior
- Choose to persist (and reload driver) or just set live

#### Non-Interactive Configuration

Set a single value directly:

```bash
# Set battery capacity to 4800 mAh (non-persistent, until reboot)
sudo pibrick-tools --battery-config charge_full_uah 4800

# Set and persist (saves to /etc/modprobe.d/ + reloads driver)
sudo pibrick-tools --battery-config charge_full_uah 4800mAh --persist

# Set INA228 shunt for 15 mΩ resistor, persist it
sudo pibrick-tools --battery-config ina228_shunt_uohm 15mΩ --persist

# Set fuel-gauge discharge profile (700 mA idle, 40% under load, 4000 mA ceiling)
sudo pibrick-tools --battery-config discharge_avg_ua 700mA --persist
sudo pibrick-tools --battery-config discharge_load_factor_pct 40 --persist
sudo pibrick-tools --battery-config discharge_max_ua 4000mA --persist

# Show all values
sudo pibrick-tools --battery-config --show

# List all parameters
sudo pibrick-tools --battery-config --list
```

#### Available Battery Parameters

| Parameter | Unit | Default | Purpose |
|-----------|------|---------|---------|
| `charge_full_uah` | mAh | 4800 | Battery design capacity (e.g. 4800 for 4800 mAh pack) |
| `ina228_shunt_uohm` | mΩ | 15 | INA228 shunt resistor value (must match hardware) |
| `ina228_max_current_ua` | mA | 6400 | INA228 max current range |
| `ina228_enabled` | bool | 1 | Use INA228 when present; set 0 to force proxy |
| `discharge_current_ua` | mA | 900 | Assumed avg discharge (for time-to-empty) |
| `batt_ir_mohm` | mΩ | 180 | Battery internal resistance (charge-time OCV estimate) |
| `discharge_avg_ua` | mA | 700 | Nominal idle discharge (set 0 to disable) |
| `discharge_load_factor_pct` | % | 40 | Extra % added under sustained load |
| `discharge_max_ua` | mA | 4000 | Hard ceiling for SOC integrator proxy current |
| `rest_min_sec` | s | 300 | Seconds of quiet required for DISCHARGING_RESTING |
| `low_v_persistent_count` | samples | 5 | Consecutive low-V samples before SOC→critical |
| `fg_v_ocv_tau_sec_override` | s | -1 | OCV tracker time constant. -1 = auto (60 with INA228, 120 without). Use 60-180. |
| `coulomb_uah` | uAh | — | **LIVE** — remaining capacity; fuel gauge overwrites |

#### Persistence Behavior

| Flag | What it does |
|------|--------------|
| *(none)* | Set value LIVE only. Resets on driver reload/reboot. |
| `--persist` | Save to `/etc/modprobe.d/pibrick-battery.conf` **AND** automatically reload driver so value takes effect immediately. Survives reboot. |
| `--force` | Bypass safety checks (for `coulomb_uah` writes below 10% capacity — DANGEROUS, can trigger UPower shutdown). |

**Important**: `--persist` makes the change survive reboot. Without it, the change is "live" — visible immediately but lost on next driver reload or reboot.

#### Why `--persist` Needs the `pibrick-battery-apply-modprobe.service`

The `bq25890_battery` module is auto-loaded by udev-trigger the moment the I2C client device appears, which happens **before** `systemd-modules-load.service` has a chance to consult `/etc/modprobe.d`. This means module parameters specified in `/etc/modprobe.d/pibrick-battery.conf` are silently ignored at boot — every persisted value (e.g. `charge_full_uah`) reverts to its in-kernel default.

To bridge the gap, the installer ships `pibrick-battery-apply-modprobe.service` (enabled by default). At boot it waits for `/sys/module/bq25890_battery/parameters/` to exist, then writes each persisted `name=value` pair from `/etc/modprobe.d/pibrick-battery.conf` to the corresponding sysfs node. This is race-free (no `rmmod`/`modprobe` reload, which would break `pibrick-battery-load-soc.sh` and was the root cause of earlier 0%-after-boot failures) and idempotent (safe to run multiple times).

```bash
# Manual check after a config change
sudo systemctl status pibrick-battery-apply-modprobe.service
sudo journalctl -u pibrick-battery-apply-modprobe.service
# Direct invocation (after driver is loaded):
sudo /usr/lib/pibrick/battery/pibrick-battery-apply-modprobe.sh
```

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

- **Display Driver Selection**: Choose between new (bq25895 + INA228 auto-detect) or original (bq25895 only, no INA228) battery driver. Both use the same panel drivers.
- **Battery Driver**: Full battery fuel gauge with INA228 integration
- **Calibration Tools**: Automatic voltage-SOC data collection and OCV table generation
- **UPower KDE Fix**: Correct charging state display in KDE Plasma Mobile
- **Button Service**: GPIO-based power and user button handling

#### Installation Options

| Option | Description |
|--------|-------------|
| `--install all` | Install core components (display, battery-new, calibration, button) |
| `--install display` | Display + touch (uses saved panel or defaults to 9203) |
| `--install display-hyn` | Display with Hynitron CST66xx touch (no INA228 dependency) |
| `--install battery` | Battery driver (bq25895 + INA228, alias for battery-new) |
| `--install calibration` | Calibration logger + auto-calibrator |
| `--install upower` | UPower KDE charging-state fix |
| `--install button` | Button service |
| `--install autorotation` | MMA8451Q accelerometer autorotation |
| `--install phosh-pi5` | libwlroots-0.18 fix for Phosh on Pi 5 (refuses to install on non-Phosh systems) |
| `--install zsh` | Oh My Zsh + Powerlevel10k for the active user |
| `--enable-calibration` | Start calibration logging |
| `--disable-calibration` | Stop calibration logging |
| `--apply-calibration` | Apply calibrated OCV table |
| `--status-calibration` | Show calibration status |
| `--check` | Re-analyze CSV → refresh status JSON |
| `--install kde-mobile-desktop` | Install + enable SDDM as default display manager; sets Plasma Mobile as default session |
| `--install plasma-mobile-black-recent-fix` | Apply KWin black-screen fix (requires kde-mobile-desktop) |
| `--autorotation-lock [n]` | Lock rotation to normal\|left\|right\|inverted |
| `--autorotation-unlock` | Resume auto-rotation |
| `--autorotation-status` | Show autorotation service status |
| `--uninstall <component>` | Remove one component — requires typed `YES` |
| `--uninstall all` | Remove everything — requires typed `YES` |

> **Uninstall safety.** `--uninstall` requires root and always prompts
> for a typed `YES` before doing anything, even in non-interactive mode.
> See the [Uninstall](#uninstall) section above for what each component
> removes and the dependency order it uses.

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
| `postprocess-ocv-table.py` | Post-process calibrator's `suggested_ocv_table.h` into a clean, monotonic driver table |
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

4. **Application**: The calibrated OCV table is applied to the driver for accurate SOC estimation. Run `sudo pibrick-tools --apply-calibration --yes` once the confidence threshold is met — the wrapper takes a confirmation (`y` or `yes`), patches the driver source with the new ascending-order table, rebuilds the module, and reloads it. See [`pibrick-tools --apply-calibration` flags](#pibrick-tools---apply-calibration-flags) for the supported flags.

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
# Check calibration status (preferred — uses the wrapper)
sudo pibrick-tools --status-calibration

# Same, direct call to the auto-calibrator:
sudo python3 /usr/lib/pibrick/battery/battery-auto-calibrator.py --status

# Analyze existing data
sudo pibrick-tools --apply-calibration --no-rebuild   # dry run, just analyze

# Generate OCV table from data
sudo python3 /usr/lib/pibrick/battery/battery-calibration-logger.py --generate-ocv-table

# Apply the calibrated OCV table (rebuilds + reloads driver)
sudo pibrick-tools --apply-calibration
```

#### `pibrick-tools --apply-calibration` flags

The wrapper passes these flags through to `battery-auto-calibrator.py`:

| Flag | Effect |
|------|--------|
| `--yes`, `-y` | Skip the `Continue? (yes/no):` confirmation prompt. Implied automatically when no TTY is attached (e.g. running from a script or CI). When the prompt is shown it accepts `y`, `Y`, `yes`, or `YES`. |
| `--no-rebuild` | Patch the driver source but skip the `make` + `modprobe` step. Useful to preview the new table without rebooting or disrupting the live module. |

#### `pibrick-tools --check` flags

| Flag | Effect |
|------|--------|
| `--no-ina228` | Tighten the sample filter for boards without the TI INA228 sensor (restricts `fg_mode` to resting, `|current_now| ≤ 10 mA`, lowers min samples per bucket). |

Examples:

```bash
# Non-interactive apply (e.g. from a script or CI)
sudo pibrick-tools --apply-calibration --yes

# Preview the new table without rebuilding/reloading
sudo pibrick-tools --apply-calibration --no-rebuild --yes

# No INA228 board: run analysis with no-INA228 thresholds first
sudo pibrick-tools --check --no-ina228
```

> **Note on table ordering.** The driver's `bq25890_calc_lipo_percentage()`
> walks the OCV table with `v[i] ≤ voltage < v[i+1]` and assumes `v[0]`
> is the lowest voltage (= 0 %) and `v[last]` is the highest (= 100 %).
> `update-ocv-table.py` always emits the table in this **ascending** order.
> If you ever hand-edit `voltage_to_percent_table` in `bq25890_battery.c`,
> keep it strictly ascending — a descending table will silently force
> SOC = 0 % for almost every voltage (this was the root cause of an
> earlier "always shows 0 %" regression).

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

- `tools/pibrick-display-settings.sh`, `tools/gnome-display-rate.py`, `tools/ocv-calibrate.py`.
- Calibration tools: `battery-calibration-logger.py`, `battery-auto-calibrator.py`, `update-ocv-table.py`

---

## UPower KDE Fix

On **KDE Plasma Mobile**, the battery indicator may show "Discharging" even while plugged in and charging. This is caused by a bug in UPower (all versions since ~0.99.x) where it ignores the battery `status` attribute and forces `Discharging` whenever `current_now < 0` in sysfs — the BQ25895 driver uses the standard `power_supply` convention where negative current means the battery is accepting charge.

The fix rebuilds UPower from source with this override disabled.

**Requires KDE Plasma to be installed first.** Apply after `sudo pibrick-tools --install kde-mobile-desktop`.

```bash
sudo pibrick-tools --install kde-mobile-desktop  # Install + enable KDE first
sudo pibrick-tools --install upower
```

To verify after install:

```bash
upower -i /org/freedesktop/UPower/devices/battery_battery | grep state
# should show: state:               charging
```

If the KDE indicator still shows "Discharging" immediately after the fix, the KDE session needs to be restarted (`sudo systemctl restart plasma-mobile.target` or reboot).

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
| **User long** | Brightness up (`pibrick-brightness up`; customize `user-long.sh`) |
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
| `user-long.sh` | Brightness up (`pibrick-brightness up` by default; customize here) |
| `power-short.sh` | Desktop power menu (`power-menu.sh`) |
| Power long | Handled in `pibrickbtn.c` (uinput `KEY_POWER` hold) |

After changes: `sudo systemctl restart pibrickbtn`

GPIO test without the daemon:

```bash
sudo systemctl stop pibrickbtn
sudo /usr/local/bin/pibrickbtn --test
```

---

## Plasma Mobile KWin Fix

Fixes black screen when opening Recent / task switcher on KDE Plasma Mobile running on Raspberry Pi (Pi 4/5/500+) with the V3D GPU driver. See [KDE bug 519099](https://bugs.kde.org/show_bug.cgi?id=519099).

### Root Cause

KWin effects (mobiletaskswitcher, overview, tiling) fail when using desktop OpenGL on Pi. The fix forces KWin to use **OpenGL ES 2.0** via `KWIN_COMPOSE=O2ES`.

### Installation

**Requires KDE Plasma to be installed first** (`--install kde-mobile-desktop`).

```bash
sudo pibrick-tools --install kde-mobile-desktop    # Step 1: install + enable KDE Plasma + SDDM
sudo pibrick-tools --install plasma-mobile-black-recent-fix  # Step 2: apply the KWin fix

# With Zink GPU fallback (higher CPU usage, only if KWin still fails):
ZINK_FALLBACK=1 sudo pibrick-tools --install kde-mobile-desktop
```

### What it does

1. **kde-mobile-desktop** (`--install kde-mobile-desktop`):
   - Installs `plasma-mobile`, `kde-standard`, and `sddm` if missing (with confirmation prompt; auto-installs in non-interactive mode).
   - Enables SDDM and sets `graphical.target`.
   - Writes the KWin drop-in for the black-recent-screen fix.

2. **plasma-mobile-black-recent-fix** (`--install plasma-mobile-black-recent-fix`):
   - Re-applies the KWin drop-in. Only applies when KDE Plasma is already installed; otherwise prints a clear error directing to `--install kde-mobile-desktop`.

KWin drop-in at `~/.config/systemd/user/plasma-kwin_wayland.service.d/pi-kwin-recent-fix.conf`:

```
KWIN_DRM_USE_MODIFIERS=0
KWIN_COMPOSE=O2ES
KWIN_PERSISTENT_VBO=1
KWIN_RENDER_BACKEND=gles
KWIN_OPENGL_INTERFACE=egl
```

### Uninstall

```bash
sudo pibrick-tools --uninstall kde-mobile-desktop   # Remove KDE desktop setup (packages untouched)
```

### Zink Fallback

If OpenGL ES alone doesn't fix the issue, enable Zink (software Vulkan via Mesa):

```bash
ZINK_FALLBACK=1 sudo pibrick-tools --install kde-mobile-desktop
```

This adds `MESA_LOADER_DRIVER_OVERRIDE=zink` to a second drop-in. It has higher CPU usage.

---

## Extras

A small collection of optional install components that don't fit the core
piBrick driver pipeline but are useful for getting a fresh image ready to
develop on. They live under `extras/` and are wired into the same
`pibrick-tools --install <component>` interface as the main components.

### `phosh-pi5` — libwlroots-0.18 fix for Phosh on Pi 5

Fixes the Debian-vs-Raspberry-Pi-OS ABI mismatch in `libwlroots-0.18`
that breaks the Phosh compositor (`phoc`) on Raspberry Pi 5. Installs
the Debian build of `libwlroots-0.18` matching phoc's ABI and holds it
so `apt upgrade` does not replace it with the Pi fork.

**Precondition: phosh / phoc must be installed.** The wrapper script
checks for `phoc` and refuses to install on a system where Phosh is
not present — installing the Debian libwlroots on a non-Phosh system
would replace the Pi-forked library that KWin / mutter rely on, and
would break the existing compositor.

```bash
sudo pibrick-tools --install phosh-pi5     # interactive boot-mode prompt
sudo pibrick-tools --uninstall phosh-pi5   # releases the apt hold
```

Uninstall releases the apt hold but does **not** change boot behaviour
(GDM / phosh.service). Re-run the install with a different boot-mode
flag if you want to change that.

See `extras/phosh-pi5/README.md` for full details.

### `zsh` — Oh My Zsh + Powerlevel10k for the active user

Installs [Oh My Zsh](https://ohmyz.sh/), the Powerlevel10k theme,
and the `zsh-autosuggestions` / `zsh-syntax-highlighting` plugins.
Switches the user's default login shell to zsh.

The original installer refuses to run as root because it manipulates
`$HOME` files and `chsh`. Our wrapper detects the active user via
`$SUDO_USER` → `loginctl` → `who` (first non-root) and re-execs the
inner script under `sudo -u <user>` so the user sees the right
`$USER`, `$HOME`, and `EUID`.

```bash
sudo pibrick-tools --install zsh     # run from an interactive sudo session
sudo pibrick-tools --uninstall zsh   # restores bash, removes ~/.oh-my-zsh
```

Uninstall renames the existing `~/.zshrc` to
`~/.zshrc.pibrick-backup-<timestamp>` so any previous config can be
recovered. See `extras/zsh/README.md`.

---

## Autorotation

The autorotation service automatically rotates the screen based on the MMA8451Q accelerometer. Based on the piBrick AOSP17 V6 implementation by Sconioo.

### Hardware Requirements

- **MMA8451Q** accelerometer (or MMA8452/MMA8453 compatible)
- Kernel IIO driver (`mma8452`) OR userspace I2C fallback

### Installation

```bash
sudo pibrick-tools --install autorotation
```

### Service Management

```bash
sudo pibrick-tools --enable-autorotation    # Start service
sudo pibrick-tools --disable-autorotation   # Stop service
sudo pibrick-tools --autorotation-status     # Check status
```

### Orientation Lock

Lock the screen to a specific orientation (disables auto-rotation):

```bash
sudo pibrick-tools --autorotation-lock           # Lock to normal
sudo pibrick-tools --autorotation-lock left      # Lock to landscape-left
sudo pibrick-tools --autorotation-lock right     # Lock to landscape-right
sudo pibrick-tools --autorotation-lock inverted  # Lock to inverted
sudo pibrick-tools --autorotation-unlock       # Resume auto-rotation
```

### KDE Plasma Mobile Quick Drawer tile

On **KDE Plasma Mobile**, the piBrick autorotation toggle is exposed in the
**Quick Drawer** — pull down from the top edge of the screen. A new tile
labelled **"Auto-rotate"** appears alongside the built-in entries
(Wi-Fi, Bluetooth, brightness, etc.):

- **Tile lit** → auto-rotation is enabled, the screen follows the
  accelerometer.
- **Tile dim** → rotation is locked. Tapping restores auto-rotation.

> Earlier versions of this installer dropped a `pibrick-rotation-lock`
> plasmoid KPackage into `~/.local/share/plasma/plasmoids/` and
> `/usr/share/plasma/plasmoids/`. The mobile shell enumerates every plasmoid
> KPackage in those directories at containment load time, regardless of
> whether the user has actually added it to a panel. With the package's
> `EnabledByDefault: true` flag, the shell tried to auto-place our applet
> in the panel containment on first login; the QML threw on load; and the
> shell killed the whole panel containment to avoid rendering an
> inconsistent UI. Symptom: top bar shows at SDDM (SDDM's greeter does not
> enumerate user plasmoids), disappears after logging into Plasma Mobile,
> and stays missing across reboots. The only sure recovery was an OS
> reinstall.
>
> The current installer therefore does **not** copy a plasmoid KPackage
> into either path. The Quick Drawer entry, installed into
> `/usr/share/plasma/quicksettings/`, is the only surface we ship. Anyone
> upgrading from an older release should run `./install.sh --reset-panel`
> (described below) to scrub the leftover package.

The tile state is sourced from `/var/lib/pibrick/autorotation.lock` (the
same file `pibrick-autorotation.service` watches). Tapping the tile calls
`/usr/bin/autorotation-lock {auto|normal}` to flip state, and a 1-second
poll keeps the tile highlighted in sync.

#### Activating the tile

The shell scans `/usr/share/plasma/quicksettings/` and reads
`enabledQuickSettings` from `~/.config/plasmamobilerc` **at session
start**. The installer writes a default value on first install, but:

- **Sign out and back in once** after the first install. Plasmashell on
  this image is launched by SDDM as a system service rather than a user
  systemd unit, so `systemctl --user restart plasma-mobile-shell` does not
  exist.
- If the tile is still missing after sign-out/in, check
  `~/.config/plasmamobilerc` — the entry
  `org.kde.plasma.quicksetting.pibrick-autorotation` must appear in
  `enabledQuickSettings`.
- If entries in the KCM (`Settings → Shell → Action Drawer → Quick
  Settings`) keep un-checking themselves, the most common cause is a stale
  `plasma-discover` cache:
  `rm -rf ~/.cache/plasma-discover/ && sign out → in`.

Do **not** run `loginctl terminate-user "$USER"` to "restart" the shell —
it kills the entire user session (KWin + plasmashell + SSH) and leaves you
with a black screen at SDDM. A clean sign-out from the session menu is the
same effect, but recoverable.

#### Recovering a broken top bar

If you ran an older version of `install.sh` and your top status bar has
disappeared, the broken panel config can be repaired without an OS
reinstall:

```bash
sudo ./autorotation-service/install.sh --reset-panel
# then sign out / sign in
```

`--reset-panel` does three things, in this order:

1. Removes the `pibrick-rotation-lock` KPackage from
   `~/.local/share/plasma/plasmoids/` and
   `~/.local/share/kservices5/` (the per-user plasmoid trees the shell
   enumerates at session start).
2. Removes `/usr/share/plasma/plasmoids/pibrick-rotation-lock` if present
   (the system-wide tree).
3. Rewrites
   `~/.config/plasma-org.kde.plasma.mobileshell-appletsrc` to the default
   Plasma Mobile layout (containments 1 and 3, no applet entries).

A fresh `install.sh` run on a broken system already scrubs all three
locations in passing, so re-running `install.sh --all` is usually enough
to recover without the dedicated `--reset-panel` step.

After any recovery, **sign out and back in once** — the in-memory state of
the currently-running shell is unaffected; you need a fresh session start
for the containment to be re-instantiated without the offending applet.
A reboot is fine too.

### Bounce-back Fix

Rotating from landscape to portrait (or vice versa) previously caused the screen to briefly flip back once before stabilizing. This has been fixed with three changes:

1. **Z-axis transition guard** — Portrait is only detected when the device is nearly upright (`|Z| < 4096` raw units). This prevents a false portrait detection during the moment when Z is still elevated while the device is transitioning between landscape and portrait.

2. **Pending-orientation guard** — Once a new orientation is confirmed and applied, the loop clears the `pending_orientation` buffer. If the sensor re-detects the same orientation as `current_orientation`, it is treated as "already applied" and does not trigger a second rotation call. Previously, this case fell through and could cause a redundant `kscreen-doctor` call.

3. **Single rotation attempt** — The KDE `kscreen-doctor` retry loop was removed. It caused multiple redundant calls because the `kwinoutputconfig.json` verification check ran before KWin had finished writing the new transform. The cooldown (increased from 200 ms → 300 ms) now naturally prevents rapid re-application.

### Supported Desktops

| Desktop | Rotation Method |
|---------|----------------|
| GNOME (Wayland) | gsettings + busctl Mutter API |
| KDE Plasma | kscreen-doctor |
| X11 | xrandr |
| labwc/sway | wlr-randr |

### Axis Mapping

| Orientation | Condition | Rotation |
|-------------|-----------|----------|
| Normal | Y dominant, Y negative | Portrait normal |
| Inverted | Y dominant, Y positive | Portrait inverted |
| Left | X dominant, X positive | Landscape left |
| Right | X dominant, X negative | Landscape right |

### Kernel Module

If the MMA8452 kernel module is not loaded automatically:

```bash
sudo modprobe mma8452
# Or for userspace I2C fallback:
sudo modprobe i2c-dev
```

### Diagnostics

```bash
# Check if MMA8451Q is detected
cat /sys/bus/iio/devices/*/name 2>/dev/null | grep mma845

# View service logs
journalctl -u pibrick-autorotation -n 50
```

---

## Legacy Panels

**9202**, **5.48 inch** (`548`), and **5 inch** (`5inch`) drivers and matching DTS overlays live alongside the default **9203** sources. Select the panel during `install.sh` or with `PANEL=`; the choice is saved to `/etc/pibrick.panel`.

Note: the **548** overlay uses an FocalTech touch controller (`edt-ft5406`); the default **9203** / **9202** / **5 inch** overlays use Hynitron CST66xx (`hyn,66xx`). Re-run install after switching panel so the correct overlay and touch driver are built.

---

## Credits

Display, touch, and battery kernel code originates from **Ahmad Amarullah** ([amarullz.com](https://amarullz.com)). The panel selection, kernel 6.18 modernization, touch panel-follower port, INA228 integration, battery calibration system, button service, desktop indicator, and PocketCM5-specific fixes in this tree are community maintenance on top of those originals.
