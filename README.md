# piBrick pocketcm5 drivers

Kernel modules and user-space helpers for the piBrick CM5 handheld (Raspberry Pi CM5 + Visionox 1080×1240 AMOLED). Both Visionox panel variants are supported and selectable at install time: **9203** (SD5302H) and **9202** (VTDR6110).

| Component | Path | Hardware |
|-----------|------|----------|
| Display | `panel-pibrick.9203.c`, `panel-pibrick.9202.c`, `dts/vc4-kms-dsi-pibrick.dts` | Visionox 1080×1240 AMOLED, DSI1 — 9203 (SD5302H, 90/60 Hz) or 9202 (VTDR6110, 60 Hz) |
| Touch | `hyn_driver_release_qm/` | Hynitron CST66xx (`compatible = "hyn,66xx"` in DTS) |
| Battery | `battery/bq25890_battery.c` | TI BQ25895 PMIC (no separate fuel gauge) |
| Buttons | `button-service/` | GPIO daemon for power + user buttons |
| Desktop | `desktop/` | GTK taskbar battery indicator, `pibrick-display-settings` |
| Tools | `tools/` | Display settings menu, GNOME refresh helper, touch reset, OCV calibration |

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

### Panel selection

`install.sh` prompts for the panel variant and saves the choice to `/etc/pibrick.panel`. You can also pick it non-interactively:

```bash
sudo PANEL=9203 bash ./install.sh   # SD5302H (90/60 Hz)
sudo PANEL=9202 bash ./install.sh   # VTDR6110 (60 Hz)
sudo PANEL=548  bash ./install.sh   # 5.48 inch 1080×1920 (legacy)
```

The default refresh rate is **60 Hz** (saved to `/etc/pibrick.display-refresh` and applied on login), which is within the panel's 57–63 Hz frame-rate spec. The 9203 panel can additionally run 90 Hz via `pibrick-display-settings --refresh 90`.

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
| Panel sources | Many variants at repo root (`panel-pibrick.5inch.c`, `.9202.c`, `.548inch.c`, …) | Two maintained builds at root: `panel-pibrick.9203.c` and `panel-pibrick.9202.c`; legacy variants under `archive/panels/` |
| DTS overlays | Multiple overlays at `dts/` (5", 5.48", 9202, XGA, …) | One active overlay: `dts/vc4-kms-dsi-pibrick.dts`; legacy under `archive/dts/` |
| Makefile | `make amoled` or `make xga`; builds `panel-pibrick.c` directly | `make amoled PANEL=9203\|9202\|548`; `install.sh` prompts for panel |
| Dev copies | Extra `2/`, `3/panel-pibrick.c` snapshots at repo root | Removed from active tree |
| Desktop | Not included | `desktop/pibrick-battery-indicator.py` + autostart |
| Tools | Not included | `tools/pibrick-display-settings.sh`, `tools/gnome-display-rate.py`, `tools/ocv-calibrate.py`, `tools/strip-panel-if0.py` |

### Build and install

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| `build.sh` | Rebuild only when kernel changes; `make install &` (background) | `--force` / `--no-reboot` flags; synchronous `make install` |
| `install.sh` | Runs `build.sh` only | Also runs `desktop/setup-desktop.sh` and `button-service/install.sh` with `--force --no-reboot` |
| `pibrick.service` | Same auto-rebuild-on-kernel-change pattern | Same |

### Display drivers (`panel-pibrick.9203.c`, `panel-pibrick.9202.c`)

| Topic | Amarullz | This repo |
|-------|----------|-----------|
| Panel variants | Single source swapped manually | `PANEL=9203\|9202` selects the source; both maintained at repo root |
| Panel allocation | `devm_kzalloc` + `drm_panel_init` (deprecated on kernel 6.18) | `devm_drm_panel_alloc()` refcounted allocation (canonical on kernel 6.18; avoids panel use-after-free) |
| Power lifecycle | `prepare` / `unprepare` only | `prepare` / `unprepare` + `enable` / `disable` + `shutdown` handler |
| Includes | Extra DRM headers (`drm_dsc.h`, `drm_vblank.h`) | Minimal includes for the active panel path |
| Sysfs `color_profile` | Present (9203) | Present on 9203 (9202 has no gamma tables) |
| Sysfs `pibrick_display_enable` | Present; default root-only permissions | `DEVICE_ATTR_RW` (0644 in driver); user write granted at runtime by udev rule + button service (kernel 6.18 forbids world-writable 0666 sysfs attrs) |
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
| Panel power sync | `drm_panel_notifier` / `DRM_PANEL_EVENT_BLANK` (Qualcomm-downstream API) | **`drm_panel_follower`** (mainline API) — the notifier API does not exist on the Pi kernel and made `hyn_ts.ko` fail to build, so touch broke on kernel updates |
| Build on Pi 6.x | Fails: `FB_EVENT_BLANK` / `drm_panel_notifier_register` undeclared | Builds against `CONFIG_DRM_PANEL`; falls back to `dev_pm_ops` (touch always-on) if panel-follower support is absent |
| Suspend/resume races | early/late duplicate blank events + `cancel_work_sync` could leave touch stuck suspended | Follower callbacks are serialised by the panel core around the real power transition; `hyntpdbg rst` resumes touch when suspended |
| Button daemon interaction | `pibrickbtn` reloads `hyn_ts` on every start (`rmmod` + `modprobe`) | Button daemon only unloads `gpio_keys`; touch module left alone; display toggle sends touch wake |

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
| Sysfs permissions | None; display toggle often needs root | udev rule `99-pibrick-display.rules` grants user write at runtime (driver attr stays 0644) |
| Session GUI | None | `run-as-session-user.sh` (`loginctl` + `/run/user` fallback) |
| systemd unit | Minimal `After=network.target` | `Restart=on-failure`, `Before=graphical.target` |

### Action scripts

| Script | Amarullz | This repo |
|--------|----------|-----------|
| `display-on-off.sh` | Backtick `` `find` `` one-liners | Safe `find` + error messages for missing node / permission denied |
| `brightness.sh` | Default user-short action | Present but not wired to user-short by default |
| `on-off-display-wlroot.sh` | Alternate `wlr-randr` toggle (unused) | Not shipped |
| `run-as-session-user.sh` | — | Runs GUI commands as the logged-in desktop user (`runuser` / `su` fallback) |
| `power-menu.sh` | — | DE-aware power menu: GNOME `gnome-session-quit`, XFCE `xfce4-session-logout`, Pi OS `pishutdown` (KDE/MATE/LXQt as fallbacks) |

### Power menu

Power short press runs `power-short.sh` → `run-as-session-user.sh` → `power-menu.sh` in the active graphical session.

Primary targets (verified design):

| Desktop | Handler | Status |
|---------|---------|--------|
| **GNOME** (48) | `KEY_POWER` uinput tap from `pibrickbtn` (same as hardware power key) | Tested |
| **XFCE** | `xfce4-session-logout` | Supported |
| **Pi OS / labwc** | `pishutdown` | Tested |

On GNOME, `power-menu.sh` is a no-op when the session bus shows `org.gnome.Shell` — the daemon injects `KEY_POWER` and opening a second D-Bus shutdown dialog (`EndSessionDialog`) caused the menu to vanish and leave a stuck blur overlay.

Additional fallbacks (best-effort, not verified on hardware): KDE Plasma (`org.kde.LogoutPrompt`), MATE (`mate-session-save`), LXQt (`lxqt-leave`), and a simulated `XF86PowerOff` (`wtype` / `xdotool`).

Detection order:

1. Live session D-Bus (`org.gnome.Shell`, `org.kde.LogoutPrompt`) — beats stale `XDG_CURRENT_DESKTOP` (Pi images may still export `LABWC` while GNOME runs)
2. `XDG_CURRENT_DESKTOP` name matching
3. Per-DE generic fallbacks, then simulated `XF86PowerOff`
4. `pishutdown` only when GNOME/KDE are not on the session bus

On **GNOME 48**, the native power menu is triggered by a brief `KEY_POWER` pulse from `pibrickbtn` via uinput — the same path as a laptop power key. Do not use `EndSessionDialog` here; it conflicts with GNOME and leaves a stuck blur overlay.

Test from a root shell (manual fallback only — physical button is preferred on GNOME):

```bash
sudo bash /etc/pibrick/power-short.sh
```

---

## Sysfs interfaces (quick reference)

| Node | Purpose |
|------|---------|
| `/sys/class/backlight/pibrick-backlight/brightness` | Backlight 0–1023 |
| `…/pibrick_display_enable` (under DSI device) | Display on/off (`0` / `1`) |
| `…/color_profile` | `natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft` (9203 only) |
| `/sys/class/power_supply/battery/` | Capacity, voltage, charging state (from extended BQ25895 driver) |

### Display settings menu

```bash
pibrick-display-settings
```

Interactive menu for:

- **Color profile** — sysfs `color_profile` (`natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft`); 9203 only
- **Refresh rate** — 60 Hz default @ 1080×1240; the 9203 panel also offers 90 Hz (9202 and 5.48 inch are 60 Hz only)

Refresh-rate backend is chosen automatically:

| Desktop | Backend | Status |
|---------|---------|--------|
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

## Touch troubleshooting

Touch is driven by `hyn_ts` and follows panel power via the mainline `drm_panel_follower` API. Earlier revisions used the Qualcomm-only `drm_panel_notifier` API, which does not exist on the Pi kernel — so a kernel update would rebuild `hyn_ts` and it would fail to compile, leaving you with no working touch. That is the most likely cause of "touch stopped after an update."

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

**What this repo fixes vs Amarullz:**

| Issue | Cause | Fix in this repo |
|-------|-------|------------------|
| `hyn_ts.ko` fails to build (no touch after kernel update) | Code used `drm_panel_notifier_register` / `DRM_PANEL_EVENT_BLANK`, which are Qualcomm-downstream only and absent on the Pi kernel | Switched to mainline `drm_panel_follower` (`drm_panel_add_follower`) gated on `CONFIG_DRM_PANEL` |
| Touch stuck suspended after blank/unblank | early/late duplicate blank events + `cancel_work_sync` race | Follower callbacks (`panel_prepared` / `panel_unpreparing`) are serialised by the panel core around the real power transition |
| Touch dead after user-button display toggle | no userspace wake | `display-on-off.sh` sends touch `rst` after turning panel on |
| `rst` sysfs useless while suspended | only reset chip, IRQ still disabled | `hyntpdbg` `rst` queues driver resume when suspended |

If the panel never registers a follower (older kernel without `CONFIG_DRM_PANEL`), touch falls back to `dev_pm_ops` and simply stays active whenever the system is awake. For a stuck session without rebuilding, use `pibrick-touch-reset`.

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
