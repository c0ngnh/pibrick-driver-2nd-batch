# piBrick pocketcm5 drivers

Kernel modules and user-space helpers for the piBrick CM5 handheld (Raspberry Pi CM5 + Visionox AMOLED). The default panel is **9203** (SD5302H, PocketCM5); **9202**, **5.48 inch**, and **5 inch** variants are selectable at install time.

| Component | Path | Hardware |
|-----------|------|----------|
| Display | `panel-pibrick.9203.c`, `panel-pibrick.9202.c`, `panel-pibrick.548.c`, `panel-pibrick.5inch.c`, `dts/` | Visionox AMOLED on DSI1 — 9203 default (1080×1240 @ 90/60 Hz) |
| Touch | `hyn_driver_release_qm/` | Hynitron CST66xx (`compatible = "hyn,66xx"` in DTS) |
| Battery | `battery/bq25890_battery.c` | TI BQ25895 PMIC (no separate fuel gauge) |
| Buttons | `button-service/` | GPIO daemon for power + user buttons |
| Desktop | `desktop/` | GTK taskbar battery indicator, `pibrick-display-settings` |
| Tools | `tools/` | Display settings menu, GNOME refresh helper, touch reset, OCV calibration |

This repository bundles the display, touch, battery, button, and desktop pieces into a single installable tree, targeting **Raspberry Pi OS on kernel 6.18** with **GNOME 48 (Wayland)**.

## Install

See [INSTALL.md](INSTALL.md):

```bash
sudo bash ./install.sh
```

`install.sh` copies the tree to `/usr/lib/pibrick/`, builds kernel modules, sets up the desktop battery indicator, installs the button service, and enables `pibrick.service` (rebuild on kernel update).

### Panel selection

`install.sh` prompts for the panel variant and saves the choice to `/etc/pibrick.panel`. You can also pick it non-interactively:

```bash
sudo PANEL=9203  bash ./install.sh   # SD5302H (90/60 Hz, 90 Hz default)
sudo PANEL=9202  bash ./install.sh   # legacy 1080×1240 @ 60 Hz
sudo PANEL=548   bash ./install.sh   # 5.48 inch 1080×1920 @ 60 Hz
sudo PANEL=5inch bash ./install.sh   # 5 inch 1080×1240 @ 90/60 Hz
```

The default refresh rate is **90 Hz** for the 9203 panel (saved to `/etc/pibrick.display-refresh` and applied on login). Use `pibrick-display-settings --refresh 60` for lower power.

---

## What's new

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

### Battery (`battery/bq25890_battery.c`)

- Software fuel gauge on top of the BQ25895 charger: OCV lookup table, charge IR compensation, capacity smoothing, and unplug relax handling.
- Tunable constants (`BQ25890_BATT_IR_MOHM`, `BQ25890_CHARGE_FULL_UAH`, …) plus `tools/ocv-calibrate.py` for calibration.
- Exposes a standard `/sys/class/power_supply/battery` interface consumed by the desktop indicator.

### Build & packaging

- `install.sh` — `set -euo pipefail`, interactive panel prompt, saves panel + default refresh, removes any stale `panel-pibrick.c`, runs the desktop and button-service installers, and regenerates the initramfs when `auto_initramfs=1`.
- `build.sh` — `--force` / `--no-reboot` flags, rebuilds on kernel change, synchronous install, initramfs regen.
- `Makefile` — `make amoled PANEL=9203|9202|548|5inch`; symlinks the chosen source to `panel-pibrick.c`; refuses to uninstall if the new `.ko` is missing.
- `pibrick.service` — rebuilds the out-of-tree modules automatically on kernel updates.

### Desktop & tools

- `desktop/pibrick-battery-indicator.py` taskbar battery indicator with autostart.
- `tools/pibrick-display-settings.sh`, `tools/gnome-display-rate.py`, `tools/ocv-calibrate.py`.

---

## Buttons

The GPIO button daemon lives under `button-service/` and is installed by `install.sh`.

### GPIO wiring

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

### Default button actions

| Gesture | Action |
|---------|--------|
| **User short** | Toggle display (`display-on-off.sh`) |
| **User long** | Empty stub (customize `user-long.sh`) |
| **Power short** | Native desktop power menu (GNOME, KDE, XFCE, Pi OS `pishutdown`, …) |
| **Power long** | Hold `KEY_POWER` for 2 s, release on button up (Pi-style shutdown) |

### Daemon implementation

- **libgpiod v2** C API with persistent line requests.
- Long-press threshold **2000 ms** (`LONG_PRESS_MS`); settle + release debounce + identity sampling.
- Logs to `syslog` / `journalctl -u pibrickbtn`; `--test` mode prints live GPIO levels.
- Unloads `gpio_keys` at startup; leaves the touch module alone.
- Built with `-lgpiod` (`install.sh` installs `libgpiod-dev`).
- systemd unit: `Restart=on-failure`, `Before=graphical.target`.
- Display-toggle sysfs write is enabled for the user by `99-pibrick-display.rules` (driver attr stays `0644`).

### Action scripts

| Script | Role |
|--------|------|
| `display-on-off.sh` | Toggle panel; safe `find` with clear errors for missing node / permission denied |
| `brightness.sh` | Legacy wrapper → `pibrick-brightness up` |
| `pibrick-brightness` | Backlight up/down for labwc / Pi OS Trixie (`XF86MonBrightness*` keys) |
| `run-as-session-user.sh` | Run GUI commands as the logged-in desktop user (`loginctl` + `/run/user` fallback, `runuser` / `su`) |
| `power-menu.sh` | DE-aware power menu (GNOME, XFCE, Pi OS `pishutdown`; KDE/MATE/LXQt fallbacks) |

### Power menu

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

## Sysfs interfaces (quick reference)

| Node | Purpose |
|------|---------|
| `/sys/class/backlight/pibrick-backlight/brightness` | Backlight 0–1023 |
| `…/pibrick_display_enable` (under DSI device) | Display on/off (`0` / `1`) |
| `…/color_profile` | `natural`, `vivid`, `srgb`, `warm`, `cool`, `night`, `soft` (9203 only) |
| `/sys/class/power_supply/battery/` | Capacity, voltage, charging state (BQ25895 driver) |

### Display settings menu

```bash
pibrick-display-settings
```

Interactive menu for:

- **Color profile** — sysfs `color_profile` (9203 only)
- **Refresh rate** — 90 Hz default @ 1080×1240 on 9203; 60 Hz optional. The 5.48 inch panel is 60 Hz only.

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

## Customizing buttons

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

## Legacy panels

**9202**, **5.48 inch** (`548`), and **5 inch** (`5inch`) drivers and matching DTS overlays live alongside the default **9203** sources. Select the panel during `install.sh` or with `PANEL=`; the choice is saved to `/etc/pibrick.panel`.

Note: the **548** overlay uses an FocalTech touch controller (`edt-ft5406`); the default **9203** / **9202** / **5 inch** overlays use Hynitron CST66xx (`hyn,66xx`). Re-run install after switching panel so the correct overlay and touch driver are built.

---

## Credits

Display, touch, and battery kernel code originates from **Ahmad Amarullah** ([amarullz.com](https://amarullz.com)). The panel selection, kernel 6.18 modernization, touch panel-follower port, battery fuel-gauge extensions, button service, desktop indicator, and PocketCM5-specific fixes in this tree are community maintenance on top of those originals.
