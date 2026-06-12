PANEL_SRC := panel-pibrick.9203.c
PANEL_OBJ := panel-pibrick.c

obj-m += panel-pibrick.o
DTBO_NAME := vc4-kms-dsi-pibrick
MODULE_NAME := panel-pibrick.ko
CONFIG_TXT := /boot/firmware/config.txt
OVERLAY_DIR := /boot/firmware/overlays
MODULE_INSTALL_DIR := /lib/modules/$(shell uname -r)/kernel/drivers/gpu/drm/panel

$(PANEL_OBJ): $(PANEL_SRC)
	ln -sf $(PANEL_SRC) $(PANEL_OBJ)

modules: $(PANEL_OBJ)
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
	rm -f $(PANEL_OBJ) *.dtbo

amoled: modules
	dtc -I dts -O dtb -o $(DTBO_NAME).dtbo dts/vc4-kms-dsi-pibrick.dts

install: remove
	install -m 644 -D $(MODULE_NAME) $(MODULE_INSTALL_DIR)
	install -m 644 -D $(DTBO_NAME).dtbo $(OVERLAY_DIR)
	depmod -a
	echo "ignore_lcd=1" >> $(CONFIG_TXT)
	echo "dtoverlay=$(DTBO_NAME)" >> $(CONFIG_TXT)
	echo "Please reboot to apply changes"

remove:
	rm -rf $(MODULE_INSTALL_DIR)/$(MODULE_NAME)
	rm -rf $(OVERLAY_DIR)/$(DTBO_NAME).dtbo
	sed -i "/ignore_lcd=1/d" $(CONFIG_TXT)
	sed -i "/dtoverlay=$(DTBO_NAME)/d" $(CONFIG_TXT)