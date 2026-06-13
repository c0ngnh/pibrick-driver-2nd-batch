#!/usr/bin/env python3
"""Read/set refresh rate via org.gnome.Mutter.DisplayConfig (GNOME Wayland)."""

import subprocess
import sys


def load_gio():
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio

    return Gio


def mutter_proxy(Gio):
    return Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION,
        Gio.DBusProxyFlags.NONE,
        None,
        "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig",
        "org.gnome.Mutter.DisplayConfig",
        None,
    )


def get_state(proxy, Gio):
    return proxy.call_sync(
        "GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None
    ).unpack()


def monitor_by_connector(monitors, connector):
    for monitor in monitors:
        if monitor[0][0] == connector:
            return monitor
    return None


def mode_is_active(mode):
    props = mode[6]
    return "is-current" in props or props.get("is-current") is True


def current_mode(monitor):
    for mode in monitor[1]:
        if mode_is_active(mode):
            return mode

    for mode in monitor[1]:
        props = mode[6]
        if "is-preferred" in props or props.get("is-preferred") is True:
            return mode

    if monitor[1]:
        return monitor[1][0]

    return None


def mode_refresh_hz(mode):
    if mode is None:
        return None

    refresh = float(mode[3])
    if refresh > 0:
        return round(refresh)

    mode_id = str(mode[0])
    if "@" in mode_id:
        return round(float(mode_id.rsplit("@", 1)[1]))

    return None


def primary_connector(logical_monitors):
    for logical in logical_monitors:
        if logical[4] and logical[5]:
            return logical[5][0][0]

    for logical in logical_monitors:
        if logical[5]:
            return logical[5][0][0]

    return None


def mode_with_refresh(monitor, width, height, refresh_hz):
    target = int(refresh_hz)

    for mode in monitor[1]:
        if mode[1] == width and mode[2] == height:
            rate = mode_refresh_hz(mode)
            if rate is not None and rate == target:
                return mode

    return None


def build_apply_logical_monitors(logical_monitors, monitors, connector, mode_id):
    applied = []

    for logical in logical_monitors:
        x, y, scale, transform, primary, linked, _props = logical
        outputs = []

        for link in linked:
            link_connector = link[0]
            if link_connector == connector:
                mode_name = str(mode_id)
            else:
                monitor = monitor_by_connector(monitors, link_connector)
                active_mode = current_mode(monitor)
                if active_mode is None:
                    return None
                mode_name = str(active_mode[0])

            outputs.append([link_connector, mode_name, {}])

        applied.append(
            [int(x), int(y), float(scale), int(transform), bool(primary), outputs]
        )

    return applied


def apply_via_dbus(serial, logical_monitors):
    try:
        import dbus
    except ImportError:
        return False, "python3-dbus not installed"

    try:
        bus = dbus.SessionBus()
        proxy = bus.get_object(
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
        )
        iface = dbus.Interface(proxy, "org.gnome.Mutter.DisplayConfig")
        iface.ApplyMonitorsConfig(
            dbus.UInt32(serial),
            dbus.UInt32(1),
            logical_monitors,
            dbus.Dictionary({}, signature="sv"),
        )
        return True, ""
    except dbus.exceptions.DBusException as error:
        return False, str(error)
    except Exception as error:
        return False, str(error)


def format_gdbus_logical(logical_monitors):
    logical_parts = []

    for logical in logical_monitors:
        x, y, scale, transform, primary, outputs = logical
        output_parts = []
        for connector, mode_name, _props in outputs:
            output_parts.append(f"('{connector}', '{mode_name}', [])")

        primary_text = "true" if primary else "false"
        logical_parts.append(
            f"({x}, {y}, {scale}, {transform}, {primary_text}, "
            f"[{', '.join(output_parts)}])"
        )

    return f"[{', '.join(logical_parts)}]"


def apply_via_gdbus(serial, logical_monitors):
    if not shutil_which("gdbus"):
        return False, "gdbus not found"

    logical_text = format_gdbus_logical(logical_monitors)
    command = [
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.gnome.Mutter.DisplayConfig",
        "--object-path",
        "/org/gnome/Mutter/DisplayConfig",
        "--method",
        "org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig",
        str(serial),
        "1",
        logical_text,
        "{}",
    ]

    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
        return True, ""
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip() or error.stdout.strip() or str(error)
        return False, message


def shutil_which(command):
    from shutil import which

    return which(command)


def apply_monitors_config(serial, logical_monitors, proxy, Gio, GLib):
    ok, error = apply_via_dbus(serial, logical_monitors)
    if ok:
        return True, ""

    ok, error = apply_via_gdbus(serial, logical_monitors)
    if ok:
        return True, ""

    try:
        params = GLib.Variant(
            "(uua(iiduba(ssa{sv}))a{sv})",
            (serial, 1, logical_monitors, {}),
        )
        proxy.call_sync(
            "ApplyMonitorsConfig", params, Gio.DBusCallFlags.NONE, -1, None
        )
        return True, ""
    except GLib.Error as glib_error:
        return False, glib_error.message
    except Exception as other_error:
        return False, str(other_error) if str(other_error) else error


def cmd_get(proxy, Gio):
    _serial, monitors, logical_monitors, _properties = get_state(proxy, Gio)
    connector = primary_connector(logical_monitors)
    if not connector:
        print("unknown", file=sys.stderr)
        return 1

    monitor = monitor_by_connector(monitors, connector)
    if monitor is None:
        print(f"monitor not found: {connector}", file=sys.stderr)
        return 1

    active_mode = current_mode(monitor)
    refresh = mode_refresh_hz(active_mode)
    if refresh is None:
        print("unknown", file=sys.stderr)
        return 1

    print(refresh)
    return 0


def cmd_set(proxy, Gio, GLib, refresh_hz):
    serial, monitors, logical_monitors, _properties = get_state(proxy, Gio)
    connector = primary_connector(logical_monitors)
    if not connector:
        print("No logical monitor found", file=sys.stderr)
        return 1

    monitor = monitor_by_connector(monitors, connector)
    if monitor is None:
        print(f"monitor not found: {connector}", file=sys.stderr)
        return 1

    active_mode = current_mode(monitor)
    if active_mode is None:
        print("No active mode found", file=sys.stderr)
        return 1

    new_mode = mode_with_refresh(
        monitor, active_mode[1], active_mode[2], refresh_hz
    )
    if new_mode is None:
        print(
            f"Refresh rate {refresh_hz} Hz not available for "
            f"{active_mode[1]}x{active_mode[2]} on {connector}",
            file=sys.stderr,
        )
        return 1

    new_logical = build_apply_logical_monitors(
        logical_monitors, monitors, connector, new_mode[0]
    )
    if new_logical is None:
        print("Failed to build monitor configuration", file=sys.stderr)
        return 1

    ok, error = apply_monitors_config(serial, new_logical, proxy, Gio, GLib)
    if not ok:
        print(f"ApplyMonitorsConfig failed: {error}", file=sys.stderr)
        return 1

    print(round(float(refresh_hz)))
    return 0


def cmd_debug(proxy, Gio):
    serial, monitors, logical_monitors, properties = get_state(proxy, Gio)
    connector = primary_connector(logical_monitors)

    print(f"serial={serial}")
    print(f"primary_connector={connector}")
    print(f"logical_monitors={len(logical_monitors)} physical_monitors={len(monitors)}")

    for monitor in monitors:
        connector_name = monitor[0][0]
        active = current_mode(monitor)
        refresh = mode_refresh_hz(active)
        print(f"  {connector_name}: active={active[0] if active else None} refresh={refresh}")

    if properties:
        print(f"properties={properties}")

    return 0


def main():
    try:
        Gio = load_gio()
        from gi.repository import GLib
    except ImportError:
        print("python3-gi is required for GNOME refresh rate control", file=sys.stderr)
        return 1

    proxy = mutter_proxy(Gio)

    if len(sys.argv) == 2 and sys.argv[1] == "get":
        return cmd_get(proxy, Gio)

    if len(sys.argv) == 2 and sys.argv[1] == "debug":
        return cmd_debug(proxy, Gio)

    if len(sys.argv) == 3 and sys.argv[1] == "set":
        return cmd_set(proxy, Gio, GLib, int(sys.argv[2]))

    print("usage: gnome-display-rate.py get|set <60|90>|debug", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
