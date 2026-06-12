# piBrick pocketcm5 drivers

Kernel modules and user-space helpers for the piBrick CM5 handheld:

- **Display:** Visionox VTDR6110 / 9203 AMOLED (`panel-pibrick.9203.c`, `dts/vc4-kms-dsi-pibrick.dts`)
- **Touch:** Hynitron CST92xx (`hyn_driver_release_qm/`)
- **Battery:** BQ25895 PMIC without fuel gauge (`battery/bq25890_battery.c`)
- **Buttons:** Power/user GPIO daemon (`button-service/`)
- **Desktop:** Battery indicator and setup scripts (`desktop/`)

## Install

See [INSTALL.md](INSTALL.md):

```bash
sudo bash ./install.sh
```

Legacy panel variants and DTS files are kept under `archive/`.
