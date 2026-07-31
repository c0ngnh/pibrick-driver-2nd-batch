#!/usr/bin/env python3
#
# pibrick-autorotation-dbus - D-Bus service for piBrick autorotation lock control.
#
# Exposes a D-Bus interface so KDE Plasma Mobile plasmoids and other clients
# (e.g. the control center toggle) can lock/unlock auto-rotation without
# directly touching the lock file.
#
# D-Bus activation: runs as a session-bus service owned by the logged-in user.
# Accelerometer polling is handled by pibrick-autorotation.sh (which watches the
# same lock file). This service only handles IPC / lock state management.
#
# Interface: com.pibrick.Autorotation
#   LockOrientation(orientation: string)   → locks to normal/left/right/inverted
#   UnlockOrientation()                     → enables auto-rotation
#   GetStatus()                             → returns {locked: bool, orientation: str}
#   GetLockedOrientation()                  → returns locked orientation or ""
#   SetEnabled(bool)                        → enable/disable the autorotation service
#
# Example D-Bus call from another process:
#   qdbus com.pibrick.Autorotation /com/pibrick/Autorotation \
#     com.pibrick.Autorotation.LockOrientation left
#
import os
import sys
import subprocess
import threading
import time
import json

try:
    import dbus
    import dbus.service
    import dbus.mainloop.glib
    HAS_DBUS = True
except ImportError:
    HAS_DBUS = False

# ── Paths ──────────────────────────────────────────────────────────────────────
# Use /var/lib/pibrick for system-wide state (matches pibrick-autorotation.service)
STATE_DIR = "/var/lib/pibrick"
os.makedirs(STATE_DIR, exist_ok=True)
LOCK_FILE = os.path.join(STATE_DIR, "autorotation.lock")
LOCK_TYPE_FILE = os.path.join(STATE_DIR, "autorotation.lock.type")
ENABLED_FILE = os.path.join(STATE_DIR, "autorotation.enabled")
ROTATION_STATE_FILE = "/var/lib/pibrick/autorotation.state"

BUS_NAME = "com.pibrick.Autorotation"
OBJECT_PATH = "/com/pibrick/Autorotation"
INTERFACE_NAME = "com.pibrick.Autorotation"

VALID_ORIENTATIONS = {"normal", "left", "right", "inverted"}

# ── File helpers ───────────────────────────────────────────────────────────────

def read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError):
        return default

def write_file(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(str(value) + "\n")

def is_locked():
    return os.path.isfile(LOCK_FILE) and os.path.getsize(LOCK_FILE) > 0

def get_locked_orientation():
    return read_file(LOCK_FILE, "")

def lock_orientation(orientation):
    if orientation not in VALID_ORIENTATIONS:
        raise ValueError(f"Invalid orientation: {orientation}")
    os.makedirs(STATE_DIR, exist_ok=True)
    write_file(LOCK_FILE, orientation)
    write_file(LOCK_TYPE_FILE, "manual")

def unlock_orientation():
    for f in [LOCK_FILE, LOCK_TYPE_FILE]:
        try:
            os.remove(f)
        except FileNotFoundError:
            pass

def is_enabled():
    return os.path.isfile(ENABLED_FILE)

def set_enabled(enabled):
    if enabled:
        write_file(ENABLED_FILE, "1")
    else:
        try:
            os.remove(ENABLED_FILE)
        except FileNotFoundError:
            pass

# ── D-Bus service ──────────────────────────────────────────────────────────────

class AutorotationDBus(dbus.service.Object if HAS_DBUS else object):
    def __init__(self, bus):
        if not HAS_DBUS:
            return
        super().__init__(bus, OBJECT_PATH)
        self._log("D-Bus service started (PID=%d)" % os.getpid())

    def _log(self, msg):
        print(msg, flush=True)

    @dbus.service.method(INTERFACE_NAME, in_signature="", out_signature="b")
    def IsLocked(self):
        """Returns True if auto-rotation is currently locked."""
        return is_locked()

    @dbus.service.method(INTERFACE_NAME, in_signature="", out_signature="s")
    def GetLockedOrientation(self):
        """Returns the currently locked orientation, or empty string if unlocked."""
        return get_locked_orientation()

    @dbus.service.method(INTERFACE_NAME, in_signature="s", out_signature="b")
    def LockOrientation(self, orientation):
        """Lock auto-rotation to a specific orientation (normal/left/right/inverted)."""
        orientation = orientation.strip().lower()
        if orientation not in VALID_ORIENTATIONS:
            self._log("ERROR: LockOrientation received invalid orientation: %s" % orientation)
            return False
        lock_orientation(orientation)
        # Also update kwinoutputconfig.json for native KDE quick settings
        subprocess.run(["/usr/bin/autorotation-lock", orientation], capture_output=True)
        self._log("Locked to: %s" % orientation)
        self.LockedChanged(orientation)   # emit signal
        return True

    @dbus.service.method(INTERFACE_NAME, in_signature="", out_signature="b")
    def UnlockOrientation(self):
        """Enable auto-rotation (remove lock)."""
        unlock_orientation()
        # Also update kwinoutputconfig.json for native KDE quick settings
        subprocess.run(["/usr/bin/autorotation-lock", "auto"], capture_output=True)
        self._log("Unlocked auto-rotation")
        self.Unlocked()   # emit signal
        return True

    @dbus.service.method(INTERFACE_NAME, in_signature="", out_signature="a{sv}")
    def GetStatus(self):
        """Returns full status dict: {locked: bool, orientation: str, enabled: bool}"""
        return dbus.Dictionary({
            "locked": dbus.Boolean(is_locked()),
            "orientation": dbus.String(get_locked_orientation()),
            "enabled": dbus.Boolean(is_enabled()),
        }, signature="sv")

    @dbus.service.method(INTERFACE_NAME, in_signature="b", out_signature="")
    def SetEnabled(self, enabled):
        """Enable or disable the autorotation service."""
        set_enabled(enabled)
        self._log("Enabled=%s" % enabled)
        self.EnabledChanged(enabled)

    @dbus.service.method(INTERFACE_NAME, in_signature="", out_signature="b")
    def IsEnabled(self):
        """Returns True if the autorotation service is enabled."""
        return is_enabled()

    # ── Signals ───────────────────────────────────────────────────────────────

    @dbus.service.signal(INTERFACE_NAME, signature="s")
    def LockedChanged(self, orientation):
        """Emitted when auto-rotation is locked to an orientation."""
        pass

    @dbus.service.signal(INTERFACE_NAME)
    def Unlocked(self):
        """Emitted when auto-rotation is unlocked."""
        pass

    @dbus.service.signal(INTERFACE_NAME, signature="b")
    def EnabledChanged(self, enabled):
        """Emitted when the autorotation service is enabled/disabled."""
        pass


def request_bus_name(bus):
    """Request the well-known bus name. Exit if already owned."""
    try:
        name = dbus.service.BusName(BUS_NAME, bus=bus, do_not_queue=True)
        return name
    except dbus.exceptions.NameOwnerException:
        print("D-Bus name %s already owned — another instance is running. Exiting." % BUS_NAME)
        sys.exit(0)


def run_dbus_service():
    """Run the D-Bus main loop (blocking)."""
    if not HAS_DBUS:
        print("ERROR: python3-dbus not installed. Install with: sudo apt install python3-dbus")
        sys.exit(1)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    request_bus_name(bus)
    obj = AutorotationDBus(bus)
    obj.add_to_connection(bus, OBJECT_PATH)

    print("com.pibrick.Autorotation D-Bus service running on session bus")
    print("  LockOrientation(s)     Lock to normal/left/right/inverted")
    print("  UnlockOrientation()    Enable auto-rotation")
    print("  GetStatus()            Get {locked, orientation, enabled}")
    print("  SetEnabled(b)          Enable/disable the autorotation service")

    from gi.repository import GLib
    loop = GLib.MainLoop()
    loop.run()


def main():
    if not HAS_DBUS:
        print("python3-dbus not available — D-Bus service not started.", file=sys.stderr)
        print("Install with: sudo apt install python3-dbus gir1.2-glib-2.0", file=sys.stderr)
        sys.exit(1)

    # Ensure state directory exists
    os.makedirs(STATE_DIR, exist_ok=True)

    try:
        run_dbus_service()
    except KeyboardInterrupt:
        print("\nD-Bus service stopped.")


if __name__ == "__main__":
    main()
