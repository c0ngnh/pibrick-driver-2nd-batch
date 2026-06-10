#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""piBrick taskbar readout: battery %, voltage, and clear time-to-full / time-left."""

import os
import sys

BATTERY = "/sys/class/power_supply/battery"
INTERVAL_SEC = 15
CHARGE_FULL_UAH = 5_000_000
CHARGE_CURRENT_MIN_UA = 100_000
DISCHARGE_CURRENT_UA = 1_300_000

try:
	import gi
	gi.require_version("Gtk", "3.0")
	from gi.repository import Gdk, GLib, Gtk
except ImportError:
	sys.stderr.write("pibrick-battery-indicator: python3-gi / Gtk 3 required\n")
	sys.exit(1)

USE_LAYER_SHELL = False
try:
	gi.require_version("GtkLayerShell", "0.1")
	from gi.repository import GtkLayerShell
	USE_LAYER_SHELL = True
except (ImportError, ValueError):
	pass


def read_sysfs_int(path):
	try:
		with open(path, encoding="ascii") as fh:
			return int(fh.read().strip())
	except (OSError, ValueError):
		return None


def read_sysfs_text(path):
	try:
		with open(path, encoding="ascii") as fh:
			return fh.read().strip()
	except OSError:
		return None


def format_duration(seconds):
	if seconds is None or seconds <= 0:
		return None
	hours = seconds // 3600
	minutes = (seconds % 3600) // 60
	if hours > 0:
		return f"{hours} h {minutes} min"
	if minutes > 0:
		return f"{minutes} min"
	return "< 1 min"


def estimate_time_seconds(status, capacity_pct, current_ua):
	if capacity_pct is None:
		return None, None

	if status == "Charging":
		seconds = read_sysfs_int(os.path.join(BATTERY, "time_to_full_now"))
		if seconds is None or seconds <= 0:
			if current_ua is None or current_ua < CHARGE_CURRENT_MIN_UA:
				return "to full", None
			if capacity_pct >= 100:
				return "to full", 0
			remaining_uah = (100 - capacity_pct) * CHARGE_FULL_UAH // 100
			seconds = remaining_uah * 3600 // current_ua
		return "to full", seconds

	if status == "Discharging":
		seconds = read_sysfs_int(os.path.join(BATTERY, "time_to_empty_avg"))
		if seconds is None or seconds <= 0:
			if capacity_pct <= 0:
				return "left", 0
			charge_now_uah = capacity_pct * CHARGE_FULL_UAH // 100
			seconds = charge_now_uah * 3600 // DISCHARGE_CURRENT_UA
		return "left", seconds

	return None, None


def read_battery():
	capacity_pct = read_sysfs_int(os.path.join(BATTERY, "capacity"))
	voltage_uv = read_sysfs_int(os.path.join(BATTERY, "voltage_now"))
	current_ua = read_sysfs_int(os.path.join(BATTERY, "current_now"))
	status = read_sysfs_text(os.path.join(BATTERY, "status"))
	if capacity_pct is None or voltage_uv is None or not status:
		return None

	time_kind, time_seconds = estimate_time_seconds(status, capacity_pct, current_ua)
	return {
		"capacity_pct": capacity_pct,
		"volts": voltage_uv / 1_000_000,
		"status": status,
		"time_kind": time_kind,
		"time_seconds": time_seconds,
	}


class BatteryIndicator(Gtk.Window):
	def __init__(self):
		super().__init__(title="piBrick Battery")
		self.set_decorated(False)
		self.set_resizable(False)
		self.set_app_paintable(True)

		self.frame = Gtk.EventBox()
		self.frame.get_style_context().add_class("pibrick-battery-indicator")
		self.add(self.frame)

		self.label = Gtk.Label()
		self.label.set_margin_start(10)
		self.label.set_margin_end(10)
		self.label.set_margin_top(5)
		self.label.set_margin_bottom(5)
		self.frame.add(self.label)

		if USE_LAYER_SHELL:
			GtkLayerShell.init_for_window(self)
			GtkLayerShell.set_layer(self, GtkLayerShell.Layer.TOP)
			GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
			GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.RIGHT, True)
			GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, 4)
			GtkLayerShell.set_margin(self, GtkLayerShell.Edge.RIGHT, 96)
		else:
			self.set_keep_above(True)
			self.set_type_hint(Gdk.WindowTypeHint.DOCK)
			self.stick()

		self.show_all()
		if not USE_LAYER_SHELL:
			self._place_top_right()

		self.refresh()
		GLib.timeout_add_seconds(INTERVAL_SEC, self._on_timer)

	def _place_top_right(self):
		display = Gdk.Display.get_default()
		if not display:
			return
		monitor = display.get_primary_monitor()
		if not monitor:
			return
		geometry = monitor.get_geometry()
		width, _height = self.get_size()
		self.move(max(geometry.x, geometry.x + geometry.width - width - 96),
			  geometry.y + 4)

	def _on_timer(self):
		self.refresh()
		return True

	def _time_suffix(self, data):
		time_text = format_duration(data["time_seconds"])
		if not time_text or not data["time_kind"]:
			return ""

		if data["time_kind"] == "to full":
			return f" · {time_text} to full"
		return f" · {time_text} left"

	def _tooltip_text(self, data):
		time_text = format_duration(data["time_seconds"])
		status = data["status"]
		pct = data["capacity_pct"]
		volts = data["volts"]

		if status in ("Full", "Not charging"):
			label = "Fully charged" if status == "Full" else "Charged (on AC)"
			return f"{label}\n{pct}%  {volts:.2f} V"

		if status == "Charging":
			if time_text:
				return (
					f"Charging\n"
					f"Time to full: {time_text}\n"
					f"{pct}%  {volts:.2f} V"
				)
			return f"Charging\n{pct}%  {volts:.2f} V"

		if status == "Discharging":
			if time_text:
				return (
					f"On battery\n"
					f"Time left: {time_text}\n"
					f"{pct}%  {volts:.2f} V"
				)
			return f"On battery\n{pct}%  {volts:.2f} V"

		if time_text and data["time_kind"] == "left":
			return f"{status}\nTime left: {time_text}\n{pct}%  {volts:.2f} V"
		return f"{status}\n{pct}%  {volts:.2f} V"

	def refresh(self):
		data = read_battery()
		if not data:
			self.label.set_text("BAT --")
			self.frame.set_has_tooltip(False)
			return

		pct = data["capacity_pct"]
		volts = data["volts"]
		suffix = self._time_suffix(data)
		self.label.set_markup(
			f'<span size="small"><b>{pct}%</b>  {volts:.2f}V{suffix}</span>'
		)
		self.frame.set_has_tooltip(True)
		self.frame.set_tooltip_text(self._tooltip_text(data))
		if not USE_LAYER_SHELL:
			self._place_top_right()


def main():
	app = BatteryIndicator()
	Gtk.main()


if __name__ == "__main__":
	main()
