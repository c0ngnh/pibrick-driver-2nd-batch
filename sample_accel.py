#!/usr/bin/env python3
"""Sample accelerometer to /tmp/accel_log.txt. Run for ~60s then stop."""
import time, os

base = "/sys/bus/iio/devices/iio:device0"

def read(name):
    try:
        with open(base + "/" + name) as f:
            return int(f.read().strip())
    except:
        return 0

PORTRAIT_Z = 4096
tilt_threshold = 1500
log_path = "/tmp/accel_log.txt"

with open(log_path, "w") as f:
    f.write("Step,X,Y,Z,absX,absY,absZ,Dominant,Detect\n")
    step = 0
    while step < 2000:  # ~100 seconds
        x = read("in_accel_x_raw")
        y = read("in_accel_y_raw")
        z = read("in_accel_z_raw")
        ax = abs(x); ay = abs(y); az = abs(z)

        if ax >= ay and ax >= az: dom = "X"; dval = ax; second = ay if ay > az else az
        elif ay >= ax and ay >= az: dom = "Y"; dval = ay; second = ax if ax > az else az
        else: dom = "Z"; dval = az; second = ax if ax > ay else ay

        detect = ""
        if dval - second >= tilt_threshold and dval >= tilt_threshold:
            if dom == "Y":
                if az < PORTRAIT_Z: detect = "normal" if y < 0 else "inverted"
            elif dom == "X":
                if az >= PORTRAIT_Z: detect = "left" if x > 0 else "right"

        f.write(f"{step},{x},{y},{z},{ax},{ay},{az},{dom},{detect}\n")
        f.flush()
        step += 1
        time.sleep(0.05)

print(f"Done. {step} samples logged to {log_path}")
