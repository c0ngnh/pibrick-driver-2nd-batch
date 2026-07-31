#!/usr/bin/env python3
import sys, time
from smbus2 import SMBus

bus = SMBus(1)
try:
    while True:
        x = bus.read_word_data(0x1c, 0x01)
        y = bus.read_word_data(0x1c, 0x03)
        z = bus.read_word_data(0x1c, 0x05)
        xn = x if x < 32768 else x - 65536
        yn = y if y < 32768 else y - 65536
        zn = z if z < 32768 else z - 65536
        sys.stdout.write(f"\r{xn:7d}  {yn:7d}  {zn:7d}   ")
        sys.stdout.flush()
        time.sleep(0.1)
finally:
    bus.close()
