obj-m += bq25890_battery.o
MODULE_NAME := bq25890_battery.ko
MODULE_INSTALL_DIR := /lib/modules/$(shell uname -r)/kernel/drivers/power/supply

# Resolve install location for Python tools.
# Order of preference:
#   1. PIBRICK_USER_HOME env var (set by install.sh)
#   2. $HOME/battery-tools (per-user install)
#   3. /usr/lib/pibrick/battery-tools (system-wide install)
PIBRICK_USER_HOME ?= $(HOME)/battery-tools
PIBRICK_TOOLS ?= $(if $(wildcard $(PIBRICK_USER_HOME)/battery_set.py),$(PIBRICK_USER_HOME),/usr/lib/pibrick/battery-tools)

.PHONY: modules clean install remove install-tools install-calibration install-service

modules:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(CURDIR) clean
	rm -rf *.dtbo

install: remove modules
	install -m 644 -D $(MODULE_NAME) $(MODULE_INSTALL_DIR)
	depmod -a
	@if command -v update-initramfs >/dev/null 2>&1; then \
		echo "Updating initramfs..."; \
		update-initramfs -u -k all || update-initramfs -u || true; \
	fi

remove:
	rm -rf $(MODULE_INSTALL_DIR)/$(MODULE_NAME)

# Install Python tools for battery management
install-tools: install
	@mkdir -p $(PIBRICK_TOOLS)
	@install -m 755 battery_set.py $(PIBRICK_TOOLS)/ 2>/dev/null || true
	@install -m 755 battery-check.py $(PIBRICK_TOOLS)/ 2>/dev/null || true
	@install -m 755 battery-soc-persist.py $(PIBRICK_TOOLS)/ 2>/dev/null || true
	@echo "Battery tools installed to $(PIBRICK_TOOLS)"

# Install calibration tools
install-calibration:
	@mkdir -p $(PIBRICK_TOOLS)
	@install -m 755 battery-calibration-logger.py $(PIBRICK_TOOLS)/ 2>/dev/null || true
	@install -m 755 battery-auto-calibrator.py $(PIBRICK_TOOLS)/ 2>/dev/null || true
	@mkdir -p /var/log/bq25890_battery
	@sed 's|__PIBRICK_TOOLS__|$(PIBRICK_TOOLS)|g' \
		pibrick-battery-calibration.service \
		> /etc/systemd/system/pibrick-battery-calibration.service
	@chmod 644 /etc/systemd/system/pibrick-battery-calibration.service
	@systemctl daemon-reload 2>/dev/null || true
	@echo "Calibration tools installed"

# Enable calibration service
enable-calibration: install-calibration
	@systemctl enable pibrick-battery-calibration.service 2>/dev/null || true
	@systemctl start pibrick-battery-calibration.service 2>/dev/null || true
	@echo "Calibration service enabled"

# Disable calibration service
disable-calibration:
	@systemctl stop pibrick-battery-calibration.service 2>/dev/null || true
	@systemctl disable pibrick-battery-calibration.service 2>/dev/null || true
	@echo "Calibration service disabled"

# Apply calibrated OCV table from /var/log/bq25890_battery/suggested_ocv_table.h
apply-calibration:
	@if [ -f /var/log/bq25890_battery/suggested_ocv_table.h ]; then \
		echo "Applying calibrated OCV table..."; \
		python3 $(PIBRICK_TOOLS)/battery-auto-calibrator.py --apply || \
		echo "Run 'python3 $(PIBRICK_TOOLS)/battery-auto-calibrator.py --apply' manually"; \
	else \
		echo "No calibrated OCV table found at /var/log/bq25890_battery/suggested_ocv_table.h"; \
		echo "Run calibration logger and analyze first"; \
	fi
