#!/bin/bash
#
# fix-phosh-pi5.sh
# -----------------------------------------------------------------------------
# Fix Phosh failing to start on Raspberry Pi OS / Raspberry Pi 5
# (Debian trixie arm64 + phosh). Symptom: choosing the "Phosh" session in GDM
# just bounces back to the login screen; running `phosh.service` crash-loops.
#
# ROOT CAUSE:
#   `phoc` (the Phosh compositor, Debian package) is built against Debian's
#   wlroots. Raspberry Pi OS ships a forked libwlroots (…+rptN) from
#   archive.raspberrypi.com whose `struct wlr_output_state` layout differs.
#   When phoc stack-allocates that struct in phoc_output_initable_init() and
#   the forked library initialises it, it writes past phoc's smaller struct and
#   trips the stack canary:
#       *** stack smashing detected ***: terminated   (SIGABRT / earlier SIGSEGV)
#   phoc dies on the very first output, so the session ends instantly. GNOME
#   works because mutter does not use wlroots.
#
# FIX:
#   Install the Debian build of libwlroots-0.18 (matching phoc's ABI) and hold
#   it so `apt upgrade` cannot replace it with the Pi fork again.
#
# Run as root:  sudo bash fix-phosh-pi5.sh [--boot-to-phosh | --boot-to-gdm | --boot-leave]
# If no flag is given, the script interactively asks what to do about GDM.
# -----------------------------------------------------------------------------
set -euo pipefail

BOOT_MODE="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

echo ">>> Current libwlroots-0.18:"
dpkg-query -W -f='${Version}\n' libwlroots-0.18 2>/dev/null || echo "(not installed)"

DEB_VER="$(apt-cache madison libwlroots-0.18 \
            | awk '/deb.debian.org/ {print $3; exit}')"
if [ -z "${DEB_VER:-}" ]; then
  echo "ERROR: Could not find a Debian (deb.debian.org) build of libwlroots-0.18." >&2
  echo "       Make sure the Debian repositories are enabled." >&2
  exit 1
fi
echo ">>> Debian libwlroots-0.18 version to install: ${DEB_VER}"

echo ">>> Installing Debian libwlroots and holding it..."
apt-mark unhold libwlroots-0.18 >/dev/null 2>&1 || true
apt-get install -y --allow-downgrades "libwlroots-0.18=${DEB_VER}"
apt-mark hold libwlroots-0.18

echo ">>> Now installed:"
dpkg-query -W -f='  libwlroots-0.18 ${Version}\n' libwlroots-0.18
echo ">>> Held packages:"; apt-mark showhold

# Configure boot behaviour. If no flag was passed, ask interactively.
if [ -z "$BOOT_MODE" ]; then
  echo
  echo "How should this device boot?"
  echo "  1) Boot straight into Phosh   (disable GDM, enable phosh.service) - phone/touch device"
  echo "  2) Keep GDM login chooser     (pick GNOME or Phosh each login)"
  echo "  3) Remove GDM entirely        (boot straight into Phosh; also 'apt purge gdm3')"
  echo "  4) Leave boot behaviour unchanged"
  if [ -t 0 ]; then
    read -r -p "Choose [1-4] (default 1): " ans
  else
    ans=""
    echo "(non-interactive: defaulting to 1 - boot straight into Phosh)"
  fi
  case "${ans:-1}" in
    1) BOOT_MODE="--boot-to-phosh" ;;
    2) BOOT_MODE="--boot-to-gdm" ;;
    3) BOOT_MODE="--remove-gdm" ;;
    *) BOOT_MODE="--boot-leave" ;;
  esac
fi

case "$BOOT_MODE" in
  --boot-to-phosh)
    echo ">>> Boot straight into Phosh (disable GDM, enable phosh.service)..."
    systemctl disable gdm  >/dev/null 2>&1 || true
    systemctl enable phosh
    echo "    Done. Reboot to start Phosh."
    ;;
  --remove-gdm)
    echo ">>> Removing GDM and booting straight into Phosh..."
    systemctl disable gdm >/dev/null 2>&1 || true
    systemctl enable phosh
    systemctl set-default graphical.target >/dev/null 2>&1 || true
    apt-get purge -y gdm3 || true
    echo "    Done. GDM removed; Phosh will start on boot."
    ;;
  --boot-to-gdm)
    echo ">>> Boot into GDM chooser (GNOME or Phosh selectable)..."
    systemctl disable phosh >/dev/null 2>&1 || true
    systemctl enable gdm    >/dev/null 2>&1 || true
    echo "    Done. Pick 'Phosh' from the gear menu on the GDM login screen."
    ;;
  *)
    echo ">>> Boot behaviour left unchanged."
    echo "    Re-run with --boot-to-phosh, --boot-to-gdm, or --remove-gdm to set it."
    ;;
esac

echo
echo ">>> Quick test (stops GDM, starts phosh for 10s):"
systemctl reset-failed phosh 2>/dev/null || true
systemctl stop gdm 2>/dev/null || true
sleep 1
systemctl start phosh
sleep 10
if pgrep -x phoc >/dev/null && pgrep -f '/usr/libexec/phosh' >/dev/null; then
  echo "    SUCCESS: phoc + phosh are running."
else
  echo "    WARNING: phosh did not come up; check: journalctl -u phosh -b 0"
fi

echo
echo ">>> All done."
