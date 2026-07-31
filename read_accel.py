#!/usr/bin/env python3
from smbus2 import SMBus
import time, statistics

bus = SMBus(1)
vals = []
for i in range(15):
    x = bus.read_word_data(0x1c, 0x01)
    y = bus.read_word_data(0x1c, 0x03)
    z = bus.read_word_data(0x1c, 0x05)
    xn = x if x < 32768 else x - 65536
    yn = y if y < 32768 else y - 65536
    zn = z if z < 32768 else z - 65536
    vals.append((xn, yn, zn))
    time.sleep(0.2)
bus.close()

xs = [v[0] for v in vals]
ys = [v[1] for v in vals]
zs = [v[2] for v in vals]

print("X: avg={:.0f}  range=[{}, {}]".format(statistics.mean(xs), min(xs), max(xs)))
print("Y: avg={:.0f}  range=[{}, {}]".format(statistics.mean(ys), min(ys), max(ys)))
print("Z: avg={:.0f}  range=[{}, {}]".format(statistics.mean(zs), min(zs), max(zs)))
