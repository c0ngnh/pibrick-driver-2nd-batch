# Panel variant: make amoled PANEL=9203|9202|548
PANEL ?= 9203

ifeq ($(PANEL),9203)
PANEL_SRC := panel-pibrick.9203.c
DTS_SRC := dts/vc4-kms-dsi-pibrick.dts
DTBO_NAME := vc4-kms-dsi-pibrick
else ifeq ($(PANEL),9202)
PANEL_SRC := panel-pibrick.9202.c
DTS_SRC := dts/vc4-kms-dsi-pibrick.dts
DTBO_NAME := vc4-kms-dsi-pibrick
else ifeq ($(PANEL),548)
PANEL_SRC := archive/panels/panel-pibrick-548inch.c
DTS_SRC := archive/dts/vc-548inch.dts
DTBO_NAME := vc-548inch
else
$(error Unknown PANEL=$(PANEL): use 9203, 9202, or 548)
endif

PANEL_OBJ := panel-pibrick.c
KNOWN_DTBO := vc4-kms-dsi-pibrick vc-548inch

obj-m += panel-pibrick.o
MODULE_NAME := panel-pibrick.ko
CONFIG_TXT := /boot/firmware/config.txt
OVERLAY_DIR := /boot/firmware/overlays
MODULE_INSTALL_DIR := /lib/modules/$(shell uname -r)/kernel/drivers/gpu/drm/panel

$(PANEL_OBJ): $(PANEL_SRC)
	rm -f $(PANEL_OBJ)
	ln -sf $(PANEL_SRC) $(PANEL_OBJ)

modules: $(PANEL_OBJ)
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) clean
	rm -f $(PANEL_OBJ) *.dtbo

amoled: modules
	dtc -I dts -O dtb -o $(DTBO_NAME).dtbo $(DTS_SRC)

install:
	@test -f $(MODULE_NAME) || { \
		echo "ERROR: $(MODULE_NAME) not built; refusing to remove the installed panel." >&2; \
		exit 1; \
	}
	@test -f $(DTBO_NAME).dtbo || { \
		echo "ERROR: $(DTBO_NAME).dtbo not built." >&2; \
		exit 1; \
	}
	$(MAKE) remove
	install -m 644 -D $(MODULE_NAME) $(MODULE_INSTALL_DIR)
	install -m 644 -D $(DTBO_NAME).dtbo $(OVERLAY_DIR)
	depmod -a
	grep -q '^ignore_lcd=1$$' $(CONFIG_TXT) 2>/dev/null || echo "ignore_lcd=1" >> $(CONFIG_TXT)
	grep -q '^dtoverlay=$(DTBO_NAME)$$' $(CONFIG_TXT) 2>/dev/null || echo "dtoverlay=$(DTBO_NAME)" >> $(CONFIG_TXT)
	@echo "Panel $(PANEL) installed from $(PANEL_SRC) with $(DTS_SRC). Please reboot to apply changes."

remove:
	rm -rf $(MODULE_INSTALL_DIR)/$(MODULE_NAME)
	@for name in $(KNOWN_DTBO); do \
		rm -rf $(OVERLAY_DIR)/$$name.dtbo; \
		sed -i "/dtoverlay=$$name/d" $(CONFIG_TXT); \
	done
	sed -i "/ignore_lcd=1/d" $(CONFIG_TXT)
