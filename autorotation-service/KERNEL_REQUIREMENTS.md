# MMA8451Q Autorotation Kernel Requirements
# ==========================================
#
# Based on piBrick AOSP17 V6 by Sconioo.
# https://github.com/Sconioo/pibrick-aosp17/releases/tag/v6
#
# This file documents the kernel configuration options required for
# MMA8451Q accelerometer-based autorotation support.
#

## Required Kernel Config

### IIO Subsystem Core
CONFIG_IIO=y              # Industrial I/O core support

### MMA845x Accelerometer Driver
# The mma8452 driver handles MMA8451, MMA8452, MMA8453, MMA8462, MMA8652, MMA8653
# Note: MMA8451Q uses the same mma8452 driver!
CONFIG_MMA8452=y          # Freescale MMA8451/2/3 accelerometer

## Quick Verification

# Check if driver is available:
zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_(IIO|MMA845)"

# Or check boot config:
cat /boot/config-$(uname -r) 2>/dev/null | grep -E "CONFIG_(IIO|MMA845)"

# Check if module is loaded:
lsmod | grep mma845

# Check IIO devices:
ls /sys/bus/iio/devices/

# Find MMA8451Q in IIO:
cat /sys/bus/iio/devices/*/name 2>/dev/null | grep -i mma

# Test accelerometer reading:
cat /sys/bus/iio/devices/iio:device*/in_accel_x_raw 2>/dev/null
cat /sys/bus/iio/devices/iio:device*/in_accel_y_raw 2>/dev/null
cat /sys/bus/iio/devices/iio:device*/in_accel_z_raw 2>/dev/null

## Raspberry Pi OS Kernel

Most Raspberry Pi OS kernels already have IIO and MMA8452 support.
If not, you'll need to build a custom kernel or use raspberrypi-kernel-headers
with a out-of-tree driver.

## Device Tree

The MMA8451Q should be added via device tree overlay on I2C1 at address 0x1C:

/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target = <&i2c1>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            status = "okay";

            accelerometer@1c {
                compatible = "fsl,mma8451";
                reg = <0x1c>;
                pibrick,invert-x;  /* piBrick-specific: invert X axis */
            };
        };
    };
};
