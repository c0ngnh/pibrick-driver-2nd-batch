# piBrick pocketcm5 drivers

Kernel modules and user-space helpers for the piBrick CM5 handheld (Raspberry Pi CM5 + Visionox 9203 AMOLED).

| Component | Path | Hardware |
|-----------|------|----------|
| Display | `panel-pibrick.9203.c`, `dts/vc4-kms-dsi-pibrick.dts` | Visionox VTDR6110 / 9203, 1080×1240 @ 90 Hz, DSI1 |
| Touch | `hyn_driver_release_qm/` | Hynitron CST66xx (`compatible = "hyn,66xx"` in DTS) |
| Battery | `battery/bq25890_battery.c` | TI BQ25895 PMIC (no separate fuel gauge) |
| Buttons | `button-service/` | GPIO daemon for power + user buttons |
| Desktop | `desktop/` | GTK taskbar battery indicator, `pibrick-display-settings` |
| Tools | `tools/` | Display settings menu, GNOME refresh helper, OCV calibration |

Original maker sources (Amarullz / [amarullz.com](https://amarullz.com)) ship as two separate trees:

- `pibrick-driver-2nd-batch` — kernel modules, DTS, build scripts
- `pibrick-button-service` — GPIO button daemon (installed separately)

This repository merges both into one installable bundle and applies the fixes described below.

## Install

See [INSTALL.md](INSTALL.md):

```bash
sudo bash ./install.sh
```

`install.sh` copies the tree to `/usr/lib/pibrick/`, builds kernel modules, sets up the desktop battery indicator, installs the button service, and enables `pibrick.service` (rebuild on kernel update).

---

## Comparison with Amarullz originals

Baseline for the tables below:

| | Maker (original) | This repository |
|---|------------------|-----------------|
| Driver tree | `pibrick-driver-2nd-batch` | same name, extended |
| Button tree | `pibrick-button-service` (separate repo) | integrated as `button-service/` |

### Repository layout

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Scope | Kernel modules only; buttons are a second install | Single repo: drivers + buttons + desktop |
| Panel sources | Many variants at repo root (`panel-pibrick.5inch.c`, `.9202.c`, `.548inch.c`, …) | One active build: `panel-pibrick.9203.c`; legacy files under `archive/panels/` |
| DTS overlays | Multiple overlays at `dts/` (5", 5.48", 9202, XGA, …) | One active overlay: `dts/vc4-kms-dsi-pibrick.dts`; legacy under `archive/dts/` |
| Makefile | `make amoled` or `make xga`; builds `panel-pibrick.c` directly | `make amoled` only; symlinks `panel-pibrick.9203.c` → `panel-pibrick.c` |
| Dev copies | Extra `2/`, `3/panel-pibrick.c` snapshots at repo root | Removed from active tree |
| Desktop | Not included | `desktop/pibrick-battery-indicator.py` + autostart |
| Tools | Not included | `tools/pibrick-display-settings.sh`, `tools/gnome-display-rate.py`, `tools/ocv-calibrate.py`, `tools/strip-panel-if0.py` |

### Build and install

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| `build.sh` | Rebuild only when kernel changes; `make install &` (background) | `--force` / `--no-reboot` flags; synchronous `make install` |
| `install.sh` | Runs `build.sh` only | Also runs `desktop/setup-desktop.sh` and `button-service/install.sh` with `--force --no-reboot` |
| `pibrick.service` | Same auto-rebuild-on-kernel-change pattern | Same |

### Display driver (`panel-pibrick.9203.c`)

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Size / structure | ~1378 lines; large blocks of commented timing alternatives | ~985 lines; trimmed and focused on 9203 @ 90 Hz |
| Includes | Extra DRM headers (`drm_dsc.h`, `drm_vblank.h`) | Minimal includes for the active panel path |
| Sysfs `color_profile` | Present | Present (unchanged behaviour) |
| Sysfs `pibrick_display_enable` | Present; default root-only permissions | Present; mode **0666** in driver so users can toggle display |
| Backlight | `pibrick-backlight` class, 0–1023 | Same |

### Device tree (`dts/vc4-kms-dsi-pibrick.dts`)

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Panel / touch nodes | DSI1, 1080×1240, `hyn,66xx` @ I2C0 | Same wiring |
| PMIC compatible | `ti,bq25890` | `ti,bq25895` (matches CM5 hardware) |
| Charge regulation voltage | 4.10 V (`4100000`) | 4.176 V (`4176000`) |

### Touch driver (`hyn_driver_release_qm/`)

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Chip support | CST66xx, CST92xx, and other Hynitron variants | Same vendor tree |
| DRM panel sync | `drm_panel_notifier` code in `hyn_core.c` | Same logic |
| Out-of-tree build | No explicit `CONFIG_DRM_PANEL` workaround | `-DHYN_DRM_PANEL_NOTIFIER` in `Makefile` so panel blank/unblank events work on Pi 5 without patching the kernel tree |
| Button daemon interaction | `pibrickbtn` reloads `hyn_ts` on every start (`rmmod` + `modprobe`) | Button daemon only unloads `gpio_keys`; touch module left alone |

### Battery driver (`battery/bq25890_battery.c`)

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Base | Upstream-style BQ25890 charger driver | Extended from the same base |
| Fuel gauge | None (PMIC only) | Software fuel gauge: OCV lookup table, charge IR compensation, capacity smoothing, unplug relax |
| Tuning | DTS charge parameters only | Documented constants (`BQ25890_BATT_IR_MOHM`, `BQ25890_CHARGE_FULL_UAH`, etc.) + `tools/ocv-calibrate.py` |
| Desktop integration | None | Battery indicator reads `/sys/class/power_supply/battery` |

---

## Button service comparison

Amarullz ships buttons in a **separate** `pibrick-button-service` repo. This repo vendors a rewritten copy under `button-service/`.

### GPIO wiring (same on both)

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

Power does **not** pull line 23 low; only the user button does. The maker daemon used `gpiochip10:20 == 1` to mean power, which does not match idle/select behaviour on real hardware. This repo uses `press == 0 && select == 0` for power and `press == 1 && select == 0` for user.

### Default button actions

| Gesture | Amarullz (`pibrick-button-service`) | This repo (`button-service/`) |
|---------|--------------------------------------|-------------------------------|
| **User short** | Cycle backlight (+64 steps via `brightness.sh`) | Toggle display (`display-on-off.sh`) |
| **User long** | Empty stub (`user-long.sh`) | Empty stub (customize `user-long.sh`) |
| **Power short** | Toggle display | Native desktop power menu (GNOME, KDE, XFCE, Pi OS `pishutdown`, …) |
| **Power long** | Brief `KEY_POWER` uinput pulse (~40 ms threshold) | Hold `KEY_POWER` for 2 s, release on button up (Pi-style shutdown) |

### Daemon implementation

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| GPIO access | Shell `gpioget` / `gpiomon` via `popen()` | **libgpiod v2** C API (persistent line requests) |
| Long-press timing | ~40 ms (`400 × 100 µs` loop) | **2000 ms** (`LONG_PRESS_MS`) |
| Debounce | Minimal | Settle + release debounce + identity sampling |
| Logging | `printf` to stdout | `syslog` + `journalctl -u pibrickbtn` |
| Diagnostics | None | `--test` mode prints live GPIO levels |
| Touch module | Reloads `hyn_ts` at startup | Does not touch touch driver |
| `gpio_keys` | `rmmod gpio_keys` at startup | Same |
| Build | `gcc pibrickbtn.c` (no libs) | `gcc … -lgpiod`; `install.sh` installs `libgpiod-dev` |
| Sysfs permissions | None; display toggle often needs root | udev rule `99-pibrick-display.rules` + panel driver 0666 |
| Session GUI | None | `run-as-session-user.sh` (`loginctl` + `/run/user` fallback) |
| systemd unit | Minimal `After=network.target` | `Restart=on-failure`, `Before=graphical.target` |

### Action scripts

| Script | Amarullz | This repo |
|--------|----------|-----------|
| `display-on-off.sh` | Backtick `` `find` `` one-liners | Safe `find` + error messages for missing node / permission denied |
| `brightness.sh` | Default user-short action | Present but not wired to user-short by default |
| `on-off-display-wlroot.sh` | Alternate `wlr-randr` toggle (unused) | Not shipped |
| `run-as-session-user.sh` | — | Runs GUI commands as the logged-in desktop user (`runuser` / `su` fallback) |
| `power-menu.sh` | — | DE-aware power menu: GNOME `gnome-session-quit`, KDE, XFCE, Pi OS `pishutdown` |

### Power menu (GNOME / KDE / Pi OS)

Power short press runs `power-short.sh` → `run-as-session-user.sh` → `power-menu.sh` in the active graphical session.

Detection order:

1. Live session D-Bus (`org.gnome.Shell`, `org.kde.LogoutPrompt`) — beats stale `XDG_CURRENT_DESKTOP` (Pi images may still export `LABWC` while GNOME runs)
2. `XDG_CURRENT_DESKTOP` name matching
3. Simulated `XF86PowerOff` (`wtype` / `xdotool`)
4. `pishutdown` only when GNOME/KDE are not on the session bus

On **GNOME 48**, the menu uses `gnome-session-quit` or `EndSessionDialog.Open` (not `Shell.Eval`, which is restricted on GNOME 41+).

Test from a root shell:

```bash
sudo bash /etc/pibrick/power-short.sh
```

---

## Sysfs interfaces (quick reference)

| Node | Purpose |
|------|---------|
| `/sys/class/backlight/pibrick-backlight/brightness` | Backlight 0–1023 |
| `…/pibrick_display_enable` (under DSI device) | Display on/off (`0` / `1`) |
| `…/color_profile` | `natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft` |
| `/sys/class/power_supply/battery/` | Capacity, voltage, charging state (from extended BQ25895 driver) |

### Display settings menu

```bash
pibrick-display-settings
```

Interactive menu for:

- **Color profile** — sysfs `color_profile` (`natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft`)
- **Refresh rate** — 90 / 60 Hz @ 1080×1240

Refresh-rate backend is chosen automatically:

| Desktop | Backend | Notes |
|---------|---------|-------|
| **GNOME Wayland** | `tools/gnome-display-rate.py` via `org.gnome.Mutter.DisplayConfig` | Uses `python3-dbus` (primary) or `gdbus` fallback |
| **labwc / wlroots** | `wlr-randr` | Pi OS default compositor |
| **X11** | `xrandr` | Legacy sessions |

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
- `/usr/lib/pibrick/tools/gnome-display-rate.py`

Dependencies: `python3-gi`, `python3-dbus` (installed by `setup-desktop.sh` when missing).

---

## Customizing buttons

Edit scripts under `/etc/pibrick/` (copied from `button-service/etc/pibrick/`):

| Hook | Default in this repo |
|------|----------------------|
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

## Legacy hardware

Older panel sizes and DTS variants are kept under `archive/` for reference. They are **not** built or installed by default. To switch panels you would need to restore the matching source + DTS from `archive/` and adjust the top-level `Makefile` / `build.sh` targets accordingly.

---

## Credits

Display, touch, and battery kernel code is by **Ahmad Amarullah** ([amarullz.com](https://amarullz.com)). Button service, battery fuel-gauge extensions, desktop indicator, and PocketCM5-specific fixes in this tree are community maintenance on top of those originals.
