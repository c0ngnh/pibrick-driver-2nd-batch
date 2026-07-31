#!/usr/bin/env python3
"""Watch Z values during a portrait rotation to find the transition point."""
from smbus2 import SMBus
import time, statistics

bus = SMBus(1)
print("Hold device LANDSCAPE, then rotate to PORTRAIT. Watching Z values...")
print("Step  X        Y        Z        |Z|    Dominant")
print("-" * 65)
try:
    step = 0
    while True:
        x = bus.read_word_data(0x1c, 0x01)
        y = bus.read_word_data(0x1c, 0x03)
        z = bus.read_word_data(0x1c, 0x05)
        xn = x if x < 32768 else x - 65536
        yn = y if y < 32768 else y - 65536
        zn = z if z < 32768 else z - 65536
        az = zn if zn >= 0 else -zn
        ax = xn if xn >= 0 else -xn
        ay = yn if yn >= 0 else -yn
        if ax >= ay and ax >= az: dom = "X"
        elif ay >= ax and ay >= az: dom = "Y"
        else: dom = "Z"
        print(f"{step:4d}  {xn:7d}  {yn:7d}  {zn:7d}  {az:5d}  {dom}")
        step += 1
        time.sleep(0.05)
except KeyboardInterrupt:
    print("\nDone")
finally:
    bus.close()
