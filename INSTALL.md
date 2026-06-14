# Installation

1. Copy this folder to your Raspberry Pi (or clone the repo).
2. Open a terminal in this directory.
3. Run:

```bash
sudo bash ./install.sh
```

4. Choose your display panel when prompted:

| Choice | Panel | Resolution | Refresh |
|--------|-------|------------|---------|
| **1** | 9203 | 1080×1240 | 90 / 60 Hz (PocketCM5 default) |
| **2** | 9202 | 1080×1240 | 60 Hz |
| **3** | 5.48" | 1080×1920 | 60 Hz |

5. Reboot when install finishes:

```bash
sudo reboot
```

**Default refresh rate is 60 Hz** for all panel variants (best uniformity on 9203). The 9203 panel still offers 90 Hz via `pibrick-display-settings --refresh 90` if you want it. On login, an autostart helper re-applies 60 Hz for GNOME sessions.

## Non-interactive install

```bash
sudo PANEL=9203 bash ./install.sh   # or 9202 / 548
```

The choice is saved to `/etc/pibrick.panel` and reused by `pibrick.service` on kernel updates.

## Initramfs

Pi OS loads the panel module from the initramfs (`auto_initramfs=1`). The installer regenerates it after building so the **new** panel driver is used at boot — not a stale copy from a previous install.

If display issues persist after install:

```bash
sudo depmod -a
sudo update-initramfs -u -k all
sudo reboot
```
