#!/bin/bash
#
# extras/phosh-pi5/install.sh — entry point invoked by the main install.sh
# (or pibrick-tools --install phosh-pi5).
#
# Wraps the original fix-phosh-pi5.sh with:
#   - a precondition that phoc / phosh must already be installed
#     (otherwise the libwlroots ABI fix is meaningless — there is nothing
#      to fix), with an explanation that points the user at phosh;
#   - idempotency: if libwlroots-0.18 is already held at the Debian
#     version, skip the apt step and only handle the optional boot-mode
#     change.
#
# The boot-mode flag (--boot-to-phosh | --boot-to-gdm | --remove-gdm
# | --boot-leave) is passed through to the original script so the user
# retains full control of session selection.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix-phosh-pi5.sh"

# ── Precondition: phosh / phoc must be installed ────────────────────────────
# The fix only matters for systems where Phosh is the compositor. If
# neither package is present (e.g. on a KDE Plasma / GNOME system),
# installing the Debian libwlroots would actively break things: it would
# replace the Pi-forked libwlroots that KWin / mutter rely on.
if ! command -v phoc >/dev/null 2>&1 && \
   ! dpkg-query -W -f='${Status}' phoc 2>/dev/null | grep -q '^install ok installed$'; then
    cat >&2 <<EOF
phosh-pi5 install refused: Phosh is not installed on this system.

This fix patches a Debian-vs-Raspberry-Pi-OS ABI mismatch in
libwlroots-0.18 that only affects the Phosh compositor (phoc).
Installing the Debian build of libwlroots here would replace the
Pi-forked library that KDE Plasma's KWin (or GNOME's mutter) rely on,
and would break your current desktop.

To use this component you need a Phosh-based system:
  - Raspberry Pi OS Phone (Pi 5)
  - postmarketOS with phosh
  - or any other Phosh session on Debian / RPi OS

If you want to switch this device to Phosh first, run:

  sudo apt install phosh phoc

Then re-run:

  sudo pibrick-tools --install phosh-pi5
EOF
    exit 1
fi

if [ ! -x "$FIX_SCRIPT" ]; then
    echo "fix-phosh-pi5.sh missing or not executable at $FIX_SCRIPT" >&2
    exit 1
fi

# ── Idempotency: skip apt step if Debian libwlroots is already held ───────
# Detect whether libwlroots-0.18 is already at the Debian version and held.
# If so, only the boot-mode change is needed.
current_ver="$(dpkg-query -W -f='${Version}' libwlroots-0.18 2>/dev/null || echo '')"
is_held="$(dpkg-mark showhold 2>/dev/null | grep -x 'libwlroots-0.18' || true)"
if [ -n "$current_ver" ] && [ -n "$is_held" ]; then
    echo "phosh-pi5: libwlroots-0.18 already at $current_ver and held — apt step will be skipped by fix-phosh-pi5.sh."
fi

# ── Pass through to the original script ────────────────────────────────────
# Any arguments given to install.sh are forwarded. In particular:
#   --boot-to-phosh | --boot-to-gdm | --remove-gdm | --boot-leave
exec "$FIX_SCRIPT" "$@"