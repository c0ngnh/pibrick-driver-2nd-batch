#!/usr/bin/env python3
"""Watch accelerometer values during orientation transitions."""
import time, os, sys

base = "/sys/bus/iio/devices/iio:device0"

def read(name):
    try:
        with open(base + "/" + name) as f:
            return int(f.read().strip())
    except:
        return 0

print("Rotate device through all orientations. Press Ctrl+C to stop.")
print("Step   X          Y          Z          |X|   |Y|   |Z|   Dominant  Detect")
print("-" * 90)
step = 0
PORTRAIT_Z = 4096
tilt_threshold = 1500

try:
    while True:
        x = read("in_accel_x_raw")
        y = read("in_accel_y_raw")
        z = read("in_accel_z_raw")
        ax = abs(x); ay = abs(y); az = abs(z)

        # detect_orientation logic (matches pibrick-autorotation.sh)
        if ax >= ay and ax >= az: dom = "X"; dval = ax; second = ay if ay > az else az
        elif ay >= ax and ay >= az: dom = "Y"; dval = ay; second = ax if ax > az else az
        else: dom = "Z"; dval = az; second = ax if ax > ay else ay

        detect = ""
        if dval - second >= tilt_threshold and dval >= tilt_threshold:
            if dom == "Y":
                if az < PORTRAIT_Z: detect = "normal" if y < 0 else "inverted"
            elif dom == "X":
                if az >= PORTRAIT_Z: detect = "left" if x > 0 else "right"
            else: detect = ""

        print(f"{step:4d}  {x:9d}  {y:9d}  {z:9d}  {ax:5d}  {ay:5d}  {az:5d}  {dom}         {detect}")
        step += 1
        time.sleep(0.05)
except KeyboardInterrupt:
    print("\nDone")
