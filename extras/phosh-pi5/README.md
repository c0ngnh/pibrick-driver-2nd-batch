# phosh-pi5

Fixes a Debian-vs-Raspberry-Pi-OS ABI mismatch in `libwlroots-0.18`
that breaks the Phosh compositor (`phoc`) on Raspberry Pi 5.

## What it does

`phoc` on Debian is built against Debian's `libwlroots-0.18`. Raspberry
Pi OS ships a forked `libwlroots-…+rptN` from `archive.raspberrypi.com`
whose `struct wlr_output_state` layout is incompatible, causing
`*** stack smashing detected ***` on session start.

This component:

1. Installs the Debian build of `libwlroots-0.18` matching phoc's ABI
2. Holds the package so future `apt upgrade` does not replace it
3. Optionally reconfigures the boot target (Phosh vs GDM)

The original script lives at `fix-phosh-pi5.sh`; this directory's
`install.sh` wraps it with:

- A precondition: refuses to run unless `phoc` (or `phosh`) is installed
  on the system. Installing the Debian libwlroots on a non-Phosh
  system would break the existing compositor (KWin, mutter).
- A pass-through so any boot-mode flag (`--boot-to-phosh`,
  `--boot-to-gdm`, `--remove-gdm`, `--boot-leave`) reaches the inner
  script.

## Install

```
sudo pibrick-tools --install phosh-pi5
```

The inner script prompts for boot mode interactively when no flag is
passed. To script it, pass the flag to the wrapper:

```
sudo pibrick-tools --install phosh-pi5 -- --boot-to-gdm
```

## Uninstall

```
sudo pibrick-tools --uninstall phosh-pi5
```

Releases the `apt hold` on `libwlroots-0.18`. Does **not** change boot
behaviour — re-run the install with a different boot-mode flag if you
want to change that.