
obj-m += hyn_ts.o
# Touch follows panel power via the mainline drm_panel_follower API
# (CONFIG_DRM_PANEL), not the Qualcomm-only drm_panel_notifier.

MODEL_FILE := /proc/device-tree/model
MODEL_EXISTS := $(wildcard $(MODEL_FILE))
MODULE_NAME := hyn_ts.ko
MODULE_INSTALL_DIR := /lib/modules/$(shell uname -r)/kernel/drivers/input/touchscreen

hyn_ts-objs += hyn_core.o hyn_lib/hyn_i2c.o hyn_lib/hyn_ts_ext.o hyn_lib/hyn_fs_node.o
hyn_ts-objs += hyn_lib/hyn_tool.o
hyn_ts-objs += hyn_lib/hyn_gesture.o
hyn_ts-objs += hyn_lib/hyn_prox.o
hyn_ts-objs += hyn_chips/hyn_cst66xx.o

# Use $(CURDIR), not $(PWD): under `sudo make` the PWD env var is stripped,
# which would make M= empty and try to build the whole kernel instead.
modules:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) modules
	
clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) clean

touch: modules


install: remove
	install -m 644 -D $(MODULE_NAME) $(MODULE_INSTALL_DIR)
	depmod -a

remove:
	rm -rf $(MODULE_INSTALL_DIR)/$(MODULE_NAME)
