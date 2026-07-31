#!/usr/bin/env python3
"""
Sample accelerometer for ~60s to /tmp/accel_log.csv.
Run it, rotate the device through all 4 orientations, then press Ctrl+C.
Then cat the file to read the results.
"""
import time, os, signal

base = "/sys/bus/iio/devices/iio:device0"
LOG = "/tmp/accel_log.csv"

def read(name):
    try:
        with open(base + "/" + name) as f:
            return int(f.read().strip())
    except:
        return 0

# Detection parameters (must match pibrick-autorotation.sh)
TILT_THRESH = 1500
PORTRAIT_Z = 4096  # |Z| below this → portrait

def detect(x, y, z):
    ax = abs(x); ay = abs(y); az = abs(z)
    if ax >= ay and ax >= az: dom, dval, second = "X", ax, ay if ay > az else az
    elif ay >= ax and ay >= az: dom, dval, second = "Y", ay, ax if ax > az else az
    else: dom, dval, second = "Z", az, ax if ax > ay else ay

    if dval - second < TILT_THRESH or dval < TILT_THRESH:
        return "FLAT"
    if dom == "Y":
        if az < PORTRAIT_Z: return "normal" if y < 0 else "inverted"
    elif dom == "X":
        if az >= PORTRAIT_Z: return "left" if x > 0 else "right"
    return "FLAT"

sig_stop = [False]
def handler(sig, frame):
    sig_stop[0] = True
signal.signal(signal.SIGINT, handler)
signal.signal(signal.SIGTERM, handler)

print("Sampling accelerometer to", LOG)
print("Rotate through all 4 orientations. Press Ctrl+C when done.")
print()

step = 0
with open(LOG, "w") as f:
    f.write("step,x,y,z,absX,absY,absZ,detect\n")
    f.flush()
    while not sig_stop[0] and step < 1200:  # ~60s
        x = read("in_accel_x_raw")
        y = read("in_accel_y_raw")
        z = read("in_accel_z_raw")
        d = detect(x, y, z)
        f.write(f"{step},{x},{y},{z},{abs(x)},{abs(y)},{abs(z)},{d}\n")
        if step % 20 == 0:
            print(f"  step={step} x={x:7d} y={y:7d} z={z:7d} detect={d}")
        f.flush()
        step += 1
        time.sleep(0.05)

print(f"\nDone. {step} samples. Run: cat {LOG}")
