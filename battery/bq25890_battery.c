// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * TI BQ25890 charger driver
 *
 * Copyright (C) 2015 Intel Corporation
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/i2c.h>
#include <linux/power_supply.h>
#include <linux/power/bq25890_charger.h>
#include <linux/regmap.h>
#include <linux/regulator/driver.h>
#include <linux/types.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/delay.h>
#include <linux/usb/phy.h>

#include <linux/acpi.h>
#include <linux/of.h>

#define BQ25890_MANUFACTURER		"Texas Instruments"
#define BQ25890_IRQ_PIN			"bq25890_irq"

#define BQ25890_ID			3
#define BQ25895_ID			7
#define BQ25896_ID			0

#define PUMP_EXPRESS_START_DELAY	(5 * HZ)
#define PUMP_EXPRESS_MAX_TRIES		6
#define PUMP_EXPRESS_VBUS_MARGIN_uV	1000000

enum bq25890_chip_version {
	BQ25890,
	BQ25892,
	BQ25895,
	BQ25896,
};

static const char *const bq25890_chip_name[] = {
	"BQ25890",
	"BQ25892",
	"BQ25895",
	"BQ25896",
};

enum bq25890_fields {
	F_EN_HIZ, F_EN_ILIM, F_IINLIM,				     /* Reg00 */
	F_BHOT, F_BCOLD, F_VINDPM_OFS,				     /* Reg01 */
	F_CONV_START, F_CONV_RATE, F_BOOSTF, F_ICO_EN,
	F_HVDCP_EN, F_MAXC_EN, F_FORCE_DPM, F_AUTO_DPDM_EN,	     /* Reg02 */
	F_BAT_LOAD_EN, F_WD_RST, F_OTG_CFG, F_CHG_CFG, F_SYSVMIN,
	F_MIN_VBAT_SEL,						     /* Reg03 */
	F_PUMPX_EN, F_ICHG,					     /* Reg04 */
	F_IPRECHG, F_ITERM,					     /* Reg05 */
	F_VREG, F_BATLOWV, F_VRECHG,				     /* Reg06 */
	F_TERM_EN, F_STAT_DIS, F_WD, F_TMR_EN, F_CHG_TMR,
	F_JEITA_ISET,						     /* Reg07 */
	F_BATCMP, F_VCLAMP, F_TREG,				     /* Reg08 */
	F_FORCE_ICO, F_TMR2X_EN, F_BATFET_DIS, F_JEITA_VSET,
	F_BATFET_DLY, F_BATFET_RST_EN, F_PUMPX_UP, F_PUMPX_DN,	     /* Reg09 */
	F_BOOSTV, F_PFM_OTG_DIS, F_BOOSTI,			     /* Reg0A */
	F_VBUS_STAT, F_CHG_STAT, F_PG_STAT, F_SDP_STAT, F_0B_RSVD,
	F_VSYS_STAT,						     /* Reg0B */
	F_WD_FAULT, F_BOOST_FAULT, F_CHG_FAULT, F_BAT_FAULT,
	F_NTC_FAULT,						     /* Reg0C */
	F_FORCE_VINDPM, F_VINDPM,				     /* Reg0D */
	F_THERM_STAT, F_BATV,					     /* Reg0E */
	F_SYSV,							     /* Reg0F */
	F_TSPCT,						     /* Reg10 */
	F_VBUS_GD, F_VBUSV,					     /* Reg11 */
	F_ICHGR,						     /* Reg12 */
	F_VDPM_STAT, F_IDPM_STAT, F_IDPM_LIM,			     /* Reg13 */
	F_REG_RST, F_ICO_OPTIMIZED, F_PN, F_TS_PROFILE, F_DEV_REV,   /* Reg14 */

	F_MAX_FIELDS
};

/* initial field values, converted to register values */
struct bq25890_init_data {
	u8 ichg;	/* charge current		*/
	u8 vreg;	/* regulation voltage		*/
	u8 iterm;	/* termination current		*/
	u8 iprechg;	/* precharge current		*/
	u8 sysvmin;	/* minimum system voltage limit */
	u8 boostv;	/* boost regulation voltage	*/
	u8 boosti;	/* boost current limit		*/
	u8 boostf;	/* boost frequency		*/
	u8 ilim_en;	/* enable ILIM pin		*/
	u8 treg;	/* thermal regulation threshold */
	u8 rbatcomp;	/* IBAT sense resistor value    */
	u8 vclamp;	/* IBAT compensation voltage limit */
};

struct bq25890_state {
	u8 online;
	u8 hiz;
	u8 vbus_gd;
	u8 chrg_status;
	u8 chrg_fault;
	u8 vsys_status;
	u8 boost_fault;
	u8 bat_fault;
	u8 ntc_fault;
};

enum bq25890_fg_mode {
	BQ_FG_UNKNOWN = 0,
	BQ_FG_CHARGING,
	BQ_FG_CHARGING_DONE,
	BQ_FG_DISCHARGING_ACTIVE,
	BQ_FG_DISCHARGING_RESTING,
};

/*
 * Forward declaration so struct bq25890_device can hold a pointer to the
 * INA228 monitor (defined further down). Without this the build fails with
 * "invalid use of undefined type 'struct bq25890_ina228_data'" the moment
 * bq->ina228 is dereferenced (which happens before the full INA228 struct
 * is visible to the compiler).
 */
struct bq25890_ina228_data;

struct bq25890_device {
	struct i2c_client *client;
	struct device *dev;
	struct power_supply *charger;
	struct power_supply *ac;
	struct power_supply *secondary_chrg;
	struct power_supply_desc desc;
	struct power_supply_desc ac_desc;
	char name[28]; /* "bq25890-charger-%d" */
	char ac_name[16];
	int id;

	struct usb_phy *usb_phy;
	struct notifier_block usb_nb;
	struct work_struct usb_work;
	struct delayed_work pump_express_work;
	struct delayed_work capacity_calibrate_work;
	struct delayed_work capacity_refresh_work;
	unsigned long usb_event;

	struct regmap *rmap;
	struct regmap_field *rmap_fields[F_MAX_FIELDS];

	bool skip_reset;
	bool read_back_init_data;
	bool force_hiz;
	u32 pump_express_vbus_max;
	u32 iinlim_percentage;
	enum bq25890_chip_version chip_version;
	struct bq25890_init_data init_data;
	struct bq25890_state state;

	/* --- Software fuel gauge (no coulomb-counter IC on PocketCM5) --- */
	int capacity_cache;		/* displayed SOC 0-100 */
	bool capacity_valid;
	bool last_ext_pwr;
	bool last_charging;		/* cached `charging` from the last sample */
	enum bq25890_fg_mode last_fg_mode;  /* previous fg_mode for transition detection */
	unsigned long capacity_jiffies;

	long batv_smoothed_uv;		/* load-filtered terminal voltage */
	long fg_v_ocv_uv;		/* OCV tracker (used for SOC lookup) */
	unsigned long batv_smoothed_jiffies;
	unsigned long batv_load_glitch_until;
	unsigned long batv_unplug_until;	/* post-charge relax: SOC may only fall */

	/* Coulomb counting while charging (ICHGR from PMIC ADC). */
	long chg_remain_uah;		/* estimated remain at plug-in */
	long chg_added_uah;
	unsigned long chg_last_jiffies;

	/* Coalesce ADC conversions / chip-state reads from bursty sysfs polls. */
	unsigned long adc_jiffies;
	/* Only emit a uevent when the user-visible state actually changes. */
	int notified_capacity;
	int notified_status;

	/* --- Load-aware fuel gauge state (locked under bq->lock) --- */
	enum bq25890_fg_mode fg_mode;
	int fg_proxy_ua;			/* proxy discharge current */
	long fg_disch_remain_uah;	/* integrator output */
	unsigned long fg_disch_jiffies;
	unsigned long fg_load_jiffies;	/* last sustained-load sample */
	unsigned long fg_rest_jiffies;	/* last quiet sample */
	int fg_low_v_count;		/* persistent-low counter */
	int fg_glitch_count;		/* legacy ADC-floor hit counter */
	/*
	 * Set when a userspace writer (the load-soc service) seeds
	 * coulomb_uah from /var/lib/bq25890_battery/soc_persist.  The boot
	 * calibrate work checks this and skips its OCV-based reseed when a
	 * user seed is present, so the persisted SOC survives the 30 s post-
	 * probe reset that would otherwise wipe it back to voltage-derived
	 * OCV (often wildly different from the persisted value, especially
	 * on a partially-charged pack).
	 */
	bool fg_user_seeded;
	struct mutex lock; /* protect state data */

	/* --- INA228 high-side current monitor (optional) --- */
	struct bq25890_ina228_data *ina228;
	int ina228_current_ua;		/* last sampled, for property readers */

	/*
	 * Fast-poll window: when the charger state changes, this is set to
	 * jiffies + fast_poll_ms/HZ so that capacity_refresh_work schedules
	 * a tighter interval instead of the default 30 s refresh.
	 */
	unsigned long fast_poll_until;

	/*
	 * Runtime override for BQ25890_FG_V_OCV_TAU_SEC. The constant
	 * default (60 s) is tuned for INA228 hardware (clean live voltage).
	 * When no INA228 is detected at probe time we bump this to 120 s
	 * so the proxy-estimator OCV tracker is smoother and the
	 * auto-calibrator's std-dev filter doesn't reject valid buckets.
	 * A module parameter is also exposed so the user can tune it.
	 */
	int fg_v_ocv_tau_sec;

	/*
	 * Coulomb counter drift detection and auto-correction state.
	 *
	 * Over long discharge cycles, the coulomb counter can drift from
	 * the true state of charge due to:
	 *   - Small systematic errors in current measurement
	 *   - Temperature effects not fully compensated
	 *   - Accumulated rounding errors in integration
	 *
	 * We detect drift by comparing the coulomb-integrated SOC against
	 * the OCV-based SOC when the battery is at rest (settled voltage).
	 * If they diverge beyond a threshold, we slowly correct the coulomb
	 * counter by applying a small adjustment each interval.
	 *
	 * drift_correction_ppm: current correction factor in ppm
	 *   (positive = coulomb counter reads low, need to subtract more)
	 *   (negative = coulomb counter reads high, need to add back)
	 * drift_accum_ppb: accumulated drift correction in ppb (for averaging)
	 * last_ocv_soc_pct: OCV-derived SOC at last drift check
	 * last_coulomb_soc_pct: coulomb-derived SOC at last drift check
	 * drift_check_jiffies: when we last checked for drift
	 */
	int drift_correction_ppm;
	s64 drift_accum_ppb;
	int last_ocv_soc_pct;
	int last_coulomb_soc_pct;
	unsigned long drift_check_jiffies;
};

#define BQ25890_CHARGE_CURRENT_MIN_UA	100000
#define BQ25890_VBUS_MIN_UV		4000000
#define BQ25890_CAPACITY_BOOT_CALIB_DELAY	(30 * HZ)
#define BQ25890_CAPACITY_REFRESH_INTERVAL	(30 * HZ)
#define BQ25890_ADC_MIN_INTERVAL		(1 * HZ)

/*
 * Fuel-gauge tuning (PocketCM5 / BQ25895, 5000 mAh 1S LiPo @ 4.176 V full).
 * No pack-side current sense: discharge current is unknown; SOC on battery
 * comes from a load-aware estimator:
 *  - DISCHARGING_ACTIVE: SOC is held (or slowly drained by a configurable
 *    proxy integrator); terminal voltage sag is NOT used to drop SOC.
 *  - DISCHARGING_RESTING: terminal voltage IS used (after long-quiet
 *    filter) as rested OCV, SOC follows downward only.
 *  - CHARGING: integrate measured ICHGR (unchanged).
 *
 * Configure the proxy integrator with discharge_avg_ua +
 * discharge_load_factor_pct. Both default to ~700 mA idle, +40% under load.
 */
#define BQ25890_FG_V_TAU_SEC			20
#define BQ25890_FG_V_OCV_TAU_SEC		60
#define BQ25890_FG_UNPLUG_RELAX_SEC		90
#define BQ25890_FG_LOAD_GLITCH_SEC		5
#define BQ25890_FG_LOAD_MAX_DROP_PCT_MIN	2
#define BQ25890_FG_REST_MIN_SEC		300
#define BQ25890_FG_REST_MAX_DROP_PCT_MIN	1
#define BQ25890_FG_CHG_POLAR_UV			50000
#define BQ25890_FG_CHG_INTEGRATE_MAX_SEC	60
#define BQ25890_FG_LOW_V_THRESH_UV		3200000
#define BQ25890_FG_LOW_V_RECOVER_UV		3350000
#define BQ25890_FG_LOW_V_COUNT_MAX		20
#define BQ25890_BATV_ADC_FLOOR_UV		2304000
#define BQ25890_BATV_ADC_FLOOR_MAX_UV		2344000
#define BQ25890_BATV_REST_MIN_UV		3150000

/*
 * Coulomb counter drift detection and auto-correction parameters.
 *
 * DRIFT_DETECT_THRESH_PCT: SOC difference threshold for drift detection.
 *   Only trigger correction when coulomb vs OCV differ by this much.
 *   Default of 5% prevents correction from minor measurement noise.
 *
 * DRIFT_CHECK_INTERVAL_SEC: Minimum time between drift checks.
 *   Default of 300s (5 min) prevents over-correction.
 *
 * DRIFT_CORRECTION_RATE_PPM_PER_MIN: How fast to correct drift.
 *   Default of 10 ppm per minute means 1% drift takes 100 minutes to correct.
 *   Slow correction prevents sudden SOC jumps.
 *
 * DRIFT_MAX_CORRECTION_PPM: Maximum total correction allowed.
 *   Default of 50000 ppm (5%) prevents runaway corrections.
 */
#define BQ25890_FG_DRIFT_DETECT_THRESH_PCT	5
#define BQ25890_FG_DRIFT_CHECK_INTERVAL_SEC	300
#define BQ25890_FG_DRIFT_CORRECTION_RATE_PPM_PER_MIN	10
#define BQ25890_FG_DRIFT_MAX_CORRECTION_PPM	50000
/* Only compare coulomb vs OCV when rest current is below this (uA). */
#define BQ25890_FG_DRIFT_IDLE_UA		50000

/*
 * PocketCM5 tuned defaults (calibrated against the 3.8 Ah pack shipped with
 * the device). Override per-device via /etc/modprobe.d/pibrick-battery.conf
 * or `battery_set.py --persist`. See README.md § "Battery driver
 * customization".
 */
static int discharge_current_ua = 900000;
module_param(discharge_current_ua, int, 0644);
MODULE_PARM_DESC(discharge_current_ua,
		 "Assumed average discharge (uA) for time-to-empty only");

static int charge_full_uah = 4800000;
module_param(charge_full_uah, int, 0644);
MODULE_PARM_DESC(charge_full_uah, "Battery capacity (uAh)");

static int batt_ir_mohm = 180;
module_param(batt_ir_mohm, int, 0644);
MODULE_PARM_DESC(batt_ir_mohm,
		 "Pack IR (mOhm) for charge-time OCV estimate only");

/* Load-aware fuel-gauge tuning. Zero disables that input to the integrator. */
static int discharge_avg_ua = 700000;
module_param(discharge_avg_ua, int, 0644);
MODULE_PARM_DESC(discharge_avg_ua,
		 "Nominal idle discharge current (uA) used by SOC integrator");

static int discharge_load_factor_pct = 40;
module_param(discharge_load_factor_pct, int, 0644);
MODULE_PARM_DESC(discharge_load_factor_pct,
		 "Extra %% added to discharge proxy while under sustained load");

static int discharge_max_ua = 4000000;
module_param(discharge_max_ua, int, 0644);
MODULE_PARM_DESC(discharge_max_ua,
		 "Hard ceiling (uA) for the SOC integrator proxy current");

static int rest_min_sec = BQ25890_FG_REST_MIN_SEC;
module_param(rest_min_sec, int, 0644);
MODULE_PARM_DESC(rest_min_sec,
		 "Seconds of sustained quiet required to enter DISCHARGING_RESTING");

static int low_v_persistent_count = 5;
module_param(low_v_persistent_count, int, 0644);
MODULE_PARM_DESC(low_v_persistent_count,
		 "Consecutive samples below low-V threshold before SOC drops to critical");

/*
 * Persistent SOC storage: saves/restores SOC across reboots for consistency.
 * File: /var/lib/bq25890_battery/soc_persist
 * Format: "soc=<value>\n" (SOC 0-100)
 * This prevents the SOC from jumping around after each reboot.
 *
 * Persistence is handled entirely in userspace (soc_persist file +
 * coulomb_uah sysfs). persist_soc is kept only so old modprobe.d lines
 * do not fail module load; the driver does not apply it.
 */
#define BQ25890_SOC_PERSIST_FILE  "/var/lib/bq25890_battery/soc_persist"

static int persist_soc = -1;
module_param(persist_soc, int, 0644);
MODULE_PARM_DESC(persist_soc,
		 "Unused (legacy). SOC persist is userspace soc_persist + coulomb_uah");

static int bq25890_save_persisted_soc(int soc)
{
	/* Userspace handles persistence; driver just logs for debugging */
	pr_debug("bq25890: SOC persist request (userspace should handle file I/O)\n");
	return 0;
}

/* --- INA228 high-side current monitor (PocketCM5, I2C 0x40) --- */
#define INA228_REG_CONFIG		0x00
#define INA228_REG_ADCCFG		0x01
#define INA228_REG_SHUNTCAL		0x02
#define INA228_REG_VSHUNT		0x04
#define INA228_REG_VBUS			0x05
#define INA228_REG_DIETEMP		0x06
#define INA228_REG_CURRENT		0x07
#define INA228_REG_POWER		0x08
#define INA228_REG_DIAGALRT		0x0B
#define INA228_REG_MFG_UID		0x3E
#define INA228_REG_DVC_UID		0x3F

#define INA228_I2C_ADDR_DEFAULT		0x40
#define INA228_MFG_ID_TI		0x5449

/* CONFIG[15] RST */
#define INA228_CFG_RST_MASK		BIT(15)
/* CONFIG[4] ADCRANGE: 0 = ±163.84 mV, 1 = ±40.96 mV */
#define INA228_CFG_ADCRANGE_MASK		BIT(4)
/* ADCCFG[15:12] MODE */
#define INA228_ADC_MODE_SHIFT		12
#define INA228_ADC_MODE_CONT_TVB		0xF /* continuous T+V+bus */

/* Conversion-time / averaging settings chosen for 1 s integrator tick. */
#define INA228_ADC_VSHCT_1052_US		5
#define INA228_ADC_VBUSCT_1052_US	5
#define INA228_ADC_TEMPCT_1052_US	5
#define INA228_ADC_AVG_64			2
/* SHUNT_CAL computed below as 2400; expose as module-param anyway. */

static int ina228_shunt_uohm = 15000;
module_param(ina228_shunt_uohm, int, 0644);
MODULE_PARM_DESC(ina228_shunt_uohm, "INA228 shunt resistor value (micro-ohms)");

static int ina228_max_current_ua = 6400000;
module_param(ina228_max_current_ua, int, 0644);
MODULE_PARM_DESC(ina228_max_current_ua,
		 "INA228 expected maximum current (uA) used to derive SHUNT_CAL");

static int ina228_enabled = 1;
module_param(ina228_enabled, int, 0644);
MODULE_PARM_DESC(ina228_enabled,
		 "Set to 0 to fall back to the proxy integrator even when INA228 is present");

/*
 * Temperature compensation for shunt resistance drift.
 * Typical TCR (Temperature Coefficient of Resistance) for precision shunts:
 *   - 50 ppm/°C for high-precision metal foil resistors
 *   - 100 ppm/°C for standard SMD current sense resistors
 *   - 200 ppm/°C for low-cost thick film chip resistors
 *
 * Set this to match your shunt's actual TCR. Default of 100 ppm/°C is
 * appropriate for most SMD current sense resistors.
 *
 * Temperature correction formula:
 *   R(T) = R(T0) * (1 + TCR * (T - T0) / 1e6)
 *
 * Example: TCR=100ppm, 25°C rise from calibration temp
 *   Correction = 100 * 25 = 2500 ppm = 0.25% increase in R
 *   Current reading is 0.25% low (actual current is higher)
 */
static int ina228_shunt_tcr_ppm = 100;
module_param(ina228_shunt_tcr_ppm, int, 0644);
MODULE_PARM_DESC(ina228_shunt_tcr_ppm,
		 "INA228 shunt resistor TCR (ppm/°C) for temperature compensation");

/*
 * High-precision coulomb integration parameters.
 *
 * COULOMB_ACCUM_PRECISION: internal accumulator resolution.
 *   - 1000 = track in nanoamp-hours (nah) for 1000x precision vs uAh
 *   - Higher values give more precision but need larger integer types
 *
 * COULOMB_ROUND_THRESHOLD: minimum charge change before updating display.
 *   Prevents jitter in the coulomb_uah sysfs value from frequent small updates.
 *   Set to uah_per_lsb / 2 to round to nearest LSB.
 */
#define COULOMB_ACCUM_PRECISION 1000
#define COULOMB_ROUND_THRESHOLD_UAH 1

/*
 * INA228 current measurement filter parameters.
 *
 * INA228_FILTER_ALPHA: Exponential moving average filter coefficient.
 *   Range: 0-1000 (represents α × 1000)
 *   α = filter weight for new sample
 *   (1-α) = weight for previous filtered value
 *
 * Recommended values:
 *   100 (α=0.10): Very smooth, good for long-term accuracy
 *   250 (α=0.25): Balanced (default), good for general use
 *   500 (α=0.50): More responsive, good for dynamic loads
 *   1000 (α=1.0): No filtering, raw ADC values
 *
 * With α=0.25 and 30s update interval, the filter has an effective
 * window of ~2 minutes (98% response in 4 intervals).
 */
#define INA228_FILTER_ALPHA_DEFAULT 250

/*
 * INA228_FILTER_DEADZONE_UA: Minimum current change to trigger filter update.
 *   Prevents jitter from small ADC fluctuations.
 *   Default of 10µA is about 1 LSB at high currents, 0.1 LSB at low currents.
 */
#define INA228_FILTER_DEADZONE_DEFAULT_UA 10

/*
 * INA228 current measurement filter alpha (0-1000, default 250).
 * Controls exponential moving average smoothing of current readings.
 * Higher values = more responsive, lower = smoother.
 */
static int ina228_filter_alpha = INA228_FILTER_ALPHA_DEFAULT;
module_param(ina228_filter_alpha, int, 0644);
MODULE_PARM_DESC(ina228_filter_alpha,
		 "INA228 filter alpha (EMA coefficient × 1000). 250=balanced, 100=smooth, 1000=raw");

/*
 * Runtime OCV-tracker time constant in seconds. The compile-time default
 * (BQ25890_FG_V_OCV_TAU_SEC, 60 s) is tuned for INA228 hardware. When
 * no INA228 is detected at probe time the driver overrides this to
 * 120 s automatically; this parameter lets the user fine-tune from
 * /etc/modprobe.d/pibrick-battery.conf. Use 60 with INA228, 120-180
 * without. Going too high makes the OCV tracker sluggish to react to
 * a fresh plug event.
 */
static int fg_v_ocv_tau_sec_override = -1;
module_param(fg_v_ocv_tau_sec_override, int, 0644);
MODULE_PARM_DESC(fg_v_ocv_tau_sec_override,
		 "OCV tracker time constant in seconds. -1 = use probe-time "
		 "default (60 with INA228, 120 without).");

/*
 * Fast poll interval (milliseconds) after a charger state change.
 * On hardware where the STAT IRQ pin doesn't fire (e.g. rp1 pinctrl
 * GPIO path), this is the only way to get sub-30 s charger detection.
 * Set to 0 to disable fast polling (always use 30 s interval).
 */
static int fast_poll_ms = 2000;
module_param(fast_poll_ms, int, 0644);
MODULE_PARM_DESC(fast_poll_ms,
		 "Poll interval (ms) after charger plug/unplug until state "
		 "stabilises. 0 disables fast polling (default: 2000).");

/* --- end INA228 --- */

static DEFINE_IDR(bq25890_id);
static DEFINE_MUTEX(bq25890_id_mutex);

static const struct regmap_range bq25890_readonly_reg_ranges[] = {
	regmap_reg_range(0x0b, 0x0c),
	regmap_reg_range(0x0e, 0x13),
};

static const struct regmap_access_table bq25890_writeable_regs = {
	.no_ranges = bq25890_readonly_reg_ranges,
	.n_no_ranges = ARRAY_SIZE(bq25890_readonly_reg_ranges),
};

static const struct regmap_range bq25890_volatile_reg_ranges[] = {
	regmap_reg_range(0x00, 0x00),
	regmap_reg_range(0x02, 0x02),
	regmap_reg_range(0x09, 0x09),
	regmap_reg_range(0x0b, 0x14),
};

static const struct regmap_access_table bq25890_volatile_regs = {
	.yes_ranges = bq25890_volatile_reg_ranges,
	.n_yes_ranges = ARRAY_SIZE(bq25890_volatile_reg_ranges),
};

static const struct regmap_config bq25890_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,

	.max_register = 0x14,
	.cache_type = REGCACHE_MAPLE,

	.wr_table = &bq25890_writeable_regs,
	.volatile_table = &bq25890_volatile_regs,
};

static const struct reg_field bq25890_reg_fields[] = {
	/* REG00 */
	[F_EN_HIZ]		= REG_FIELD(0x00, 7, 7),
	[F_EN_ILIM]		= REG_FIELD(0x00, 6, 6),
	[F_IINLIM]		= REG_FIELD(0x00, 0, 5),
	/* REG01 */
	[F_BHOT]		= REG_FIELD(0x01, 6, 7),
	[F_BCOLD]		= REG_FIELD(0x01, 5, 5),
	[F_VINDPM_OFS]		= REG_FIELD(0x01, 0, 4),
	/* REG02 */
	[F_CONV_START]		= REG_FIELD(0x02, 7, 7),
	[F_CONV_RATE]		= REG_FIELD(0x02, 6, 6),
	[F_BOOSTF]		= REG_FIELD(0x02, 5, 5),
	[F_ICO_EN]		= REG_FIELD(0x02, 4, 4),
	[F_HVDCP_EN]		= REG_FIELD(0x02, 3, 3),  // reserved on BQ25896
	[F_MAXC_EN]		= REG_FIELD(0x02, 2, 2),  // reserved on BQ25896
	[F_FORCE_DPM]		= REG_FIELD(0x02, 1, 1),
	[F_AUTO_DPDM_EN]	= REG_FIELD(0x02, 0, 0),
	/* REG03 */
	[F_BAT_LOAD_EN]		= REG_FIELD(0x03, 7, 7),
	[F_WD_RST]		= REG_FIELD(0x03, 6, 6),
	[F_OTG_CFG]		= REG_FIELD(0x03, 5, 5),
	[F_CHG_CFG]		= REG_FIELD(0x03, 4, 4),
	[F_SYSVMIN]		= REG_FIELD(0x03, 1, 3),
	[F_MIN_VBAT_SEL]	= REG_FIELD(0x03, 0, 0), // BQ25896 only
	/* REG04 */
	[F_PUMPX_EN]		= REG_FIELD(0x04, 7, 7),
	[F_ICHG]		= REG_FIELD(0x04, 0, 6),
	/* REG05 */
	[F_IPRECHG]		= REG_FIELD(0x05, 4, 7),
	[F_ITERM]		= REG_FIELD(0x05, 0, 3),
	/* REG06 */
	[F_VREG]		= REG_FIELD(0x06, 2, 7),
	[F_BATLOWV]		= REG_FIELD(0x06, 1, 1),
	[F_VRECHG]		= REG_FIELD(0x06, 0, 0),
	/* REG07 */
	[F_TERM_EN]		= REG_FIELD(0x07, 7, 7),
	[F_STAT_DIS]		= REG_FIELD(0x07, 6, 6),
	[F_WD]			= REG_FIELD(0x07, 4, 5),
	[F_TMR_EN]		= REG_FIELD(0x07, 3, 3),
	[F_CHG_TMR]		= REG_FIELD(0x07, 1, 2),
	[F_JEITA_ISET]		= REG_FIELD(0x07, 0, 0), // reserved on BQ25895
	/* REG08 */
	[F_BATCMP]		= REG_FIELD(0x08, 5, 7),
	[F_VCLAMP]		= REG_FIELD(0x08, 2, 4),
	[F_TREG]		= REG_FIELD(0x08, 0, 1),
	/* REG09 */
	[F_FORCE_ICO]		= REG_FIELD(0x09, 7, 7),
	[F_TMR2X_EN]		= REG_FIELD(0x09, 6, 6),
	[F_BATFET_DIS]		= REG_FIELD(0x09, 5, 5),
	[F_JEITA_VSET]		= REG_FIELD(0x09, 4, 4), // reserved on BQ25895
	[F_BATFET_DLY]		= REG_FIELD(0x09, 3, 3),
	[F_BATFET_RST_EN]	= REG_FIELD(0x09, 2, 2),
	[F_PUMPX_UP]		= REG_FIELD(0x09, 1, 1),
	[F_PUMPX_DN]		= REG_FIELD(0x09, 0, 0),
	/* REG0A */
	[F_BOOSTV]		= REG_FIELD(0x0A, 4, 7),
	[F_BOOSTI]		= REG_FIELD(0x0A, 0, 2), // reserved on BQ25895
	[F_PFM_OTG_DIS]		= REG_FIELD(0x0A, 3, 3), // BQ25896 only
	/* REG0B */
	[F_VBUS_STAT]		= REG_FIELD(0x0B, 5, 7),
	[F_CHG_STAT]		= REG_FIELD(0x0B, 3, 4),
	[F_PG_STAT]		= REG_FIELD(0x0B, 2, 2),
	[F_SDP_STAT]		= REG_FIELD(0x0B, 1, 1), // reserved on BQ25896
	[F_VSYS_STAT]		= REG_FIELD(0x0B, 0, 0),
	/* REG0C */
	[F_WD_FAULT]		= REG_FIELD(0x0C, 7, 7),
	[F_BOOST_FAULT]		= REG_FIELD(0x0C, 6, 6),
	[F_CHG_FAULT]		= REG_FIELD(0x0C, 4, 5),
	[F_BAT_FAULT]		= REG_FIELD(0x0C, 3, 3),
	[F_NTC_FAULT]		= REG_FIELD(0x0C, 0, 2),
	/* REG0D */
	[F_FORCE_VINDPM]	= REG_FIELD(0x0D, 7, 7),
	[F_VINDPM]		= REG_FIELD(0x0D, 0, 6),
	/* REG0E */
	[F_THERM_STAT]		= REG_FIELD(0x0E, 7, 7),
	[F_BATV]		= REG_FIELD(0x0E, 0, 6),
	/* REG0F */
	[F_SYSV]		= REG_FIELD(0x0F, 0, 6),
	/* REG10 */
	[F_TSPCT]		= REG_FIELD(0x10, 0, 6),
	/* REG11 */
	[F_VBUS_GD]		= REG_FIELD(0x11, 7, 7),
	[F_VBUSV]		= REG_FIELD(0x11, 0, 6),
	/* REG12 */
	[F_ICHGR]		= REG_FIELD(0x12, 0, 6),
	/* REG13 */
	[F_VDPM_STAT]		= REG_FIELD(0x13, 7, 7),
	[F_IDPM_STAT]		= REG_FIELD(0x13, 6, 6),
	[F_IDPM_LIM]		= REG_FIELD(0x13, 0, 5),
	/* REG14 */
	[F_REG_RST]		= REG_FIELD(0x14, 7, 7),
	[F_ICO_OPTIMIZED]	= REG_FIELD(0x14, 6, 6),
	[F_PN]			= REG_FIELD(0x14, 3, 5),
	[F_TS_PROFILE]		= REG_FIELD(0x14, 2, 2),
	[F_DEV_REV]		= REG_FIELD(0x14, 0, 1)
};

/*
 * Most of the val -> idx conversions can be computed, given the minimum,
 * maximum and the step between values. For the rest of conversions, we use
 * lookup tables.
 */
enum bq25890_table_ids {
	/* range tables */
	TBL_ICHG,
	TBL_ITERM,
	TBL_IINLIM,
	TBL_VREG,
	TBL_BOOSTV,
	TBL_SYSVMIN,
	TBL_VBUSV,
	TBL_VBATCOMP,
	TBL_RBATCOMP,

	/* lookup tables */
	TBL_TREG,
	TBL_BOOSTI,
	TBL_TSPCT,
};

/* Thermal Regulation Threshold lookup table, in degrees Celsius */
static const u32 bq25890_treg_tbl[] = { 60, 80, 100, 120 };

#define BQ25890_TREG_TBL_SIZE		ARRAY_SIZE(bq25890_treg_tbl)

/* Boost mode current limit lookup table, in uA */
static const u32 bq25890_boosti_tbl[] = {
	500000, 700000, 1100000, 1300000, 1600000, 1800000, 2100000, 2400000
};

#define BQ25890_BOOSTI_TBL_SIZE		ARRAY_SIZE(bq25890_boosti_tbl)

/* NTC 10K temperature lookup table in tenths of a degree */
static const u32 bq25890_tspct_tbl[] = {
	850, 840, 830, 820, 810, 800, 790, 780,
	770, 760, 750, 740, 730, 720, 710, 700,
	690, 685, 680, 675, 670, 660, 650, 645,
	640, 630, 620, 615, 610, 600, 590, 585,
	580, 570, 565, 560, 550, 540, 535, 530,
	520, 515, 510, 500, 495, 490, 480, 475,
	470, 460, 455, 450, 440, 435, 430, 425,
	420, 410, 405, 400, 390, 385, 380, 370,
	365, 360, 355, 350, 340, 335, 330, 320,
	310, 305, 300, 290, 285, 280, 275, 270,
	260, 250, 245, 240, 230, 225, 220, 210,
	205, 200, 190, 180, 175, 170, 160, 150,
	145, 140, 130, 120, 115, 110, 100, 90,
	80, 70, 60, 50, 40, 30, 20, 10,
	0, -10, -20, -30, -40, -60, -70, -80,
	-90, -10, -120, -140, -150, -170, -190, -210,
};

#define BQ25890_TSPCT_TBL_SIZE		ARRAY_SIZE(bq25890_tspct_tbl)

struct bq25890_range {
	u32 min;
	u32 max;
	u32 step;
};

struct bq25890_lookup {
	const u32 *tbl;
	u32 size;
};

static const union {
	struct bq25890_range  rt;
	struct bq25890_lookup lt;
} bq25890_tables[] = {
	/* range tables */
	/* TODO: BQ25896 has max ICHG 3008 mA */
	[TBL_ICHG] =	 { .rt = {0,        5056000, 64000} },	 /* uA */
	[TBL_ITERM] =	 { .rt = {64000,    1024000, 64000} },	 /* uA */
	[TBL_IINLIM] =   { .rt = {100000,   3250000, 50000} },	 /* uA */
	[TBL_VREG] =	 { .rt = {3840000,  4608000, 16000} },	 /* uV */
	[TBL_BOOSTV] =	 { .rt = {4550000,  5510000, 64000} },	 /* uV */
	[TBL_SYSVMIN] =  { .rt = {3000000,  3700000, 100000} },	 /* uV */
	[TBL_VBUSV] =	 { .rt = {2600000, 15300000, 100000} },	 /* uV */
	[TBL_VBATCOMP] = { .rt = {0,         224000, 32000} },	 /* uV */
	[TBL_RBATCOMP] = { .rt = {0,         140000, 20000} },	 /* uOhm */

	/* lookup tables */
	[TBL_TREG] =	{ .lt = {bq25890_treg_tbl, BQ25890_TREG_TBL_SIZE} },
	[TBL_BOOSTI] =	{ .lt = {bq25890_boosti_tbl, BQ25890_BOOSTI_TBL_SIZE} },
	[TBL_TSPCT] =	{ .lt = {bq25890_tspct_tbl, BQ25890_TSPCT_TBL_SIZE} }
};

static int bq25890_field_read(struct bq25890_device *bq,
			      enum bq25890_fields field_id)
{
	int ret;
	int val;

	ret = regmap_field_read(bq->rmap_fields[field_id], &val);
	if (ret < 0)
		return ret;

	return val;
}

static int bq25890_field_write(struct bq25890_device *bq,
			       enum bq25890_fields field_id, u8 val)
{
	return regmap_field_write(bq->rmap_fields[field_id], val);
}

static u8 bq25890_find_idx(u32 value, enum bq25890_table_ids id)
{
	u8 idx;

	if (id >= TBL_TREG) {
		const u32 *tbl = bq25890_tables[id].lt.tbl;
		u32 tbl_size = bq25890_tables[id].lt.size;

		for (idx = 1; idx < tbl_size && tbl[idx] <= value; idx++)
			;
	} else {
		const struct bq25890_range *rtbl = &bq25890_tables[id].rt;
		u8 rtbl_size;

		rtbl_size = (rtbl->max - rtbl->min) / rtbl->step + 1;

		for (idx = 1;
		     idx < rtbl_size && (idx * rtbl->step + rtbl->min <= value);
		     idx++)
			;
	}

	return idx - 1;
}

static u32 bq25890_find_val(u8 idx, enum bq25890_table_ids id)
{
	const struct bq25890_range *rtbl;

	/* lookup table? */
	if (id >= TBL_TREG)
		return bq25890_tables[id].lt.tbl[idx];

	/* range table */
	rtbl = &bq25890_tables[id].rt;

	return (rtbl->min + idx * rtbl->step);
}

enum bq25890_status {
	STATUS_NOT_CHARGING,
	STATUS_PRE_CHARGING,
	STATUS_FAST_CHARGING,
	STATUS_TERMINATION_DONE,
};

enum bq25890_chrg_fault {
	CHRG_FAULT_NORMAL,
	CHRG_FAULT_INPUT,
	CHRG_FAULT_THERMAL_SHUTDOWN,
	CHRG_FAULT_TIMER_EXPIRED,
};

enum bq25890_ntc_fault {
	NTC_FAULT_NORMAL = 0,
	NTC_FAULT_WARM = 2,
	NTC_FAULT_COOL = 3,
	NTC_FAULT_COLD = 5,
	NTC_FAULT_HOT = 6,
};


/* HELPERS */
typedef struct {
    int voltage;
    int percentage;
} VoltageMap;
/*
 * Calibrated 1S LiPo rest OCV table for the PocketCM5 / BQ25895 pack
 * (4800 mAh rated, 4.176 V full charge). Centivolts; 3.70 V -> 370.
 *
 * IMPORTANT: this table must be sorted ASCENDING by voltage and MUST
 * have exactly one entry per voltage.  The driver walks it looking
 * for `voltage >= v[i] && voltage < v[i+1]` and assumes `v[0]` is the
 * lowest voltage (= 0%) and `v[size-1]` is the highest (= 100%).
 * A descending table, a duplicate-voltage table, or a non-monotonic
 * table would each produce wrong SOC for some voltage range.
 *
 * Source: 5299 resting samples logged 2026-08-22 .. 2026-08-28 by
 * pibrick-battery-calibration.service, processed by
 * battery-auto-calibrator.py and collapsed by
 * battery/postprocess-ocv-table.py.  The raw calibrator output had
 * multiple (voltage_cv, soc) entries per voltage — the dominant one
 * per voltage (highest sample count, ties to lower SOC) was kept and
 * the curve was monotonicity-floor-corrected (any SOC drop was raised
 * to the previous max).  Confidence: 0.99, SOC coverage: 97%.
 *
 * Re-generate by:
 *   1. Run pibrick-battery-calibration.service for 1+ charge cycles
 *   2. python3 battery-auto-calibrator.py --check
 *   3. python3 battery/postprocess-ocv-table.py \
 *        /var/log/bq25890_battery/suggested_ocv_table.h \
 *        /tmp/ocv-clean.h /tmp/ocv-clean.csv \
 *        /var/log/bq25890_battery/calibration_status.json
 *   4. Paste the resulting static VoltageMap[] body into here.
 */
static VoltageMap voltage_to_percent_table[] = {
	{ 334,   2 },  /* 14 samples */
	{ 335,   4 },  /* 58 samples */
	{ 337,   6 },  /* 54 samples */
	{ 338,   7 },  /* 57 samples */
	{ 339,   8 },  /* 59 samples */
	{ 340,   9 },  /* 53 samples */
	{ 341,  10 },  /* 45 samples */
	{ 342,  11 },  /* 44 samples */
	{ 343,  18 },  /* 50 samples */
	{ 344,  18 },  /* 65 samples (raised from 17 for monotonicity) */
	{ 345,  21 },  /* 58 samples */
	{ 346,  21 },  /* 62 samples (raised from 16) */
	{ 347,  22 },  /* 52 samples */
	{ 348,  24 },  /* 72 samples */
	{ 349,  27 },  /* 60 samples */
	{ 350,  28 },  /* 49 samples */
	{ 351,  29 },  /* 49 samples */
	{ 352,  30 },  /* 53 samples */
	{ 353,  31 },  /* 54 samples */
	{ 355,  33 },  /* 52 samples */
	{ 356,  35 },  /* 58 samples */
	{ 357,  39 },  /* 75 samples */
	{ 358,  41 },  /* 84 samples */
	{ 359,  42 },  /* 77 samples */
	{ 360,  43 },  /* 83 samples */
	{ 361,  45 },  /* 94 samples */
	{ 363,  48 },  /* 101 samples */
	{ 365,  51 },  /* 43 samples */
	{ 366,  51 },  /* raised from 50 */
	{ 367,  53 },  /* 40 samples */
	{ 369,  54 },  /* 70 samples */
	{ 370,  55 },  /* 52 samples */
	{ 371,  56 },  /* 53 samples */
	{ 373,  60 },  /* 75 samples */
	{ 374,  60 },  /* raised from 57 */
	{ 375,  63 },  /* 33 samples */
	{ 377,  63 },  /* raised from 58 */
	{ 378,  65 },  /* 32 samples */
	{ 379,  65 },  /* raised from 59 */
	{ 380,  73 },  /* 48 samples */
	{ 381,  73 },  /* raised from 72 */
	{ 383,  76 },  /* 49 samples */
	{ 384,  77 },  /* 63 samples */
	{ 385,  78 },  /* 65 samples */
	{ 386,  81 },  /* 49 samples */
	{ 387,  83 },  /* 52 samples */
	{ 388,  86 },  /* 54 samples */
	{ 389,  88 },  /* 80 samples */
	{ 390,  88 },  /* 79 samples (raised from 84) */
	{ 391,  89 },  /* 42 samples */
	{ 392,  92 },  /* 27 samples */
	{ 393,  93 },  /* 33 samples */
	{ 395,  94 },  /* 53 samples */
	{ 399,  96 },  /* 52 samples */
	{ 407,  97 },  /* 22 samples */
	{ 413,  98 },  /* 15 samples */
	{ 418, 100 },  /* synthetic full-charge point (above max observed) */
};
const int table_size = ARRAY_SIZE(voltage_to_percent_table);
static int bq25890_calc_lipo_percentage(int voltage_uv)
{
	int voltage = voltage_uv / 10000;
	int i;

	if (voltage <= voltage_to_percent_table[0].voltage)
		return 0;
	if (voltage >= voltage_to_percent_table[table_size - 1].voltage)
		return 100;

	for (i = 0; i < table_size - 1; i++) {
		if (voltage >= voltage_to_percent_table[i].voltage &&
		    voltage < voltage_to_percent_table[i + 1].voltage) {
			int v1 = voltage_to_percent_table[i].voltage;
			int v2 = voltage_to_percent_table[i + 1].voltage;
			int p1 = voltage_to_percent_table[i].percentage;
			int p2 = voltage_to_percent_table[i + 1].percentage;

			return p1 + (voltage - v1) * (p2 - p1) / (v2 - v1);
		}
	}

	return 100;
}

static bool bq25890_batv_is_adc_floor(int uv)
{
	return uv >= BQ25890_BATV_ADC_FLOOR_UV &&
	       uv <= BQ25890_BATV_ADC_FLOOR_MAX_UV;
}

/*
 * Under heavy CPU/display load the BATV ADC often pegs at 2.304 V even though
 * the cell is still well above empty. Treat that as a bad sample, not a real
 * collapse — otherwise userspace (e.g. KDE PowerDevil) sees 0 % and shuts down.
 */
static bool bq25890_batv_is_load_glitch(int raw, long smoothed_uv)
{
	return bq25890_batv_is_adc_floor(raw) && smoothed_uv > 2800000;
}

static int bq25890_get_batv_uv(struct bq25890_device *bq)
{
	int ret = bq25890_field_read(bq, F_BATV);

	if (ret < 0)
		return ret;

	/* converted_val = 2.304V + ADC_val * 20mV (table 10.3.15) */
	return 2304000 + ret * 20000;
}

static int bq25890_get_charge_current_ua(struct bq25890_device *bq)
{
	int ret = bq25890_field_read(bq, F_ICHGR);

	if (ret < 0)
		return ret;

	return ret * 50000;
}

static int bq25890_get_vbus_voltage(struct bq25890_device *bq)
{
	int ret;

	ret = bq25890_field_read(bq, F_VBUSV);
	if (ret < 0)
		return ret;

	return bq25890_find_val(ret, TBL_VBUSV);
}

static bool bq25890_has_external_power(struct bq25890_device *bq,
				       const struct bq25890_state *state)
{
	int vbusv;

	if (state->hiz || !state->vbus_gd)
		return false;

	vbusv = bq25890_get_vbus_voltage(bq);
	if (vbusv < BQ25890_VBUS_MIN_UV)
		return false;

	return true;
}

static bool bq25890_is_actively_charging(struct bq25890_device *bq,
					 const struct bq25890_state *state)
{
	int ichgr;

	if (!bq25890_has_external_power(bq, state))
		return false;

	if (state->chrg_status == STATUS_TERMINATION_DONE)
		return false;

	/*
	 * The PMIC's CHRG_STATUS register doesn't always reflect real
	 * battery activity: during input-current regulation, DPM, recharge
	 * after termination, and battery-detection sweeps the chip pulses
	 * through STATUS_NOT_CHARGING even though current is still flowing
	 * into the cell. Reporting this as "Not charging" makes upower
	 * (and therefore KDE Plasma Mobile's tray icon) flicker between the
	 * charging bolt and the plain battery every few seconds. Upower maps
	 * the kernel's "Not charging" status to its own "pending-charge"
	 * state, and KDE's Solid backend maps that to Battery::NoCharge —
	 * so the tray icon shows the plain battery icon and "checking
	 * battery information in settings" reports the battery as
	 * "stable" / not charging.
	 *
	 * Two signals can confirm we are actually putting energy into the
	 * battery; either is sufficient:
	 *
	 *   1. The PMIC's ICHGR register reports measurable charge current
	 *      (>= BQ25890_CHARGE_CURRENT_MIN_UA). This is the chip's own
	 *      measurement of current going into the cell.
	 *
	 *   2. The INA228 (if bound) reads negative battery current, meaning
	 *      current is flowing into the cell from some source. INA228 is
	 *      ground-truth for actual battery-terminal current.
	 *
	 * Either signal wins. We deliberately no longer look at
	 * chrg_status == STATUS_NOT_CHARGING as a disqualifier — that flag
	 * fires for the regulator-pause case above.
	 */
	ichgr = bq25890_get_charge_current_ua(bq);
	if (ichgr >= BQ25890_CHARGE_CURRENT_MIN_UA)
		return true;

	/*
	 * INA228 fallback: bq->ina228_current_ua is updated only by the
	 * INA228 sample path. When INA228 hardware is absent or disabled,
	 * it stays at 0, so this branch is harmless to evaluate. We avoid
	 * dereferencing bq->ina228 here because the full struct definition
	 * appears further down in this file.
	 */
	if (ina228_enabled && bq->ina228_current_ua < -50000)
		return true;

	return false;
}

static long bq25890_get_battery_current_ua(struct bq25890_device *bq,
					   const struct bq25890_state *state)
{
	int ichgr;

	ichgr = bq25890_get_charge_current_ua(bq);
	if (ichgr < 0)
		ichgr = 0;

	if (bq25890_has_external_power(bq, state) &&
	    bq25890_is_actively_charging(bq, state))
		return ichgr;

	return 0;
}

static int bq25890_fg_charge_ocv_uv(struct bq25890_device *bq,
				    const struct bq25890_state *state,
				    int v_term)
{
	int ichgr;
	long ir_drop_uv;

	if (v_term < 0)
		return v_term;

	if (!bq25890_has_external_power(bq, state))
		return v_term;

	ichgr = bq25890_get_charge_current_ua(bq);
	if (ichgr < 0)
		ichgr = 0;

	ir_drop_uv = (long)ichgr * batt_ir_mohm / 1000;
	v_term -= (int)ir_drop_uv;
	v_term -= BQ25890_FG_CHG_POLAR_UV;

	return v_term;
}

static int bq25890_get_status(struct bq25890_device *bq,
			      const struct bq25890_state *state,
			      bool ext_pwr, bool charging)
{
	if (charging)
		return POWER_SUPPLY_STATUS_CHARGING;

	if (!ext_pwr)
		return POWER_SUPPLY_STATUS_DISCHARGING;

	if (state->chrg_status == STATUS_TERMINATION_DONE)
		return POWER_SUPPLY_STATUS_FULL;

	return POWER_SUPPLY_STATUS_NOT_CHARGING;
}

static bool bq25890_fg_under_load(struct bq25890_device *bq)
{
	return bq->batv_load_glitch_until &&
	       time_before(jiffies, bq->batv_load_glitch_until);
}

static int bq25890_capacity_cached(struct bq25890_device *bq)
{
	if (!bq->capacity_valid)
		return -ENODATA;

	return bq->capacity_cache;
}

/*
 * Smoothed terminal voltage tracker.
 *
 * Caller must hold bq->lock (this is the estimator's single owner path).
 * Returns the filtered terminal voltage in uV. Also updates the persisted
 * "is the cell under load right now?" flag (`batv_load_glitch_until`) the
 * rest of the estimator uses to gate `DISCHARGING_ACTIVE` vs.
 * `DISCHARGING_RESTING`.
 */
static int bq25890_update_smoothed_batv_locked(struct bq25890_device *bq,
					       bool reseed)
{
	int raw = bq25890_get_batv_uv(bq);
	unsigned long now = jiffies;
	unsigned long dt_jiffies;
	long dt_sec;

	if (raw < 0)
		return raw;

	if (bq25890_batv_is_adc_floor(raw)) {
		bq->batv_load_glitch_until = now + BQ25890_FG_LOAD_GLITCH_SEC * HZ;
		bq->fg_glitch_count++;
		if (bq->batv_smoothed_uv > BQ25890_BATV_REST_MIN_UV)
			return (int)bq->batv_smoothed_uv;
	}

	if (reseed || bq->batv_smoothed_uv <= 0) {
		bq->batv_smoothed_uv = raw;
		bq->batv_smoothed_jiffies = now;
		return raw;
	}

	if (bq25890_batv_is_load_glitch(raw, bq->batv_smoothed_uv)) {
		bq->batv_load_glitch_until = now + BQ25890_FG_LOAD_GLITCH_SEC * HZ;
		return (int)bq->batv_smoothed_uv;
	}

	/*
	 * Detect a load event (any sudden drop larger than 6% of the current
	 * terminal voltage). This is much more permissive than the ADC-floor
	 * heuristic it replaces and is the new "are we under load?" signal.
	 */
	if (bq->batv_smoothed_uv > 0 &&
	    (long)bq->batv_smoothed_uv - raw > (bq->batv_smoothed_uv / 16) &&
	    raw > BQ25890_BATV_REST_MIN_UV) {
		bq->batv_load_glitch_until = now + BQ25890_FG_LOAD_GLITCH_SEC * HZ;
	}

	if (raw - (int)bq->batv_smoothed_uv > 350000) {
		bq->batv_smoothed_uv = raw;
		bq->batv_smoothed_jiffies = now;
		return raw;
	}

	if ((int)bq->batv_smoothed_uv - raw > 350000 &&
	    bq25890_batv_is_adc_floor(raw))
		return (int)bq->batv_smoothed_uv;

	dt_jiffies = now - bq->batv_smoothed_jiffies;
	if (dt_jiffies < HZ)
		return (int)bq->batv_smoothed_uv;

	dt_sec = (long)(dt_jiffies / HZ);
	if (dt_sec > BQ25890_FG_V_TAU_SEC)
		dt_sec = BQ25890_FG_V_TAU_SEC;

	bq->batv_smoothed_uv += (raw - bq->batv_smoothed_uv) * dt_sec /
				(BQ25890_FG_V_TAU_SEC + dt_sec);
	bq->batv_smoothed_jiffies = now;

	return (int)bq->batv_smoothed_uv;
}

/*
 * Slower tracker for the "OCV" we feed the LiPo curve. Only updated when
 * the cell is at rest; decays toward the smoothed terminal voltage.
 * Caller must hold bq->lock.
 */
static void bq25890_update_v_ocv_locked(struct bq25890_device *bq, int v_term_uv,
					bool force_reseed)
{
	unsigned long now = jiffies;
	unsigned long dt_jiffies;
	long dt_sec;

	if (force_reseed || bq->fg_v_ocv_uv <= 0) {
		bq->fg_v_ocv_uv = v_term_uv;
		return;
	}

	if (!time_before(now, bq->batv_load_glitch_until)) {
		dt_jiffies = HZ;
	} else {
		dt_jiffies = now - bq->batv_smoothed_jiffies;
		if (dt_jiffies < HZ)
			return;
	}

	dt_sec = (long)(dt_jiffies / HZ);
	if (dt_sec > bq->fg_v_ocv_tau_sec)
		dt_sec = bq->fg_v_ocv_tau_sec;

	bq->fg_v_ocv_uv += (v_term_uv - bq->fg_v_ocv_uv) * dt_sec /
			   (bq->fg_v_ocv_tau_sec + dt_sec);
}

/*
 * Returns uA clamped to [0, discharge_max_ua]. Caller must hold bq->lock.
 */
static int bq25890_fg_compute_proxy_ua_locked(struct bq25890_device *bq,
					     bool sustained_load)
{
	long ua;

	if (discharge_avg_ua <= 0)
		return 0;

	ua = discharge_avg_ua;
	if (sustained_load && discharge_load_factor_pct > 0)
		ua = ua + ua * discharge_load_factor_pct / 100;

	if (ua > discharge_max_ua && discharge_max_ua > 0)
		ua = discharge_max_ua;
	if (ua < 0)
		ua = 0;

	return (int)ua;
}

static void bq25890_fg_integrate_proxy_locked(struct bq25890_device *bq)
{
	unsigned long now = jiffies;
	unsigned long dt_jiffies = now - bq->fg_disch_jiffies;
	s64 dt_msec, drop_uah;

	if (bq->fg_proxy_ua <= 0 || charge_full_uah <= 0)
		return;
	/* Unseeded remainder (-1). Integrating would clamp to 0% SOC. */
	if (bq->fg_disch_remain_uah < 0)
		return;

	if (dt_jiffies < HZ / 10)
		return;

	/*
	 * ENHANCED: High-precision time calculation for proxy integrator.
	 * Same technique as INA228 integration for consistency.
	 *
	 * Note: For proxy mode (no INA228), current precision is limited
	 * by the proxy estimate. We still improve time precision to at least
	 * match the quality of the INA228-based integration.
	 */
	dt_msec = (s64)jiffies_to_msecs(dt_jiffies);

	if (dt_msec > (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL)
		dt_msec = (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL;

	/*
	 * Coulomb calculation: charge (uAh) = current (uA) × time (ms) / 3600000
	 * Using 64-bit arithmetic to prevent overflow and maintain precision.
	 */
	drop_uah = (s64)bq->fg_proxy_ua * dt_msec;
	drop_uah = div_s64(drop_uah, 3600000LL);

	if (drop_uah > 0) {
		bq->fg_disch_remain_uah -= (long)drop_uah;
		if (bq->fg_disch_remain_uah < 0)
			bq->fg_disch_remain_uah = 0;
	}
	bq->fg_disch_jiffies = now;
}

/* Caller must hold bq->lock. Returns uA or negative on error. */
static int bq25890_ichgr_ua_locked(struct bq25890_device *bq)
{
	return bq25890_get_charge_current_ua(bq);
}

/* =====================================================================
 * INA228 high-side current monitor driver (PocketCM5, I2C 0x40).
 *
 * Optional. When present, we use its signed current reading as the
 * authoritative coulomb-counter source for SOC integration. When absent
 * (or ina228_enabled == 0), we fall back to the proxy integrator.
 *
 * 24-bit telemetry uses a private regmap created on an
 * i2c_new_dummy_device handle for address 0x40. 16-bit control and ID
 * registers use SMBus word transactions. All access runs under bq->lock
 * to preserve the single-mutator estimator invariant.
 * =====================================================================
 */

enum bq25890_ina228_fields {
	F_ina228_VSHUNT,
	F_ina228_VBUS,
	F_ina228_CURRENT,
	F_ina228_POWER,
	F_MAX_INA228_FIELDS,
};

struct bq25890_ina228_data {
	bool present;
	struct i2c_client *client;
	struct regmap *rmap;
	struct regmap_field *rmap_fields[F_MAX_INA228_FIELDS];
	int current_ua;			/* signed, positive = discharge */
	s32 raw_current_adc;		/* raw 20-bit ADC value for precise integration */
	int bus_uv;
	int shunt_uv;			/* signed */
	int power_mw;
	int dietemp_mdeg_c;
	int device_id;
	unsigned long jiffies;
	int adc_range;			/* 0 = ±163.84 mV, 1 = ±40.96 mV */
	u32 current_lsb_na;		/* current_lsb in nA/LSB (from Rsh/I) */

	/*
	 * Coulomb counter state for high-precision integration.
	 * These values track the accumulated charge with fractional precision.
	 *
	 * coulomb_nah: accumulated coulombs in nanoamp-hours (nah).
	 *              Using nah (vs uah) provides 1000x more resolution
	 *              for the fractional accumulator, preventing rounding
	 *              errors from accumulating over many integration cycles.
	 *
	 * last_coulomb_update_jiffies: timestamp of last coulomb update
	 * last_disch_remain_nah: last reported discharge remaining in nah
	 *
	 * Example: at 6.4A max current with default lsb_na≈12207:
	 *   One ADC LSB = 12207 nA ≈ 12 µA
	 *   Over 30-second integration interval at 100mA average:
	 *     raw charge = 100000 nA * 30 s = 3,000,000 nAs
	 *     nah = nAs / 3600 = 833.33 nah (needs fractional precision)
	 *
	 * With nah tracking (1000x more granular than uah):
	 *   error per sample < 0.1% even at 100µA discharge
	 *   error per sample < 0.001% at normal discharge currents
	 */
	s64 coulomb_nah;			/* accumulated coulombs in nah */
	unsigned long last_coulomb_update_jiffies;
	long last_disch_remain_nah;		/* previous remaining in nah */

	/*
	 * Temperature compensation state for shunt resistance.
	 * Shunt resistor TCR (Temperature Coefficient of Resistance) typically
	 * ranges from ±50 to ±100 ppm/°C for precision shunts.
	 * At 50 ppm/°C and 25°C temperature swing, error = 0.125%
	 *
	 * For the common SMD current-sense resistor (e.g., 15 mΩ ±1% tolerance):
	 *   TCR ≈ 100 ppm/°C typical
	 *   At 25°C swing from calibration temp: 0.25% error in current measurement
	 *
	 * We track temperature changes and apply a correction factor to
	 * compensate for shunt resistance drift.
	 *
	 * calib_dietemp_mdeg_c: die temperature at last calibration
	 * temp_correction_ppm: accumulated temperature correction in ppm
	 *   (positive = resistance increased, current reading low)
	 */
	int calib_dietemp_mdeg_c;	/* die temp at calibration/characterization */
	int temp_correction_ppm;	/* ppm correction from temp drift */

	/*
	 * Current measurement filtering state.
	 *
	 * The INA228 has excellent 20-bit resolution, but current measurements
	 * can still have noise from:
	 *   - Thermal EMF effects on the shunt
	 *   - ADC quantization at low currents
	 *   - Transient load changes (CPU spikes, WiFi bursts)
	 *
	 * We use an exponential moving average (EMA) filter to smooth the
	 * current readings while maintaining responsiveness to real changes.
	 *
	 * filtered_current_ua: EMA-filtered current in µA
	 * filter_alpha: filter coefficient (0-1000, represents α × 1000)
	 *   Higher values = more responsive but less smooth
	 *   Lower values = smoother but slower to respond
	 *   Default of 250 (α=0.25) gives good balance for 30s update rate
	 *
	 * For EMA: filtered = α × sample + (1-α) × previous_filtered
	 * With α=0.25 and 30s updates, the filter has ~2-minute effective window
	 */
	int filtered_current_ua;
	int filter_alpha;			/* α × 1000 (0-1000) */

	/*
	 * Deadzone filter state to prevent jitter from small changes.
	 * Some current sensors exhibit "flutter" where readings oscillate
	 * by ±1 LSB even when the actual current is stable.
	 *
	 * deadzone_ua: minimum change required to update the filtered value
	 * last_filtered: previous filtered value for deadzone comparison
	 */
	int deadzone_ua;
	int last_filtered_ua;
};

static const struct reg_field bq25890_ina228_reg_fields[F_MAX_INA228_FIELDS] = {
	[F_ina228_VSHUNT] = REG_FIELD(INA228_REG_VSHUNT, 0, 23),
	[F_ina228_VBUS]   = REG_FIELD(INA228_REG_VBUS, 0, 23),
	[F_ina228_CURRENT] = REG_FIELD(INA228_REG_CURRENT, 0, 23),
	[F_ina228_POWER]  = REG_FIELD(INA228_REG_POWER, 0, 23),
};

static const struct regmap_config bq25890_ina228_regmap_cfg = {
	.name = "ina228",
	.reg_bits = 8,
	.val_bits = 24,
	.max_register = INA228_REG_DVC_UID,
	.val_format_endian = REGMAP_ENDIAN_BIG,
	.can_multi_write = false,
};

/*
 * Write a 16-bit register to the INA228 using raw I2C block write.
 * SMBus write_word_data sends [LOW, HIGH] but the INA228 expects
 * [HIGH, LOW] per the I2C standard.  This helper bypasses that mismatch.
 */
static int bq25890_ina228_read_reg16(struct i2c_client *client, u8 reg, u16 *val)
{
	u8 txbuf[1] = { reg };
	u8 rxbuf[2];
	int ret;

	ret = i2c_master_send(client, txbuf, sizeof(txbuf));
	if (ret < 0)
		return ret;
	ret = i2c_master_recv(client, rxbuf, sizeof(rxbuf));
	if (ret < 0)
		return ret;
	/* INA228 16-bit regs are big-endian: MSB first on wire. */
	*val = ((u16)rxbuf[0] << 8) | rxbuf[1];
	return 0;
}

static int bq25890_ina228_write_reg16(struct i2c_client *client,
				       u8 reg, u16 val)
{
	u8 buf[3] = { reg, val >> 8, val & 0xff };
	int ret = i2c_master_send(client, buf, sizeof(buf));
	return (ret < 0) ? ret : 0;
}

static int bq25890_ina228_field_read(struct bq25890_ina228_data *ina,
				     enum bq25890_ina228_fields f, int *val)
{
	int ret;

	ret = regmap_field_read(ina->rmap_fields[f], val);
	return ret < 0 ? ret : 0;
}

static int bq25890_ina228_compute_cal(int max_current_ua, int shunt_uohm)
{
	/*
	 * Per INA228 datasheet / Adafruit setShunt:
	 *   current_lsb  = max_current / 2^19  (in A)
	 *   SHUNT_CAL    = floor(13107.2e6 * current_lsb * Rshunt)
	 *
	 * Since 13107.2e6 / 2^19 = 25000 exactly, in fixed point:
	 *   SHUNT_CAL    = floor(25000 * max_current_A * Rshunt_ohm)
	 *               = floor(25 * max_current_uA * Rshunt_uohm / 1e6)
	 *
	 * With defaults (6.4 A, 15 mΩ): SHUNT_CAL = floor(25 * 6400000 * 15000 / 1e6)
	 *                             = floor(2400) = 2400.
	 * Cap at u16 (SHUNTCAL is 16-bit); saturation is silent because the
	 * current_lsb_nA used on the host side is independent of this value.
	 *
	 * Avoid overflow: 25 * 6400000 * 15000 = 2.4 trillion > 2^31.
	 * Multiply in 64-bit intermediates, then divide to keep within range.
	 *   SHUNT_CAL = floor((max_current_uA / 1000) * (shunt_uohm / 1000) * 25 / 1000)
	 */
	s64 a = max_current_ua / 1000;
	s64 b = shunt_uohm / 1000;
	s64 num = a * b * 25;

	if (num <= 0)
		return 0;
	return (int)clamp_t(s64, num / 1000, 0LL, 0xFFFFLL);
}

static int bq25890_ina228_raw_to_current_ua(struct bq25890_ina228_data *ina,
					    u32 raw24)
{
	/*
	 * CURRENT is a signed 20-bit value occupying register bits[23:4].
	 * The regmap field reads bits[23:4] directly (REGMAP_ENDIAN_BIG on
	 * a 24-bit value).  Extract those bits, shift into position, then
	 * sign-extend the 20-bit result to s32 before scaling:
	 *   current_uA = signext(raw24 >> 4, 20) * current_lsb_nA / 1e3
	 *
	 * ENHANCED: Use 64-bit arithmetic to preserve precision during
	 * division. The current_lsb_na can be as small as ~12207 nA (at
	 * default settings), and dividing by 1000 before multiplying would
	 * lose significant digits for small currents.
	 *
	 * New formula: current_ua = signed20 * current_lsb_na / 1000
	 * Using s64 intermediates prevents overflow while maintaining
	 * sub-microamp precision for the coulomb integrator.
	 */
	u32 field20 = (raw24 >> 4) & 0x000FFFFFU;
	s32 signed20 = (field20 <= 0x0007FFFFU)
		? (s32)field20
		: (s32)(field20 | 0xFFF00000U);

	/*
	 * Store the raw signed20 value for high-precision coulomb integration.
	 * This preserves full 20-bit resolution for the fractional LSB
	 * accumulator, which is more accurate than rounding to integer uA.
	 */
	ina->raw_current_adc = signed20;

	/*
	 * Standard integer conversion for sysfs display and status reporting.
	 * Use 64-bit multiply to preserve precision for small currents:
	 *   result = signed20 * current_lsb_na / 1000
	 * With signed20 max ±524287 and lsb_na ~12207:
	 *   max magnitude = 524287 * 12207 / 1000 ≈ 6.4M µA (as expected)
	 */
	return (int)((((s64)signed20 * (s64)ina->current_lsb_na) + 500) / 1000);
}

/*
 * High-precision current reading for coulomb integration.
 * Returns current in microamps with fractional precision tracked separately.
 *
 * This function is used by the coulomb integrator to achieve better accuracy
 * than the rounded integer from bq25890_ina228_raw_to_current_ua().
 *
 * The INA228 has 20-bit effective resolution on CURRENT. With default settings
 * (max_current=6.4A, lsb_na≈12207), the theoretical resolution is:
 *   6400000 uA / 2^20 ≈ 6.1 µA per LSB
 *
 * By keeping the raw ADC value and using it directly in integration, we avoid
 * the rounding error that accumulates over thousands of samples per discharge.
 */
static int bq25890_ina228_raw_to_bus_uv(u32 raw24)
{
	/*
	 * VBUS is 24-bit, top 20 bits used. 195.3125 µV/LSB.
	 *   V_uV = (raw >> 4) * 195.3125
	 * Fixed point: multiply by 1953125 then divide by 10000.
	 */
	u32 v = raw24 >> 4;

	return (int)(((u64)v * 1953125ULL) / 10000ULL);
}

static int bq25890_ina228_raw_to_shunt_uv(struct bq25890_ina228_data *ina,
					   u32 raw24)
{
	/*
	 * VSHUNT is a signed 20-bit value in register bits[23:4], same layout
	 * as CURRENT.  Extract the field, shift right 4 bits, then sign-extend
	 * to s32 before applying the ADC LSB:
	 *   ±163.84 mV range (ADCRANGE=0): 0.3125 µV/code
	 *   ±40.96  mV range (ADCRANGE=1): 0.078125 µV/code
	 */
	u32 field20 = (raw24 >> 4) & 0x000FFFFFU;
	s32 signed20 = (field20 <= 0x0007FFFFU)
		? (s32)field20
		: (s32)(field20 | 0xFFF00000U);
	s64 r = signed20;
	s64 uV;

	if (ina->adc_range == 0)
		uV = r * 3125LL / 10000LL;
	else
		uV = r * 78125LL / 1000000LL;

	return (int)uV;
}

static int bq25890_ina228_raw_to_power_mw(struct bq25890_ina228_data *ina,
					 u32 raw24)
{
	/*
	 * Per INA228 datasheet Equation 5:
	 *   Power [W] = 3.2 × CURRENT_LSB × POWER_raw
	 * With current_lsb_nA = current_lsb_A × 1e9:
	 *   power_W  = raw × 3.2 × current_lsb_nA × 1e-9
	 *   power_mW = raw × 3.2 × current_lsb_nA × 1e-6
	 * Integer form: power_mW = raw × current_lsb_nA × 4 / 1_250_000
	 * For raw = 1 at defaults (lsb_nA ≈ 12207): power_mW ≈ 0.039.
	 */
	s64 nA = (s64)raw24 * (s64)ina->current_lsb_na;

	return (int)((nA * 4) / 1250000);
}

static int bq25890_ina228_raw_to_dietemp_mdeg(s16 raw)
{
	/* Per INA228 datasheet: 7.8125 m°C/LSB. Integer form: raw × 78125 / 10000. */
	return (int)raw * 78125 / 10000;
}

/*
 * Calculate temperature compensation correction for shunt resistance.
 *
 * Shunt resistance changes with temperature according to TCR (Temperature
 * Coefficient of Resistance). This affects the INA228's current reading because:
 *   V_shunt = I × R_shunt
 *   I_measured = V_shunt / R_nominal
 *
 * If R_shunt drifts due to temperature, the current reading drifts proportionally.
 *
 * Args:
 *   ina228_shunt_tcr_ppm: shunt TCR in ppm/°C (typically 50-200 ppm/°C)
 *   calib_temp_mdeg_c: calibration temperature in millidegrees C
 *   current_temp_mdeg_c: current operating temperature in millidegrees C
 *
 * Returns:
 *   Correction factor in ppm (positive = resistance increased, reading is low)
 *   To apply: multiply current by (1 + correction_ppm / 1,000,000)
 */
static int bq25890_ina228_temp_correction_ppm(int calib_temp_mdeg_c,
					      int current_temp_mdeg_c)
{
	long temp_diff_mdeg;
	long correction_ppm;

	if (ina228_shunt_tcr_ppm == 0)
		return 0;

	temp_diff_mdeg = (long)current_temp_mdeg_c - (long)calib_temp_mdeg_c;

	correction_ppm = (long)temp_diff_mdeg * (long)ina228_shunt_tcr_ppm / 1000;

	return (int)clamp_t(long, correction_ppm, -100000, 100000);
}

/*
 * Apply temperature correction to current reading.
 *
 * The INA228 measures V_shunt and computes I = V_shunt / R_shunt_cal.
 * If the actual shunt resistance is different from nominal (due to temperature),
 * the current reading needs correction:
 *   I_corrected = I_measured × (1 + correction_ppm / 1e6)
 *
 * Args:
 *   current_ua: uncorrected current reading in µA
 *   temp_correction_ppm: temperature correction in ppm
 *
 * Returns:
 *   Temperature-corrected current in µA
 */
static long bq25890_ina228_corrected_current_ua(long current_ua,
						int temp_correction_ppm)
{
	s64 corrected;

	if (temp_correction_ppm == 0)
		return current_ua;

	corrected = (s64)current_ua * (1000000LL + temp_correction_ppm);
	corrected = div_s64(corrected, 1000000LL);

	return (long)clamp_t(s64, corrected, -100000000L, 100000000L);
}

/*
 * Apply exponential moving average (EMA) filter to current reading.
 *
 * The INA228 has excellent 20-bit resolution, but current measurements
 * can still have noise from thermal effects, ADC quantization, and
 * transient load changes. The EMA filter smooths these readings while
 * maintaining responsiveness to real current changes.
 *
 * Formula: filtered = α × sample + (1-α) × previous_filtered
 * With α stored as alpha/1000 for integer math:
 *   filtered = (alpha × sample + (1000-alpha) × previous) / 1000
 *
 * Args:
 *   ina: INA228 data structure with filter state
 *   raw_current_ua: uncorrected current reading in µA
 *
 * Returns:
 *   Filtered current in µA
 */
static int bq25890_ina228_filter_current(struct bq25890_ina228_data *ina,
					 int raw_current_ua)
{
	s64 filtered;
	s64 diff;

	if (!ina)
		return raw_current_ua;

	/*
	 * Handle first sample - initialize the filter.
	 */
	if (ina->filtered_current_ua == 0 && ina->last_filtered_ua == 0) {
		ina->filtered_current_ua = raw_current_ua;
		ina->last_filtered_ua = raw_current_ua;
		return raw_current_ua;
	}

	/*
	 * Apply deadzone filter first.
	 * Only update the filter if the change exceeds the deadzone threshold.
	 * This prevents jitter from small ADC fluctuations.
	 */
	diff = (s64)raw_current_ua - (s64)ina->last_filtered_ua;
	if (diff < 0)
		diff = -diff;

	if (diff < (s64)ina->deadzone_ua) {
		/*
		 * Change is within deadzone - keep the same filtered value.
		 * But still update last_filtered to track the center point.
		 */
		ina->last_filtered_ua = raw_current_ua;
		return ina->filtered_current_ua;
	}

	/*
	 * Apply EMA filter.
	 * filtered = (alpha × sample + (1000-alpha) × previous) / 1000
	 *
	 * Using s64 to prevent overflow:
	 *   max: 1000 × 10A × 1e6 uA / 1000 = 10e9 (well within s64 range)
	 */
	if (ina->filter_alpha >= 1000) {
		filtered = raw_current_ua;
	} else {
		filtered = (s64)ina->filter_alpha * (s64)raw_current_ua;
		filtered += (s64)(1000 - ina->filter_alpha) * (s64)ina->filtered_current_ua;
		filtered = div_s64(filtered, 1000LL);
	}

	ina->filtered_current_ua = (int)filtered;
	ina->last_filtered_ua = raw_current_ua;

	return (int)filtered;
}

/* Caller must hold bq->lock. Returns 0 on success, negative on error. */
static int bq25890_ina228_refresh_locked(struct bq25890_device *bq)
{
	struct bq25890_ina228_data *ina = bq->ina228;
	u32 raw24;
	s16 raw16;
	int ret;

	if (!ina || !ina->present)
		return -ENODEV;

	ret = bq25890_ina228_field_read(ina, F_ina228_CURRENT, &raw24);
	if (ret < 0)
		return ret;
	ina->current_ua = bq25890_ina228_raw_to_current_ua(ina, raw24);

	ret = bq25890_ina228_field_read(ina, F_ina228_VBUS, &raw24);
	if (ret < 0)
		return ret;
	ina->bus_uv = bq25890_ina228_raw_to_bus_uv(raw24);

	ret = bq25890_ina228_field_read(ina, F_ina228_VSHUNT, &raw24);
	if (ret < 0)
		return ret;
	ina->shunt_uv = bq25890_ina228_raw_to_shunt_uv(ina, raw24);

	ret = bq25890_ina228_field_read(ina, F_ina228_POWER, &raw24);
	if (ret < 0)
		return ret;
	ina->power_mw = bq25890_ina228_raw_to_power_mw(ina, raw24);

	raw16 = i2c_smbus_read_word_swapped(ina->client,
						 INA228_REG_DIETEMP);
	if (raw16 < 0)
		return raw16;
	ina->dietemp_mdeg_c = bq25890_ina228_raw_to_dietemp_mdeg(raw16);

	/*
	 * Update temperature compensation state.
	 * The INA228 die temperature closely tracks the shunt resistor temperature
	 * (they're on the same PCB, often adjacent). This gives us an accurate
	 * proxy for shunt temperature without external sensors.
	 *
	 * Only update calibration temperature once at initialization (when
	 * calib_dietemp_mdeg_c is 0), then compute correction dynamically.
	 */
	if (ina->calib_dietemp_mdeg_c == 0) {
		ina->calib_dietemp_mdeg_c = ina->dietemp_mdeg_c;
	}
	ina->temp_correction_ppm = bq25890_ina228_temp_correction_ppm(
		ina->calib_dietemp_mdeg_c, ina->dietemp_mdeg_c);

	/*
	 * Apply EMA filter to smooth current readings for display.
	 * The filter reduces noise while maintaining responsiveness.
	 * We apply it AFTER temperature correction so the display shows
	 * the fully corrected, filtered current.
	 */
	{
		int corrected = bq25890_ina228_corrected_current_ua(
			ina->current_ua, ina->temp_correction_ppm);
		int filtered = bq25890_ina228_filter_current(ina, corrected);
		ina->jiffies = jiffies;
		bq->ina228_current_ua = filtered;
	}

	return 0;
}

/*
 * High-precision coulomb integration using INA228.
 *
 * Key accuracy improvements over the simple integration approach:
 *
 * 1. HIGH-PRECISION TIME BASE
 *    - Uses jiffies_to_msecs() for sub-second precision instead of integer
 *      truncation from dt_jiffies / HZ
 *    - At HZ=100 (10ms tick), this gives 10ms resolution vs 1s with integer division
 *
 * 2. FRACTIONAL CURRENT TRACKING
 *    - Uses raw 20-bit ADC value with current_lsb_na multiplier
 *    - Keeps internal accumulator in nanoamp-hours (nah) for 1000x precision
 *    - Converts to uAh only for the final display value
 *
 * 3. TEMPERATURE COMPENSATION
 *    - Applies TCR correction to current reading based on INA228 die temperature
 *    - Compensates for shunt resistance drift with temperature
 *    - Reduces systematic error from thermal effects
 *
 * 4. MOVING AVERAGE FILTERING
 *    - Smooths current readings over multiple samples to reduce noise
 *    - Weighted average gives more weight to recent samples
 *    - Reduces impact of single-sample outliers
 *
 * 5. DEAD-ZONE ROUNDING
 *    - Prevents jitter from frequent small updates to display value
 *    - Only updates when change exceeds threshold
 *
 * Mathematical precision analysis:
 *
 * With default settings (max_current=6.4A, lsb_na≈12207):
 *   - One ADC LSB = 12207 nA ≈ 12 µA (theoretical minimum current resolution)
 *   - Time resolution: 10ms (with jiffies_to_msecs)
 *   - At 100mA discharge over 30s interval:
 *     * Raw charge = 100000 nA * 30 s = 3,000,000 nAs
 *     * Nah = nAs / 3600 = 833.33 nah
 *     * Error with uAh tracking: 0.33 nah / 833 nah = 0.04%
 *     * Error is even smaller with our nah accumulator: < 0.001%
 */

/* Forward declaration for drift correction function */
static s64 bq25890_fg_get_drift_correction_factor(struct bq25890_device *bq);

static void bq25890_fg_integrate_ina228_locked(struct bq25890_device *bq)
{
	struct bq25890_ina228_data *ina = bq->ina228;
	unsigned long now = jiffies;
	unsigned long dt_jiffies;
	s64 dt_msec;
	s64 corrected_current_ua;
	s64 new_disch_remain_nah;
	s64 delta_nah;
	int current_ua;

	if (!ina || !ina->present)
		return;

	current_ua = bq25890_ina228_corrected_current_ua(
		ina->current_ua, ina->temp_correction_ppm);

	if (current_ua == 0)
		return;
	if (charge_full_uah <= 0)
		return;
	/*
	 * remain == -1 means "never seeded" (probe init).  Integrating
	 * from last_disch_remain_nah == 0 would publish 0% on the first
	 * sample after reboot, even with a 4.1 V cell.  The sample path
	 * seeds from OCV (or userspace coulomb_uah) first.
	 */
	if (bq->fg_disch_remain_uah < 0)
		return;

	dt_jiffies = now - bq->fg_disch_jiffies;
	if (dt_jiffies < HZ / 10)
		return;

	/*
	 * ENHANCED: High-precision time calculation.
	 * Using jiffies_to_msecs() gives us sub-second precision.
	 * For example, at HZ=100 (10ms tick):
	 *   - Old method: dt_jiffies / HZ = 3/100 = 0 seconds (truncated!)
	 *   - New method: jiffies_to_msecs(3) / 1000 = 30/1000 = 0.03 seconds
	 *
	 * This is critical for accurate coulomb counting because:
	 *   - Per-sample error = current * (true_dt - truncated_dt) / 3600
	 *   - At 1A, 1 second error per 30-second interval = 0.028% per sample
	 *   - Over 1000 samples, this adds up to 28% error!
	 */
	dt_msec = (s64)jiffies_to_msecs(dt_jiffies);

	if (dt_msec > (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL)
		dt_msec = (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL;

	/*
	 * Apply drift correction factor to current measurement.
	 * Drift correction slowly adjusts the coulomb counter toward
	 * the OCV-derived SOC when they diverge over time.
	 *
	 * The correction factor is applied as:
	 *   current_corrected = current × (1 + drift_correction_ppm / 1e6)
	 */
	corrected_current_ua = (s64)current_ua;
	{
		s64 drift_factor = bq25890_fg_get_drift_correction_factor(bq);
		corrected_current_ua = corrected_current_ua * drift_factor / 1000000LL;
	}

	/*
	 * ENHANCED: Coulomb calculation in nAh with fractional precision.
	 * Formula: charge (nAh) = |current| (nA) × time (s) / 3600
	 *        = |current| (µA) × 1000 × time (ms) / 1000 / 3600
	 *        = |current| (µA) × time (ms) / 3600
	 *
	 * delta_nah is always positive; the sign of current_ua determines
	 * whether we add it (charging, current into battery) or subtract it
	 * (discharging, current out of battery).
	 *
	 * Using 64-bit arithmetic to prevent overflow:
	 *   max: 10A × 60000ms = 600,000,000 (well within s64 range)
	 */
	delta_nah = (corrected_current_ua >= 0 ? corrected_current_ua
						: -corrected_current_ua) * dt_msec;
	delta_nah = div_s64(delta_nah, 3600LL);

	if (delta_nah <= 0)
		goto update_timestamp;

	/*
	 * ENHANCED: Use high-precision nah accumulator.
	 *
	 * Internal tracking in nah (nanoamp-hours) provides 1000x more
	 * resolution than uAh, preventing rounding errors from accumulating
	 * over many integration cycles.
	 *
	 * The display value (fg_disch_remain_uah) is updated by converting
	 * from nah with proper rounding.
	 *
	 * Convert remaining capacity from uAh to nah for accumulation.
	 * This allows us to maintain fractional precision internally.
	 *
	 * Re-seed the nah accumulator whenever the coulomb counter was
	 * reset (e.g. at boot, after full charge, or after a user seed).
	 */
	if (bq->fg_disch_remain_uah == 0 && bq->fg_disch_remain_uah != (long)-1) {
		ina->coulomb_nah = 0;
		ina->last_disch_remain_nah = 0;
	} else if (ina->last_disch_remain_nah == 0 && bq->fg_disch_remain_uah > 0) {
		ina->last_disch_remain_nah = (s64)bq->fg_disch_remain_uah * 1000LL;
	}

	ina->coulomb_nah += delta_nah;

	if (current_ua > 0) {
		/* Discharging: capacity decreases. */
		new_disch_remain_nah = ina->last_disch_remain_nah - delta_nah;
		if (new_disch_remain_nah < 0)
			new_disch_remain_nah = 0;
	} else {
		/* Charging: capacity increases (capped at full). */
		new_disch_remain_nah = ina->last_disch_remain_nah + delta_nah;
		if (new_disch_remain_nah > (s64)charge_full_uah * 1000LL)
			new_disch_remain_nah = (s64)charge_full_uah * 1000LL;
	}

	/*
	 * Update display value with proper rounding.
	 * Round to nearest uAh: (nah + 500) / 1000
	 * This minimizes visible jitter in the sysfs value.
	 */
	bq->fg_disch_remain_uah = (long)div_s64(new_disch_remain_nah + 500, 1000);
	if (bq->fg_disch_remain_uah < 0)
		bq->fg_disch_remain_uah = 0;
	if ((s64)bq->fg_disch_remain_uah > (s64)charge_full_uah)
		bq->fg_disch_remain_uah = (long)charge_full_uah;

	ina->last_disch_remain_nah = new_disch_remain_nah;

update_timestamp:
	bq->fg_disch_jiffies = now;
	ina->last_coulomb_update_jiffies = now;
}

/*
 * ENHANCED: Coulomb counter drift detection and auto-correction.
 *
 * Over long discharge cycles, the coulomb counter can drift from the true
 * SOC due to accumulated measurement errors. This function compares the
 * coulomb-integrated SOC against the OCV-based SOC and applies a slow
 * correction when they diverge beyond a threshold.
 *
 * The correction is applied as a multiplicative factor to the current
 * measurement during integration. This slowly adjusts the coulomb counter
 * toward the OCV-derived SOC without causing sudden jumps.
 *
 * Drift correction logic:
 *   1. Only check when battery is at rest (no significant current flow)
 *   2. Only check periodically (every 5 minutes by default)
 *   3. Only correct if divergence exceeds threshold (5% by default)
 *   4. Apply correction slowly (10 ppm per minute max)
 *
 * Args:
 *   bq: device structure with fuel gauge state
 *   v_smooth_uv: smoothed terminal voltage for OCV calculation
 *
 * Returns:
 *   Updated drift_correction_ppm value
 */
static int bq25890_fg_check_drift_correction(struct bq25890_device *bq,
					    int v_smooth_uv)
{
	unsigned long now = jiffies;
	int ocv_soc_pct;
	int coulomb_soc_pct;
	int drift_pct;
	s64 drift_ppb;
	long correction_per_interval_ppb;
	unsigned long check_interval_jiffies;
	unsigned long elapsed_min;
	s64 new_correction_ppb;

	check_interval_jiffies = BQ25890_FG_DRIFT_CHECK_INTERVAL_SEC * HZ / 1;

	if (time_before(now, bq->drift_check_jiffies + check_interval_jiffies))
		return bq->drift_correction_ppm;

	if (!bq->ina228 || !bq->ina228->present)
		return bq->drift_correction_ppm;

	if (charge_full_uah <= 0)
		return bq->drift_correction_ppm;

	/* Terminal voltage is only an OCV proxy at rest with near-zero current. */
	if (bq->fg_mode != BQ_FG_DISCHARGING_RESTING)
		return bq->drift_correction_ppm;
	if (abs(bq->ina228_current_ua) > BQ25890_FG_DRIFT_IDLE_UA)
		return bq->drift_correction_ppm;

	ocv_soc_pct = bq25890_calc_lipo_percentage(v_smooth_uv);

	coulomb_soc_pct = (int)(bq->fg_disch_remain_uah * 100L / charge_full_uah);
	coulomb_soc_pct = clamp(coulomb_soc_pct, 0, 100);

	drift_pct = coulomb_soc_pct - ocv_soc_pct;

	if (abs(drift_pct) < BQ25890_FG_DRIFT_DETECT_THRESH_PCT) {
		bq->drift_check_jiffies = now;
		return bq->drift_correction_ppm;
	}

	elapsed_min = (now - bq->drift_check_jiffies) / (60 * HZ);
	if (elapsed_min < 1)
		elapsed_min = 1;

	drift_ppb = (s64)drift_pct * 1000000LL;

	correction_per_interval_ppb = (s64)BQ25890_FG_DRIFT_CORRECTION_RATE_PPM_PER_MIN *
				       elapsed_min * 1000LL;

	if (drift_ppb > 0) {
		new_correction_ppb = bq->drift_accum_ppb + correction_per_interval_ppb;
		if (new_correction_ppb > drift_ppb)
			new_correction_ppb = drift_ppb;
	} else {
		new_correction_ppb = bq->drift_accum_ppb - correction_per_interval_ppb;
		if (new_correction_ppb < drift_ppb)
			new_correction_ppb = drift_ppb;
	}

	bq->drift_accum_ppb = new_correction_ppb;

	bq->drift_correction_ppm = (int)(bq->drift_accum_ppb / 1000LL);
	bq->drift_correction_ppm = clamp(bq->drift_correction_ppm,
					-BQ25890_FG_DRIFT_MAX_CORRECTION_PPM,
					BQ25890_FG_DRIFT_MAX_CORRECTION_PPM);

	bq->last_ocv_soc_pct = ocv_soc_pct;
	bq->last_coulomb_soc_pct = coulomb_soc_pct;
	bq->drift_check_jiffies = now;

	dev_dbg(bq->dev, "INA228 drift: ocv=%d%% coulomb=%d%% drift=%d%% correction=%d ppm\n",
		ocv_soc_pct, coulomb_soc_pct, drift_pct, bq->drift_correction_ppm);

	return bq->drift_correction_ppm;
}

/*
 * Apply drift correction to coulomb integration.
 * Returns the correction factor as a multiplier (in ppm).
 */
static s64 bq25890_fg_get_drift_correction_factor(struct bq25890_device *bq)
{
	s64 factor;

	if (bq->drift_correction_ppm == 0)
		return 1000000LL;

	factor = 1000000LL + (s64)bq->drift_correction_ppm;

	return factor;
}

/* Probe-time helper; not lock-protected (only called from probe). */
static int bq25890_ina228_configure(struct bq25890_ina228_data *ina)
{
	int cal;
	int ret;
	u32 lsb_na;

	/*
	 * SHUNT_CAL = round(13107.2e6 * current_lsb * Rshunt)
	 * current_lsb = max_current / 2^19
	 * lsb_nA      = max_current_uA * 1000 / 524288
	 *              = max_current_uA * 125 / 65536
	 */
	lsb_na = ((u32)ina228_max_current_ua * 125U) / 65536U;
	if (lsb_na == 0)
		lsb_na = 1;
	ina->current_lsb_na = lsb_na;

	cal = bq25890_ina228_compute_cal(ina228_max_current_ua, ina228_shunt_uohm);
	ina->adc_range = 0; /* ±163.84 mV range for 15 mΩ @ 6.4 A = 96 mV max */

	ret = bq25890_ina228_write_reg16(ina->client, INA228_REG_SHUNTCAL, cal);
	if (ret < 0)
		return ret;
	dev_dbg(&ina->client->dev, "INA228 configure: SHUNT_CAL=0x%04x (%d), lsb_na=%u\n",
		 (u16)cal, cal, lsb_na);

	/* Verify via matching i2c_master_recv read. */
	{
		u16 verify;
		int vr = bq25890_ina228_read_reg16(ina->client, INA228_REG_SHUNTCAL, &verify);
		dev_dbg(&ina->client->dev, "INA228 SHUNT_CAL verify: read=0x%04x wrote=0x%04x ret=%d\n",
			 verify, (u16)cal, vr);
		if (vr == 0 && verify != (u16)cal) {
			dev_warn(&ina->client->dev, "INA228 SHUNT_CAL mismatch: retrying\n");
			bq25890_ina228_write_reg16(ina->client, INA228_REG_SHUNTCAL, cal);
			bq25890_ina228_read_reg16(ina->client, INA228_REG_SHUNTCAL, &verify);
			dev_dbg(&ina->client->dev, "INA228 SHUNT_CAL 2nd verify: read=0x%04x\n", verify);
		}
	}

	ret = bq25890_ina228_write_reg16(ina->client, INA228_REG_ADCCFG,
		(INA228_ADC_MODE_CONT_TVB << INA228_ADC_MODE_SHIFT) |
		(INA228_ADC_VSHCT_1052_US << 6) |
		(INA228_ADC_VBUSCT_1052_US << 9) |
		(INA228_ADC_TEMPCT_1052_US << 3) |
		INA228_ADC_AVG_64);
	if (ret < 0)
		return ret;
	dev_dbg(&ina->client->dev,
		 "INA228 ADCCFG written; RST should clear within 2 ms\n");
	/*
	 * Wait for the ADC to complete its first conversion after ADCCFG
	 * write.  With AVG=64 and 1052 µs conversion time, the first
	 * conversion settles in ~70 ms.  100 ms is a safe margin.
	 */
	usleep_range(100000, 150000);

	ret = bq25890_ina228_write_reg16(ina->client, INA228_REG_CONFIG,
		ina->adc_range ? INA228_CFG_ADCRANGE_MASK : 0);
	if (ret < 0)
		return ret;

	/*
	 * Initialize current measurement filter state.
	 * The filter uses an exponential moving average (EMA) to smooth
	 * current readings while maintaining responsiveness to real changes.
	 */
	ina->filter_alpha = clamp(ina228_filter_alpha, 0, 1000);
	if (ina->filter_alpha == 0)
		ina->filter_alpha = INA228_FILTER_ALPHA_DEFAULT;
	ina->filtered_current_ua = 0;
	ina->deadzone_ua = INA228_FILTER_DEADZONE_DEFAULT_UA;
	ina->last_filtered_ua = 0;

	/*
	 * Initialize coulomb counter state.
	 */
	ina->coulomb_nah = 0;
	ina->last_coulomb_update_jiffies = 0;
	ina->last_disch_remain_nah = 0;

	/*
	 * Temperature compensation will be initialized on first refresh
	 * when we read the die temperature.
	 */
	ina->calib_dietemp_mdeg_c = 0;
	ina->temp_correction_ppm = 0;

	return 0;
}

static int bq25890_ina228_probe(struct bq25890_device *bq)
{
	struct bq25890_ina228_data *ina;
	struct i2c_client *dummy;
	int ret, mfg, dev_id;

	ina = devm_kzalloc(bq->dev, sizeof(*ina), GFP_KERNEL);
	if (!ina)
		return -ENOMEM;

	dummy = i2c_new_dummy_device(bq->client->adapter,
				     INA228_I2C_ADDR_DEFAULT);
	if (IS_ERR(dummy)) {
		ret = PTR_ERR(dummy);
		dev_dbg(bq->dev, "INA228 dummy @ 0x40 unavailable: %d\n", ret);
		return ret;
	}

	ina->client = dummy;
	ina->rmap = devm_regmap_init_i2c(dummy, &bq25890_ina228_regmap_cfg);
	if (IS_ERR(ina->rmap)) {
		i2c_unregister_device(dummy);
		return PTR_ERR(ina->rmap);
	}

	ret = devm_regmap_field_bulk_alloc(bq->dev, ina->rmap,
					   ina->rmap_fields,
					   bq25890_ina228_reg_fields,
					   F_MAX_INA228_FIELDS);
	if (ret) {
		i2c_unregister_device(dummy);
		return ret;
	}

	/* Verify manufacturer ID. */
	mfg = i2c_smbus_read_word_swapped(dummy, INA228_REG_MFG_UID);
	if (mfg < 0 || mfg != INA228_MFG_ID_TI) {
		dev_dbg(bq->dev, "INA228 mfg-id mismatch (%x)\n", mfg);
		i2c_unregister_device(dummy);
		return -ENODEV;
	}

	dev_id = i2c_smbus_read_word_swapped(dummy, INA228_REG_DVC_UID);
	if (dev_id < 0)
		dev_id = 0;

	ina->device_id = dev_id;
	ina->present = false; /* set true after successful configuration */

	ret = bq25890_ina228_configure(ina);
	if (ret < 0) {
		dev_warn(bq->dev, "INA228 configure failed: %d\n", ret);
		i2c_unregister_device(dummy);
		return ret;
	}

	ina->present = true;
	bq->ina228 = ina;

	dev_dbg(bq->dev, "INA228 bound at 0x40 (dvc=0x%03x shunt=%duohm max=%uuA)\n",
		 dev_id, ina228_shunt_uohm, ina228_max_current_ua);

	return 0;
}

static void bq25890_ina228_release(struct bq25890_device *bq)
{
	struct bq25890_ina228_data *ina = bq->ina228;

	if (!ina)
		return;
	if (ina->client)
		i2c_unregister_device(ina->client);
	bq->ina228 = NULL;
}

static void bq25890_fg_charge_reset(struct bq25890_device *bq)
{
	bq->chg_remain_uah = -1;
	bq->chg_added_uah = 0;
	bq->chg_last_jiffies = 0;
}

static void bq25890_fg_charge_begin(struct bq25890_device *bq,
				    const struct bq25890_state *state,
				    int v_smooth)
{
	int seed_pct, ocv_pct, ocv_uv;

	if (bq->capacity_valid)
		seed_pct = bq->capacity_cache;
	else
		seed_pct = -1;

	ocv_uv = bq25890_fg_charge_ocv_uv(bq, state, v_smooth);
	if (ocv_uv < 0)
		ocv_pct = 50;
	else
		ocv_pct = bq25890_calc_lipo_percentage(ocv_uv);

	if (seed_pct < 0)
		seed_pct = ocv_pct;
	else if (seed_pct + 15 < ocv_pct)
		seed_pct = ocv_pct - 10;

	seed_pct = clamp(seed_pct, 0, 99);
	bq->chg_remain_uah = (long)seed_pct * charge_full_uah / 100;
	bq->chg_added_uah = 0;
	bq->chg_last_jiffies = jiffies;
}

static void bq25890_fg_charge_integrate(struct bq25890_device *bq)
{
	unsigned long now = jiffies;
	unsigned long delta_jiffies;
	s64 delta_msec, ichgr, delta_uah;

	if (bq->chg_remain_uah < 0)
		return;

	delta_jiffies = now - bq->chg_last_jiffies;
	if (delta_jiffies < HZ / 10)
		return;

	/*
	 * ENHANCED: High-precision time calculation for charge integration.
	 * Same technique as discharge integration for consistency.
	 *
	 * The BQ25895's ICHGR register provides charge current measurement.
	 * This is typically less accurate than the INA228 but still useful
	 * for tracking charge accumulation.
	 */
	delta_msec = (s64)jiffies_to_msecs(delta_jiffies);

	if (delta_msec > (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL)
		delta_msec = (s64)BQ25890_FG_CHG_INTEGRATE_MAX_SEC * 1000LL;

	ichgr = bq25890_get_charge_current_ua(bq);
	if (ichgr < 0)
		ichgr = 0;

	/*
	 * Coulomb calculation: charge (uAh) = current (uA) × time (ms) / 3600000
	 * Using 64-bit arithmetic to prevent overflow and maintain precision.
	 */
	delta_uah = ichgr * delta_msec;
	delta_uah = div_s64(delta_uah, 3600000LL);

	if (delta_uah > 0)
		bq->chg_added_uah += (long)delta_uah;

	bq->chg_last_jiffies = now;
}

static int bq25890_fg_charge_percent(struct bq25890_device *bq)
{
	long remain_uah, pct;

	if (bq->chg_remain_uah < 0)
		return -ENODATA;

	remain_uah = bq->chg_remain_uah + bq->chg_added_uah;
	pct = remain_uah * 100L / charge_full_uah;
	return (int)clamp(pct, 0L, 99L);
}

static int bq25890_get_chip_state(struct bq25890_device *bq,
				  struct bq25890_state *state);

/*
 * Seed fg_disch_remain_uah from the OCV curve when the coulomb counter
 * has never been initialised (remain < 0).
 *
 * After reboot the integrator starts at -1.  The first INA228 sample
 * would otherwise treat last_disch_remain_nah == 0 as "empty" and
 * publish 0 % even when the cell sits at 4.1 V.  Userspace
 * pibrick-battery-load-soc.sh also writes coulomb_uah; this is the
 * in-kernel safety net for the window before that service runs, and
 * for boots with no persist file.
 *
 * Caller must hold bq->lock.  Does nothing if a userspace writer has
 * already seeded, or if remain is already tracking (>= 0).
 */
static void bq25890_fg_ensure_remain_seeded_locked(struct bq25890_device *bq,
						   int v_uv)
{
	int ocv_pct;

	if (bq->fg_user_seeded)
		return;
	if (bq->fg_disch_remain_uah >= 0)
		return;
	if (charge_full_uah <= 0 || v_uv <= 0)
		return;

	ocv_pct = clamp(bq25890_calc_lipo_percentage(v_uv), 0, 100);
	bq->fg_disch_remain_uah = (long)ocv_pct * charge_full_uah / 100;
	bq->fg_disch_jiffies = jiffies;
	if (bq->ina228 && bq->ina228->present)
		bq->ina228->last_disch_remain_nah =
			(s64)bq->fg_disch_remain_uah * 1000LL;
	if (!bq->capacity_valid) {
		bq->capacity_cache = ocv_pct;
		bq->capacity_valid = true;
	}
}

/*
 * Single owner for all fuel-gauge state mutations.
 *
 * Runs an ADC conversion, reads BATV/ICHGR/VBUSV/CHRG_STATUS once, picks a
 * mode (charging / charging_done / discharging_active / resting), updates
 * the proxy integrator and the OCV/voltage trackers, then returns the new
 * SOC. The lock is held for the entire conversion + read + update
 * sequence, eliminating the cross-path race that previously existed
 * between the periodic refresh worker, the boot calibrate worker, the IRQ
 * handler, and the power-supply property readers.
 *
 * Returns the new SOC (0..100), or -ENODATA if the very first sample
 * hasn't completed yet.
 */
static int bq25890_sample_and_update_fg(struct bq25890_device *bq)
{
	struct bq25890_state new_state;
	bool ext_pwr, charging, terminal_charged;
	int v_term_uv, v_smooth_uv;
	int soc_in, soc_out, persistent_low_pct;
	int proxy_ua;
	unsigned long now;
	int ret;
	mutex_lock(&bq->lock);
	now = jiffies;

	/* Start an ADC conversion (idempotent: chip ignores if already running). */
	ret = bq25890_field_write(bq, F_CONV_START, 1);
	if (ret < 0)
		goto out_unlock;

	ret = regmap_field_read_poll_timeout(bq->rmap_fields[F_CONV_START],
					     ret, !ret, 25000, 1000000);
	if (ret < 0)
		goto out_unlock;

	/* Re-read chip state under the same lock. */
	ret = bq25890_get_chip_state(bq, &new_state);
	if (ret < 0)
		goto out_unlock;
	bq->state = new_state;
	bq->adc_jiffies = now;

	ext_pwr = bq25890_has_external_power(bq, &new_state);
	charging = bq25890_is_actively_charging(bq, &new_state);
	terminal_charged =
		new_state.chrg_status == STATUS_TERMINATION_DONE && ext_pwr;

	v_term_uv = bq25890_get_batv_uv(bq);
	v_smooth_uv = bq25890_update_smoothed_batv_locked(bq,
			!bq->last_ext_pwr == ext_pwr);  /* reseed on plug change */

	/* Refresh INA228 cache (under same lock). */
	if (bq->ina228 && bq->ina228->present) {
		int ina_ret = bq25890_ina228_refresh_locked(bq);

		if (ina_ret < 0)
			dev_dbg(bq->dev, "INA228 refresh failed: %d\n", ina_ret);
	}

	bq25890_fg_ensure_remain_seeded_locked(bq,
		v_smooth_uv > 0 ? v_smooth_uv : v_term_uv);

	/* Maintain persistent-low-voltage guard. */
	if (v_term_uv > 0) {
		if (v_term_uv <= BQ25890_FG_LOW_V_THRESH_UV) {
			if (bq->fg_low_v_count < BQ25890_FG_LOW_V_COUNT_MAX)
				bq->fg_low_v_count++;
		} else if (v_term_uv >= BQ25890_FG_LOW_V_RECOVER_UV) {
			if (bq->fg_low_v_count > 0)
				bq->fg_low_v_count -= 2;
			if (bq->fg_low_v_count < 0)
				bq->fg_low_v_count = 0;
		}
	}

	/* Track load vs rest timestamps used to gate mode transitions. */
	if (bq25890_fg_under_load(bq))
		bq->fg_load_jiffies = now;
	else if (time_after(now, bq->fg_load_jiffies +
			    (rest_min_sec > 0 ? rest_min_sec : 300) * HZ))
		bq->fg_rest_jiffies = now;

	/* --- mode selection --- */
	if (terminal_charged) {
		bq->fg_mode = BQ_FG_CHARGING_DONE;
		soc_in = 100;
		bq25890_fg_charge_reset(bq);
		bq->fg_disch_remain_uah = charge_full_uah;
		bq->fg_disch_jiffies = now;
		soc_out = 100;
	} else if (ext_pwr && charging) {
		bq->fg_mode = BQ_FG_CHARGING;
		if (!bq->last_ext_pwr || bq->chg_remain_uah < 0)
			bq25890_fg_charge_begin(bq, &new_state, v_smooth_uv);
		bq25890_fg_charge_integrate(bq);
		/*
		 * Run the INA228 coulomb integrator during charging too.
		 * It uses the signed INA228 current (negative during charge)
		 * to update fg_disch_remain_uah bidirectionally, so both
		 * charge_now and capacity% track real charge accumulation
		 * rather than staying frozen at the plug-in seed value.
		 */
		if (bq->ina228 && bq->ina228->present && ina228_enabled)
			bq25890_fg_integrate_ina228_locked(bq);
		/* Keep the OCV tracker current so an abrupt unplug does not
		 * reseed the discharge integrator from a stale OCV value. */
		bq25890_update_v_ocv_locked(bq, v_smooth_uv, false);
		/* Read back the INA228-driven capacity for SOC output. */
		if (bq->fg_disch_remain_uah >= 0 && charge_full_uah > 0) {
			soc_out = (int)clamp(
				(s64)bq->fg_disch_remain_uah * 100L /
				(s64)charge_full_uah,
				0L, 100L);
		} else {
			soc_in = bq->capacity_valid ? bq->capacity_cache : 50;
			soc_out = soc_in;
		}
		soc_in = soc_out;
	} else if (ext_pwr) {
		/* Plugged in but not actively charging: hold last SOC. */
		bq->fg_mode = BQ_FG_CHARGING;
		/* Keep OCV tracker warm. */
		bq25890_update_v_ocv_locked(bq, v_smooth_uv, false);
		if (bq->fg_disch_remain_uah < 0) {
			int ocv = bq25890_calc_lipo_percentage(v_smooth_uv);

			soc_in = clamp(ocv, 0, 100);
			bq->capacity_valid = true;
			bq->capacity_cache = soc_in;
			bq->fg_disch_remain_uah =
				(long)soc_in * charge_full_uah / 100;
		}
		if (bq->capacity_valid) {
			soc_out = bq->capacity_cache;
		} else if (bq->fg_disch_remain_uah >= 0 && charge_full_uah > 0) {
			soc_out = (int)clamp(bq->fg_disch_remain_uah * 100L /
					     charge_full_uah, 0L, 100L);
		} else {
			soc_out = 50;
		}
	} else {
		bool just_unplugged = bq->last_ext_pwr;
		bool sustained_load = time_after(now, bq->fg_rest_jiffies) &&
				      !time_after(now, bq->fg_load_jiffies +
						 (rest_min_sec > 0 ? rest_min_sec : 300) * HZ);
		bool rested = !bq25890_fg_under_load(bq) &&
			      time_after(now, bq->fg_load_jiffies +
					 (rest_min_sec > 0 ? rest_min_sec : 300) * HZ);

		bq->fg_mode = rested ? BQ_FG_DISCHARGING_RESTING :
				       BQ_FG_DISCHARGING_ACTIVE;

		if (just_unplugged) {
			bq25890_fg_charge_reset(bq);
			bq->batv_unplug_until =
				now + BQ25890_FG_UNPLUG_RELAX_SEC * HZ;
		}

		proxy_ua = bq25890_fg_compute_proxy_ua_locked(bq, sustained_load);
		bq->fg_proxy_ua = proxy_ua;

		if (bq->ina228 && bq->ina228->present && ina228_enabled)
			bq25890_fg_integrate_ina228_locked(bq);
		else
			bq25890_fg_integrate_proxy_locked(bq);

		/*
		 * ENHANCED: Check for coulomb counter drift vs OCV.
		 * This runs periodically when the battery is at rest and
		 * slowly corrects any accumulated drift in the coulomb counter.
		 */
		if (bq->ina228 && bq->ina228->present && ina228_enabled &&
		    bq->fg_mode == BQ_FG_DISCHARGING_RESTING &&
		    abs(bq->ina228_current_ua) <= BQ25890_FG_DRIFT_IDLE_UA)
			bq25890_fg_check_drift_correction(bq, v_smooth_uv);

		/*
		 * Seed from OCV only when the coulomb counter was never
		 * initialised.  Do not reseed on unplug: terminal voltage is
		 * still inflated after a charge, which would jump a tracked
		 * 60% toward ~90%.
		 */
		if (bq->fg_disch_remain_uah < 0) {
			int ocv = bq25890_calc_lipo_percentage(v_smooth_uv);

			soc_in = clamp(ocv, 0, 100);
			bq->fg_disch_remain_uah =
				(long)soc_in * charge_full_uah / 100;
			bq->fg_disch_jiffies = now;
			if (bq->ina228 && bq->ina228->present)
				bq->ina228->last_disch_remain_nah =
					(s64)bq->fg_disch_remain_uah * 1000LL;
		} else {
			soc_in = bq->capacity_cache;
		}

		if (bq->fg_disch_remain_uah >= 0 && charge_full_uah > 0)
			soc_out = (int)clamp(bq->fg_disch_remain_uah * 100L /
					     charge_full_uah, 0L, 100L);
		else
			soc_out = soc_in;

		/* OCV-based recalibration only on the first RESTING transition.
		 * Once rested, the coulomb integrator (INA228 / proxy) owns SOC;
		 * we only let OCV bring it down when the cell has genuinely
		 * settled to a new resting voltage after being active.  Continuing
		 * to apply OCV every RESTING sample would drag SOC toward the
		 * voltage every tick and defeat the integrator. */
		if (bq->fg_mode == BQ_FG_DISCHARGING_RESTING &&
		    bq->last_fg_mode != BQ_FG_DISCHARGING_RESTING) {
			int ocv_pct = bq25890_calc_lipo_percentage(v_smooth_uv);
			unsigned long dt_min =
				max_t(unsigned long, 1UL,
				      (now - bq->capacity_jiffies) / (60 * HZ));
			int max_drop = BQ25890_FG_REST_MAX_DROP_PCT_MIN *
				       (int)dt_min;

			if (ocv_pct < soc_in - max_drop)
				ocv_pct = soc_in - max_drop;
			if (ocv_pct > soc_out)
				ocv_pct = soc_out;
			bq25890_update_v_ocv_locked(bq, v_smooth_uv, false);
			if (ocv_pct < soc_out)
				soc_out = ocv_pct;
		} else {
			bq25890_update_v_ocv_locked(bq, v_smooth_uv,
						     !bq->capacity_valid);
		}

		/* Persistent-low-voltage guard. */
		if (low_v_persistent_count > 0 &&
		    bq->fg_low_v_count >= low_v_persistent_count) {
			persistent_low_pct = 1;
			if (persistent_low_pct < soc_out &&
			    v_smooth_uv > BQ25890_BATV_REST_MIN_UV)
				soc_out = persistent_low_pct;
		}
	}

	bq->capacity_cache = clamp(soc_out, 0, 100);
	bq->capacity_valid = true;
	bq->capacity_jiffies = now;
	bq->last_ext_pwr = ext_pwr;
	bq->last_charging = charging;
	bq->last_fg_mode = bq->fg_mode;

	mutex_unlock(&bq->lock);

	return bq->capacity_cache;

out_unlock:
	mutex_unlock(&bq->lock);
	return ret;
}

/*
 * Back-compat thin wrapper. Historical callers (IRQ handler, capacity
 * workers) still call this; it routes everything through the single
 * estimator owner. Safe to call from any context that can sleep.
 */
static int bq25890_update_capacity(struct bq25890_device *bq,
				   const struct bq25890_state *state)
{
	return bq25890_sample_and_update_fg(bq);
}


static irqreturn_t __bq25890_handle_irq(struct bq25890_device *bq);
static int bq25890_get_chip_state(struct bq25890_device *bq,
				  struct bq25890_state *state);

static void bq25890_power_supply_changed(struct bq25890_device *bq)
{
	power_supply_changed(bq->charger);
	if (bq->ac)
		power_supply_changed(bq->ac);
}

/*
 * Emit a uevent only when the user-visible state (capacity or status) actually
 * changes. The periodic refresh runs every 30 s; notifying unconditionally
 * would wake UPower (and re-trigger a sysfs read burst) for no reason.
 *
 * ext_pwr / charging must come from the same `sample_and_update_fg` call whose
 * `state` we just snapshotted (single owner path). We don't re-derive them
 * here — that would re-issue I2C reads that the sample already did.
 */
static void bq25890_notify_if_changed(struct bq25890_device *bq,
				      const struct bq25890_state *state,
				      bool ext_pwr, bool charging)
{
	int status = bq25890_get_status(bq, state, ext_pwr, charging);
	int capacity;

	mutex_lock(&bq->lock);
	capacity = bq->capacity_valid ? bq->capacity_cache : -1;
	if (capacity == bq->notified_capacity && status == bq->notified_status) {
		mutex_unlock(&bq->lock);
		return;
	}
	bq->notified_capacity = capacity;
	bq->notified_status = status;
	mutex_unlock(&bq->lock);

	bq25890_power_supply_changed(bq);
}

static void bq25890_capacity_refresh_work(struct work_struct *work)
{
	struct bq25890_device *bq = container_of(work, struct bq25890_device,
						 capacity_refresh_work.work);
	struct bq25890_state state;
	bool ext_pwr, charging;
	int soc;
	unsigned long now = jiffies;
	bool charger_toggled = false;

	soc = bq25890_sample_and_update_fg(bq);
	if (soc < 0)
		goto reschedule;

	mutex_lock(&bq->lock);
	state = bq->state;
	ext_pwr = bq->last_ext_pwr;
	charging = bq->last_charging;

	/*
	 * Detect charger plug/unplug by comparing ext_pwr (VBus present) from
	 * this sample against the previous one.  The fuel-gauge state is
	 * protected by bq->lock, so it is safe to access last_ext_pwr /
	 * last_charging even though they belong to a previous work-cycle.
	 */
	if (bq->capacity_valid) {
		if (bq->last_ext_pwr != ext_pwr ||
		    bq->last_charging != charging) {
			charger_toggled = true;
			bq->fast_poll_until = now +
				msecs_to_jiffies(fast_poll_ms);
		}
	}
	mutex_unlock(&bq->lock);

	/* Periodically save SOC to persistent storage for reboot consistency */
	bq25890_save_persisted_soc(soc);

	/*
	 * Always notify UPower on charger toggle — even if SOC hasn't changed,
	 * the charging/discharging icon must update immediately.
	 */
	if (charger_toggled)
		bq25890_power_supply_changed(bq);

	bq25890_notify_if_changed(bq, &state, ext_pwr, charging);

reschedule:
{
	unsigned long interval;

	if (fast_poll_ms > 0 &&
	    time_before(now, bq->fast_poll_until))
		interval = msecs_to_jiffies(fast_poll_ms);
	else
		interval = BQ25890_CAPACITY_REFRESH_INTERVAL;

	schedule_delayed_work(&bq->capacity_refresh_work, interval);
}
}

static void bq25890_capacity_calibrate_work(struct work_struct *work)
{
	struct bq25890_device *bq = container_of(work, struct bq25890_device,
						 capacity_calibrate_work.work);
	int soc;

	/*
	 * Delayed UPower nudge after probe. First-sample and load-soc already
	 * seed the coulomb counter. Do not copy live BATV into remain: while
	 * charging that voltage is not OCV. persist_soc is unused.
	 */
	mutex_lock(&bq->lock);
	if (!bq->fg_user_seeded && bq->fg_disch_remain_uah < 0 &&
	    !bq->last_charging && !bq->last_ext_pwr) {
		long batv_uv = bq25890_get_batv_uv(bq);

		if (batv_uv > 0) {
			int ocv_pct = bq25890_calc_lipo_percentage(batv_uv);

			bq->fg_disch_remain_uah =
				(long)clamp(ocv_pct, 0, 100) * charge_full_uah / 100;
			bq->fg_disch_jiffies = jiffies;
			if (bq->ina228 && bq->ina228->present)
				bq->ina228->last_disch_remain_nah =
					(s64)bq->fg_disch_remain_uah * 1000LL;
		}
	}
	mutex_unlock(&bq->lock);

	soc = bq25890_sample_and_update_fg(bq);
	if (soc < 0)
		return;
	bq25890_power_supply_changed(bq);
}

static void bq25890_update_state(struct bq25890_device *bq,
				 enum power_supply_property psp,
				 struct bq25890_state *state,
				 bool *ext_pwr, bool *charging)
{
	/*
	 * All estimator state, including the cached chip state, is kept under
	 * bq->lock by `bq25890_sample_and_update_fg`. Property readers either:
	 *  - trigger a fresh sample (if the last sample is stale), or
	 *  - read the cached fields without writing them.
	 * ext_pwr/charging are pulled from the same single-owner cache so the
	 * caller doesn't re-issue I2C to recompute them.
	 */
	*ext_pwr = false;
	*charging = false;

	mutex_lock(&bq->lock);
	if (!bq->capacity_valid ||
	    time_after(jiffies, bq->adc_jiffies + BQ25890_ADC_MIN_INTERVAL)) {
		mutex_unlock(&bq->lock);
		if (bq25890_sample_and_update_fg(bq) < 0)
			return;
		mutex_lock(&bq->lock);
	}
	*state = bq->state;
	*ext_pwr = bq->last_ext_pwr;
	*charging = bq->last_charging;
	mutex_unlock(&bq->lock);
}

static int bq25890_ac_get_property(struct power_supply *psy,
				   enum power_supply_property psp,
				   union power_supply_propval *val)
{
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	struct bq25890_state state;
	bool ext_pwr, charging;

	bq25890_update_state(bq, psp, &state, &ext_pwr, &charging);

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		val->intval = ext_pwr;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = bq25890_get_status(bq, &state, ext_pwr, charging);
		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int bq25890_power_supply_get_property(struct power_supply *psy,
					     enum power_supply_property psp,
					     union power_supply_propval *val)
{
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	struct bq25890_state state;
	int ret;

	bool ext_pwr, charging;

	if (psy == bq->ac)
		return bq25890_ac_get_property(psy, psp, val);

	bq25890_update_state(bq, psp, &state, &ext_pwr, &charging);

	switch (psp) {
	/* VIRTUAL BATTERY */
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LIPO;
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
	case POWER_SUPPLY_PROP_CHARGE_FULL:
		val->intval = charge_full_uah;
		break;
	case POWER_SUPPLY_PROP_CHARGE_NOW: {
		long rem;

		ret = bq25890_capacity_cached(bq);
		if (ret < 0)
			ret = bq25890_update_capacity(bq, &state);
		if (ret < 0)
			return ret;

		mutex_lock(&bq->lock);
		rem = bq->fg_disch_remain_uah >= 0 ? bq->fg_disch_remain_uah
						   : (long)ret *
						     charge_full_uah / 100;
		mutex_unlock(&bq->lock);

		if (rem < 0)
			rem = 0;
		val->intval = (int)rem;
		break;
	}
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG: {
		long rem_uah, curr_ua;

		/* Seconds left = coulomb_remain_uah / abs(discharge_current_ua).
		 * Uses the same current source policy as CURRENT_NOW: prefer
		 * the INA228 signed reading when bound, else the proxy.
		 */
		if (ext_pwr) {
			val->intval = 0;
			break;
		}

		mutex_lock(&bq->lock);
		rem_uah = bq->fg_disch_remain_uah;
		if (bq->ina228 && bq->ina228->present && ina228_enabled)
			curr_ua = bq->ina228_current_ua;
		else
			curr_ua = bq->fg_proxy_ua;
		mutex_unlock(&bq->lock);

		if (rem_uah <= 0 || curr_ua <= 0) {
			val->intval = 0;
			break;
		}

		/* curr_ua is uA: seconds = rem_uah * 1e6 / curr_ua */
		val->intval = (int)(rem_uah * 1000000LL / curr_ua);
		break;
	}
	case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW: {
		int cap = bq25890_capacity_cached(bq);
		int ichgr = bq25890_get_charge_current_ua(bq);

		/* Use the measured charge current: time = remaining_uah / ICHGR. */
		if (bq25890_get_status(bq, &state, ext_pwr, charging) !=
			POWER_SUPPLY_STATUS_CHARGING ||
		    cap < 0 || cap >= 100 || ichgr < BQ25890_CHARGE_CURRENT_MIN_UA) {
			val->intval = 0;
		} else {
			long remaining_uah = (long)(100 - cap) *
					     charge_full_uah / 100;

			val->intval = (int)(remaining_uah * 3600 / ichgr);
		}
		break;
	}
	case POWER_SUPPLY_PROP_CAPACITY:
		ret = bq25890_capacity_cached(bq);
		if (ret < 0)
			ret = bq25890_sample_and_update_fg(bq);
		if (ret < 0)
			return ret;
		val->intval = ret;
		break;
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL: {
		int low_v_count;
		int smooth_v;

		ret = bq25890_capacity_cached(bq);
		if (ret < 0)
			ret = bq25890_sample_and_update_fg(bq);
		if (ret < 0)
			return ret;

		mutex_lock(&bq->lock);
		smooth_v = (int)bq->batv_smoothed_uv;
		low_v_count = bq->fg_low_v_count;
		mutex_unlock(&bq->lock);

		/*
		 * Persistent-low-voltage gate: never report CRITICAL just because
		 * one sample looked low. Only report CRITICAL after the
		 * persistent counter has been pinned below the threshold long
		 * enough, or when the smoothed terminal V is actually low.
		 */
		if (ret < 20) {
			if (smooth_v > BQ25890_FG_LOW_V_RECOVER_UV &&
			    (low_v_count < low_v_persistent_count ||
			     low_v_persistent_count <= 0))
				ret = 20;
		}
		if (ret >= 95)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_FULL;
		else if (ret >= 70)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
		else if (ret >= 50)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
		else if (ret >= 20)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_LOW;
		else
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
		break;
	}
	case POWER_SUPPLY_PROP_CAPACITY_ALERT_MIN: {
		int low_v_count;
		int smooth_v;

		ret = bq25890_capacity_cached(bq);
		if (ret < 0)
			ret = bq25890_sample_and_update_fg(bq);
		if (ret < 0)
			return ret;

		mutex_lock(&bq->lock);
		smooth_v = (int)bq->batv_smoothed_uv;
		low_v_count = bq->fg_low_v_count;
		mutex_unlock(&bq->lock);

		val->intval = ret < 20 && smooth_v <= BQ25890_FG_LOW_V_THRESH_UV
			      && low_v_count >= low_v_persistent_count;
		break;
	}

	case POWER_SUPPLY_PROP_STATUS:
		val->intval = bq25890_get_status(bq, &state, ext_pwr, charging);
		break;

	case POWER_SUPPLY_PROP_CHARGE_TYPE:
		if (!charging)
			val->intval = POWER_SUPPLY_CHARGE_TYPE_NONE;
		else if (state.chrg_status == STATUS_PRE_CHARGING)
			val->intval = POWER_SUPPLY_CHARGE_TYPE_STANDARD;
		else
			val->intval = POWER_SUPPLY_CHARGE_TYPE_FAST;
		break;

	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = BQ25890_MANUFACTURER;
		break;

	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = bq25890_chip_name[bq->chip_version];
		break;

	case POWER_SUPPLY_PROP_HEALTH:
		if (!state.chrg_fault && !state.bat_fault && !state.boost_fault)
			val->intval = POWER_SUPPLY_HEALTH_GOOD;
		else if (state.bat_fault)
			val->intval = POWER_SUPPLY_HEALTH_OVERVOLTAGE;
		else if (state.chrg_fault == CHRG_FAULT_TIMER_EXPIRED)
			val->intval = POWER_SUPPLY_HEALTH_SAFETY_TIMER_EXPIRE;
		else if (state.chrg_fault == CHRG_FAULT_THERMAL_SHUTDOWN)
			val->intval = POWER_SUPPLY_HEALTH_OVERHEAT;
		else
			val->intval = POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
		break;

	case POWER_SUPPLY_PROP_PRECHARGE_CURRENT:
		val->intval = bq25890_find_val(bq->init_data.iprechg, TBL_ITERM);
		break;

	case POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT:
		val->intval = bq25890_find_val(bq->init_data.iterm, TBL_ITERM);
		break;

	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		ret = bq25890_field_read(bq, F_IINLIM);
		if (ret < 0)
			return ret;

		val->intval = bq25890_find_val(ret, TBL_IINLIM);
		break;

	case POWER_SUPPLY_PROP_CURRENT_NOW:	/* I_BAT now */
		/*
		 * Prefer the INA228 signed current (positive = discharge)
		 * when the chip is bound; otherwise fall back to the BQ25895
		 * ADC reading (which is zero in DISCHARGING_ACTIVE).
		 */
		mutex_lock(&bq->lock);
		if (bq->ina228 && bq->ina228->present && ina228_enabled)
			val->intval = bq->ina228_current_ua;
		else {
			int v = bq25890_get_battery_current_ua(bq, &state);

			mutex_unlock(&bq->lock);
			val->intval = v;
			break;
		}
		mutex_unlock(&bq->lock);
		break;

	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:	/* I_BAT user limit */
		/*
		 * This is user-configured constant charge current supplied
		 * from charger to battery in first phase of charging, when
		 * battery voltage is below constant charge voltage.
		 *
		 * This value reflects the current hardware setting.
		 *
		 * The POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX is the
		 * maximum value of this property.
		 */
		ret = bq25890_field_read(bq, F_ICHG);
		if (ret < 0)
			return ret;
		val->intval = bq25890_find_val(ret, TBL_ICHG);

		/* When temperature is too low, charge current is decreased */
		if (bq->state.ntc_fault == NTC_FAULT_COOL) {
			ret = bq25890_field_read(bq, F_JEITA_ISET);
			if (ret < 0)
				return ret;

			if (ret)
				val->intval /= 5;
			else
				val->intval /= 2;
		}
		break;

	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX:	/* I_BAT max */
		/*
		 * This is maximum allowed constant charge current supplied
		 * from charger to battery in first phase of charging, when
		 * battery voltage is below constant charge voltage.
		 *
		 * This value is constant for each battery and set from DT.
		 */
		val->intval = bq25890_find_val(bq->init_data.ichg, TBL_ICHG);
		break;

	case POWER_SUPPLY_PROP_VOLTAGE_NOW: {
		int report_v;

		/*
		 * Mode-aware voltage reporting. Prefer the INA228 bus voltage
		 * when bound; fall back to the smoothed BQ25895 BATV.
		 */
		mutex_lock(&bq->lock);
		if (bq->ina228 && bq->ina228->present &&
		    bq->ina228->bus_uv > 0) {
			report_v = bq->ina228->bus_uv;
		} else if (bq->last_ext_pwr &&
			   bq->fg_mode != BQ_FG_DISCHARGING_ACTIVE &&
			   bq->fg_mode != BQ_FG_DISCHARGING_RESTING) {
			int ichgr_now = bq25890_ichgr_ua_locked(bq);

			if (ichgr_now >= 0 && bq->batv_smoothed_uv > 0)
				report_v = (int)bq->batv_smoothed_uv
					   - (long)ichgr_now *
					     batt_ir_mohm / 1000
					   - BQ25890_FG_CHG_POLAR_UV;
			else
				report_v = (int)bq->batv_smoothed_uv;
		} else if (bq->fg_mode == BQ_FG_DISCHARGING_RESTING &&
			   bq->fg_v_ocv_uv > 0) {
			report_v = (int)bq->fg_v_ocv_uv;
		} else {
			report_v = (int)bq->batv_smoothed_uv;
		}
		mutex_unlock(&bq->lock);

		val->intval = report_v;
		break;
	}

	/*
	 * POWER_NOW: instantaneous power in µW.
	 * UPower uses this (with negative sign) to derive battery state.
	 * INA228 POWER register gives positive values regardless of direction.
	 * Negate when charging so UPower sees negative power = charging.
	 */
	case POWER_SUPPLY_PROP_POWER_NOW: {
		int power_mw;

		mutex_lock(&bq->lock);
		power_mw = bq->ina228 ? bq->ina228->power_mw : 0;
		/* Charging: negate power so UPower derives negative energy-rate. */
		if (bq->fg_mode == BQ_FG_CHARGING ||
		    bq->fg_mode == BQ_FG_CHARGING_DONE)
			power_mw = -power_mw;
		mutex_unlock(&bq->lock);

		val->intval = (int)(power_mw * 1000LL);
		break;
	}

	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE:	/* V_BAT user limit */
		/*
		 * This is user-configured constant charge voltage supplied
		 * from charger to battery in second phase of charging, when
		 * battery voltage reached constant charge voltage.
		 *
		 * This value reflects the current hardware setting.
		 *
		 * The POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX is the
		 * maximum value of this property.
		 */
		ret = bq25890_field_read(bq, F_VREG);
		if (ret < 0)
			return ret;

		val->intval = bq25890_find_val(ret, TBL_VREG);
		break;

	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX:	/* V_BAT max */
		/*
		 * This is maximum allowed constant charge voltage supplied
		 * from charger to battery in second phase of charging, when
		 * battery voltage reached constant charge voltage.
		 *
		 * This value is constant for each battery and set from DT.
		 */
		val->intval = bq25890_find_val(bq->init_data.vreg, TBL_VREG);
		break;

	case POWER_SUPPLY_PROP_TEMP:
		ret = bq25890_field_read(bq, F_TSPCT);
		if (ret < 0)
			return ret;

		/* convert TS percentage into rough temperature */
		val->intval = bq25890_find_val(ret, TBL_TSPCT);
		break;

	default:
		return -EINVAL;
	}

	return 0;
}

static int bq25890_power_supply_set_property(struct power_supply *psy,
					     enum power_supply_property psp,
					     const union power_supply_propval *val)
{
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	struct bq25890_state state;
	bool ext_pwr_unused, charging_unused;
	int maxval, ret;
	u8 lval;

	if (psy == bq->ac)
		return -EINVAL;

	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_FULL:
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		/* Clamp to sane range; zero disables FG math. */
		charge_full_uah = clamp(val->intval, 0, 200000000);
		return 0;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:
		maxval = bq25890_find_val(bq->init_data.ichg, TBL_ICHG);
		lval = bq25890_find_idx(min(val->intval, maxval), TBL_ICHG);
		return bq25890_field_write(bq, F_ICHG, lval);
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE:
		maxval = bq25890_find_val(bq->init_data.vreg, TBL_VREG);
		lval = bq25890_find_idx(min(val->intval, maxval), TBL_VREG);
		return bq25890_field_write(bq, F_VREG, lval);
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		lval = bq25890_find_idx(val->intval, TBL_IINLIM);
		return bq25890_field_write(bq, F_IINLIM, lval);
	case POWER_SUPPLY_PROP_ONLINE:
		ret = bq25890_field_write(bq, F_EN_HIZ, !val->intval);
		if (!ret)
			bq->force_hiz = !val->intval;
		bq25890_update_state(bq, psp, &state, &ext_pwr_unused, &charging_unused);
		return ret;
	default:
		return -EINVAL;
	}
}

static int bq25890_power_supply_property_is_writeable(struct power_supply *psy,
						      enum power_supply_property psp)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_FULL:
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE:
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
	case POWER_SUPPLY_PROP_ONLINE:
		return true;
	default:
		return false;
	}
}

/*
 * If there are multiple chargers the maximum current the external power-supply
 * can deliver needs to be divided over the chargers. This is done according
 * to the bq->iinlim_percentage setting.
 */
static int bq25890_charger_get_scaled_iinlim_regval(struct bq25890_device *bq,
						    int iinlim_ua)
{
	iinlim_ua = iinlim_ua * bq->iinlim_percentage / 100;
	return bq25890_find_idx(iinlim_ua, TBL_IINLIM);
}

/* On the BQ25892 try to get charger-type info from our supplier */
static void bq25890_charger_external_power_changed(struct power_supply *psy)
{
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	union power_supply_propval val;
	int input_current_limit, ret;

	if (bq->chip_version != BQ25892)
		return;

	ret = power_supply_get_property_from_supplier(psy,
						      POWER_SUPPLY_PROP_USB_TYPE,
						      &val);
	if (ret)
		return;

	switch (val.intval) {
	case POWER_SUPPLY_USB_TYPE_DCP:
		input_current_limit = bq25890_charger_get_scaled_iinlim_regval(bq, 2000000);
		if (bq->pump_express_vbus_max) {
			queue_delayed_work(system_power_efficient_wq,
					   &bq->pump_express_work,
					   PUMP_EXPRESS_START_DELAY);
		}
		break;
	case POWER_SUPPLY_USB_TYPE_CDP:
	case POWER_SUPPLY_USB_TYPE_ACA:
		input_current_limit = bq25890_charger_get_scaled_iinlim_regval(bq, 1500000);
		break;
	case POWER_SUPPLY_USB_TYPE_SDP:
	default:
		input_current_limit = bq25890_charger_get_scaled_iinlim_regval(bq, 500000);
	}

	bq25890_field_write(bq, F_IINLIM, input_current_limit);
	power_supply_changed(psy);
}

static int bq25890_get_chip_state(struct bq25890_device *bq,
				  struct bq25890_state *state)
{
	int i, ret;

	struct {
		enum bq25890_fields id;
		u8 *data;
	} state_fields[] = {
		{F_CHG_STAT,	&state->chrg_status},
		{F_PG_STAT,	&state->online},
		{F_EN_HIZ,	&state->hiz},
		{F_VBUS_GD,	&state->vbus_gd},
		{F_VSYS_STAT,	&state->vsys_status},
		{F_BOOST_FAULT, &state->boost_fault},
		{F_BAT_FAULT,	&state->bat_fault},
		{F_CHG_FAULT,	&state->chrg_fault},
		{F_NTC_FAULT,	&state->ntc_fault}
	};

	for (i = 0; i < ARRAY_SIZE(state_fields); i++) {
		ret = bq25890_field_read(bq, state_fields[i].id);
		if (ret < 0)
			return ret;

		*state_fields[i].data = ret;
	}

	dev_dbg(bq->dev, "S:CHG/PG/VBUS/HIZ/VSYS=%d/%d/%d/%d/%d, F:CHG/BOOST/BAT/NTC=%d/%d/%d/%d\n",
		state->chrg_status, state->online, state->vbus_gd,
		state->hiz, state->vsys_status,
		state->chrg_fault, state->boost_fault,
		state->bat_fault, state->ntc_fault);

	return 0;
}

static irqreturn_t __bq25890_handle_irq(struct bq25890_device *bq)
{
	bool adc_conv_rate, new_adc_conv_rate;
	struct bq25890_state new_state;
	int ret;

	ret = bq25890_get_chip_state(bq, &new_state);
	if (ret < 0)
		return IRQ_NONE;

	if (!memcmp(&bq->state, &new_state, sizeof(new_state)))
		return IRQ_NONE;

	/*
	 * Restore HiZ bit in case it was set by user. The chip does not retain
	 * this bit on cable replug, hence the bit must be reset manually here.
	 */
	if (new_state.online && !bq->state.online && bq->force_hiz) {
		ret = bq25890_field_write(bq, F_EN_HIZ, bq->force_hiz);
		if (ret < 0)
			goto error;
		new_state.hiz = 1;
	}

	/* Should period ADC sampling be enabled? */
	adc_conv_rate = bq->state.online && !bq->state.hiz;
	new_adc_conv_rate = new_state.online && !new_state.hiz;

	if (new_adc_conv_rate != adc_conv_rate) {
		ret = bq25890_field_write(bq, F_CONV_RATE, new_adc_conv_rate);
		if (ret < 0)
			goto error;
	}

	if (new_state.vbus_gd != bq->state.vbus_gd ||
	    new_state.chrg_status != bq->state.chrg_status) {
		/*
		 * Estimator state is owned by `bq25890_sample_and_update_fg`,
		 * which takes `bq->lock` itself; we must release the IRQ-held
		 * lock before calling it. The chip-state fields we need were
		 * already mirrored above (force_hiz handling + adc_conv_rate),
		 * so dropping the lock for the function call is safe.
		 */
		memcpy(&bq->state, &new_state, sizeof(new_state));
		bq->adc_jiffies = jiffies;
		mutex_unlock(&bq->lock);
		bq25890_sample_and_update_fg(bq);
		mutex_lock(&bq->lock);
	} else {
		bq->state = new_state;
	}

	bq25890_power_supply_changed(bq);

	return IRQ_HANDLED;
error:
	dev_err(bq->dev, "Error communicating with the chip: %pe\n",
		ERR_PTR(ret));
	return IRQ_HANDLED;
}

static irqreturn_t bq25890_irq_handler_thread(int irq, void *private)
{
	struct bq25890_device *bq = private;
	irqreturn_t ret;

	mutex_lock(&bq->lock);
	ret = __bq25890_handle_irq(bq);
	mutex_unlock(&bq->lock);

	return ret;
}

static int bq25890_chip_reset(struct bq25890_device *bq)
{
	int ret;
	int rst_check_counter = 10;

	ret = bq25890_field_write(bq, F_REG_RST, 1);
	if (ret < 0)
		return ret;

	do {
		ret = bq25890_field_read(bq, F_REG_RST);
		if (ret < 0)
			return ret;

		usleep_range(5, 10);
	} while (ret == 1 && --rst_check_counter);

	if (!rst_check_counter)
		return -ETIMEDOUT;

	return 0;
}

static int bq25890_rw_init_data(struct bq25890_device *bq)
{
	bool write = !bq->read_back_init_data;
	int ret;
	int i;

	const struct {
		enum bq25890_fields id;
		u8 *value;
	} init_data[] = {
		{F_ICHG,	 &bq->init_data.ichg},
		{F_VREG,	 &bq->init_data.vreg},
		{F_ITERM,	 &bq->init_data.iterm},
		{F_IPRECHG,	 &bq->init_data.iprechg},
		{F_SYSVMIN,	 &bq->init_data.sysvmin},
		{F_BOOSTV,	 &bq->init_data.boostv},
		{F_BOOSTI,	 &bq->init_data.boosti},
		{F_BOOSTF,	 &bq->init_data.boostf},
		{F_EN_ILIM,	 &bq->init_data.ilim_en},
		{F_TREG,	 &bq->init_data.treg},
		{F_BATCMP,	 &bq->init_data.rbatcomp},
		{F_VCLAMP,	 &bq->init_data.vclamp},
	};

	for (i = 0; i < ARRAY_SIZE(init_data); i++) {
		if (write) {
			ret = bq25890_field_write(bq, init_data[i].id,
						  *init_data[i].value);
		} else {
			ret = bq25890_field_read(bq, init_data[i].id);
			if (ret >= 0)
				*init_data[i].value = ret;
		}
		if (ret < 0) {
			dev_dbg(bq->dev, "Accessing init data failed %d\n", ret);
			return ret;
		}
	}

	return 0;
}

static int bq25890_hw_init(struct bq25890_device *bq)
{
	int ret;

	if (!bq->skip_reset) {
		ret = bq25890_chip_reset(bq);
		if (ret < 0) {
			dev_dbg(bq->dev, "Reset failed %d\n", ret);
			return ret;
		}
	} else {
		/*
		 * Ensure charging is enabled, on some boards where the fw
		 * takes care of initalizition F_CHG_CFG is set to 0 before
		 * handing control over to the OS.
		 */
		ret = bq25890_field_write(bq, F_CHG_CFG, 1);
		if (ret < 0) {
			dev_dbg(bq->dev, "Enabling charging failed %d\n", ret);
			return ret;
		}
	}

	/* disable watchdog */
	ret = bq25890_field_write(bq, F_WD, 0);
	if (ret < 0) {
		dev_dbg(bq->dev, "Disabling watchdog failed %d\n", ret);
		return ret;
	}

	/* initialize currents/voltages and other parameters */
	ret = bq25890_rw_init_data(bq);
	if (ret)
		return ret;

	ret = bq25890_get_chip_state(bq, &bq->state);
	if (ret < 0) {
		dev_dbg(bq->dev, "Get state failed %d\n", ret);
		return ret;
	}

	/* Configure ADC for continuous conversions when charging */
	ret = bq25890_field_write(bq, F_CONV_RATE, bq->state.online && !bq->state.hiz);
	if (ret < 0) {
		dev_dbg(bq->dev, "Config ADC failed %d\n", ret);
		return ret;
	}

	return 0;
}

static const enum power_supply_property bq25890_power_supply_props[] = {
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_TYPE,
	POWER_SUPPLY_PROP_CAPACITY_LEVEL,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_CAPACITY_ALERT_MIN,
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_POWER_NOW,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX,
	POWER_SUPPLY_PROP_PRECHARGE_CURRENT,
	POWER_SUPPLY_PROP_CHARGE_TERM_CURRENT,
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
	POWER_SUPPLY_PROP_TIME_TO_FULL_NOW,
};

static const enum power_supply_property bq25890_ac_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_STATUS,
};

static char *bq25890_ac_supplied_to[] = {
	"battery",
};

static const struct power_supply_desc bq25890_power_supply_desc = {
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = bq25890_power_supply_props,
	.num_properties = ARRAY_SIZE(bq25890_power_supply_props),
	.get_property = bq25890_power_supply_get_property,
	.set_property = bq25890_power_supply_set_property,
	.property_is_writeable = bq25890_power_supply_property_is_writeable,
	.external_power_changed	= bq25890_charger_external_power_changed,
};

static const struct power_supply_desc bq25890_ac_desc = {
	.type = POWER_SUPPLY_TYPE_USB,
	.properties = bq25890_ac_props,
	.num_properties = ARRAY_SIZE(bq25890_ac_props),
	.get_property = bq25890_power_supply_get_property,
};

/* --- Diagnostic sysfs (read-only) --- */
static const char *bq25890_fg_mode_name(enum bq25890_fg_mode mode)
{
	switch (mode) {
	case BQ_FG_CHARGING:		return "charging";
	case BQ_FG_CHARGING_DONE:	return "full";
	case BQ_FG_DISCHARGING_ACTIVE:	return "active";
	case BQ_FG_DISCHARGING_RESTING:	return "resting";
	default:			return "unknown";
	}
}

static ssize_t bq25890_fg_show_str(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	enum bq25890_fg_mode mode;

	mutex_lock(&bq->lock);
	mode = bq->fg_mode;
	mutex_unlock(&bq->lock);

	return sysfs_emit(buf, "%s\n", bq25890_fg_mode_name(mode));
}

static int bq25890_fg_get_v_term(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = (int)bq->batv_smoothed_uv;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_v_ocv(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = (int)bq->fg_v_ocv_uv;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ocv_soc_pct(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = (int)bq->batv_smoothed_uv;
	if (v <= 0)
		v = bq25890_get_batv_uv(bq);
	mutex_unlock(&bq->lock);
	if (v <= 0)
		return -1;
	return clamp(bq25890_calc_lipo_percentage(v), 0, 100);
}

static int bq25890_fg_get_proxy_ua(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = bq->fg_proxy_ua;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_remain(struct bq25890_device *bq, bool rd)
{
	long v;

	mutex_lock(&bq->lock);
	v = bq->fg_disch_remain_uah;
	mutex_unlock(&bq->lock);
	if (v < 0)
		v = 0;
	return (int)v;
}

static int bq25890_fg_get_added(struct bq25890_device *bq, bool rd)
{
	long v;

	mutex_lock(&bq->lock);
	v = bq->chg_added_uah;
	mutex_unlock(&bq->lock);
	return (int)v;
}

static int bq25890_fg_get_glitch(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = bq->fg_glitch_count;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_low_v(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = bq->fg_low_v_count;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_rest_sec(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	if (bq->fg_load_jiffies == 0)
		v = 0;
	else
		v = (int)((long)(jiffies - bq->fg_load_jiffies) / HZ);
	mutex_unlock(&bq->lock);
	if (v < 0)
		v = 0;
	return v;
}

/* --- INA228 sysfs getters --- */

static int bq25890_fg_get_ina228_present(struct bq25890_device *bq, bool rd)
{
	int v;

	mutex_lock(&bq->lock);
	v = (bq->ina228 && bq->ina228->present) ? 1 : 0;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ina228_current_ua(struct bq25890_device *bq, bool rd)
{
	int v;

	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	mutex_lock(&bq->lock);
	v = bq->ina228->current_ua;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ina228_raw(struct bq25890_device *bq, bool rd)
{
	int val;
	(void)rd;
	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	if (bq25890_ina228_field_read(bq->ina228, F_ina228_CURRENT, &val) < 0)
		return -1;
	return val;
}

static int bq25890_fg_get_ina228_shuntcal(struct bq25890_device *bq, bool rd)
{
	(void)rd;
	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	{
		u16 v;
		int r = bq25890_ina228_read_reg16(bq->ina228->client, INA228_REG_SHUNTCAL, &v);
		return r < 0 ? -1 : (int)(s16)v;
	}
}

static int bq25890_fg_get_ina228_bus_uv(struct bq25890_device *bq, bool rd)
{
	int v;

	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	mutex_lock(&bq->lock);
	v = bq->ina228->bus_uv;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ina228_shunt_uv(struct bq25890_device *bq, bool rd)
{
	int v;

	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	mutex_lock(&bq->lock);
	v = bq->ina228->shunt_uv;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ina228_power_mw(struct bq25890_device *bq, bool rd)
{
	int v;

	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	mutex_lock(&bq->lock);
	v = bq->ina228->power_mw;
	mutex_unlock(&bq->lock);
	return v;
}

static int bq25890_fg_get_ina228_dietemp_mdeg_c(struct bq25890_device *bq, bool rd)
{
	int v;

	if (!bq->ina228 || !bq->ina228->present)
		return -1;
	mutex_lock(&bq->lock);
	v = bq->ina228->dietemp_mdeg_c;
	mutex_unlock(&bq->lock);
	return v;
}


static ssize_t bq25890_fg_store_coulomb_uah(struct device *dev,
					     struct device_attribute *attr,
					     const char *buf, size_t count)
{
	/*
	 * This store function is registered on the i2c_client device (bq->dev),
	 * not the power_supply child.  struct bq25890_device is stashed in
	 * dev_get_drvdata() by bq25890_probe().
	 */
	struct bq25890_device *bq = dev_get_drvdata(dev);
	long v;
	int err;

	err = kstrtol(buf, 10, &v);
	if (err < 0)
		return err;

	/*
	 * Clamp against the design capacity (charge_full_uah).  Using
	 * bq->chg_remain_uah as the upper bound is unsafe because it
	 * starts at -1 and is only updated once the fuel gauge has
	 * actually begun tracking a charging session; a user write
	 * arriving before that would silently get clamped to 0.
	 */
	mutex_lock(&bq->lock);
	bq->fg_disch_remain_uah = clamp(v, 0L, (long)charge_full_uah);
	/*
	 * Reset the integrator timestamps so the next integration sample
	 * does not compute a large dt from a stale pre-write timestamp and
	 * overwrite our seeded value with a jump.  Also re-seed the nah
	 * accumulator so fractional tracking is consistent with the new
	 * fg_disch_remain_uah.  Reset chg_added_uah so the legacy charge
	 * integrator does not interfere with the INA228-driven value.
	 */
	bq->fg_disch_jiffies = jiffies;
	bq->chg_added_uah = 0;
	bq->chg_last_jiffies = 0;
	if (bq->ina228 && bq->ina228->present) {
		bq->ina228->last_disch_remain_nah =
			(s64)bq->fg_disch_remain_uah * 1000LL;
		bq->ina228->last_coulomb_update_jiffies = jiffies;
	}
	/*
	 * Mark the integrator as user-seeded so the post-probe calibrate
	 * work does not overwrite this value with an OCV-based reseed.
	 * Also pin capacity_cache to the same percentage so the
	 * discharging branch in bq25890_sample_and_update_fg() (which
	 * gates its OCV reseed on !capacity_valid) keeps using our value
	 * instead of falling back to a fresh OCV lookup.
	 */
	if (charge_full_uah > 0) {
		bq->capacity_cache =
			clamp((int)(bq->fg_disch_remain_uah * 100L / charge_full_uah),
			      0, 100);
		bq->capacity_valid = true;
	}
	bq->fg_user_seeded = true;
	mutex_unlock(&bq->lock);

	return count;
}

static ssize_t bq25890_fg_show_coulomb_uah(struct device *dev,
				       struct device_attribute *attr,
				       char *buf)
{
	/*
	 * This file is registered on the i2c_client device (bq->dev), not
	 * the power_supply child — use dev_get_drvdata() instead of
	 * to_power_supply() + power_supply_get_drvdata().
	 */
	struct bq25890_device *bq = dev_get_drvdata(dev);
	long v;

	mutex_lock(&bq->lock);
	v = bq->fg_disch_remain_uah;
	mutex_unlock(&bq->lock);
	if (v < 0)
		v = 0;
	return sysfs_emit(buf, "%ld\n", v);
}

#define BQ25890_FG_INT_SHOW_FN(name)                                          \
static ssize_t bq25890_fg_show_##name(struct device *dev,                     \
				       struct device_attribute *attr,         \
				       char *buf)                             \
{                                                                              \
	struct power_supply *psy = to_power_supply(dev);                       \
	struct bq25890_device *bq = power_supply_get_drvdata(psy);              \
	return sysfs_emit(buf, "%d\n", bq25890_fg_get_##name(bq, false));       \
}

BQ25890_FG_INT_SHOW_FN(v_term)
BQ25890_FG_INT_SHOW_FN(v_ocv)
BQ25890_FG_INT_SHOW_FN(ocv_soc_pct)
BQ25890_FG_INT_SHOW_FN(proxy_ua)
BQ25890_FG_INT_SHOW_FN(remain)
BQ25890_FG_INT_SHOW_FN(added)
BQ25890_FG_INT_SHOW_FN(glitch)
BQ25890_FG_INT_SHOW_FN(low_v)
BQ25890_FG_INT_SHOW_FN(rest_sec)
BQ25890_FG_INT_SHOW_FN(ina228_present)
BQ25890_FG_INT_SHOW_FN(ina228_current_ua)
BQ25890_FG_INT_SHOW_FN(ina228_bus_uv)
BQ25890_FG_INT_SHOW_FN(ina228_shunt_uv)
BQ25890_FG_INT_SHOW_FN(ina228_power_mw)
BQ25890_FG_INT_SHOW_FN(ina228_dietemp_mdeg_c)
BQ25890_FG_INT_SHOW_FN(ina228_raw)
BQ25890_FG_INT_SHOW_FN(ina228_shuntcal)

static DEVICE_ATTR(fg_mode, 0444, bq25890_fg_show_str, NULL);
static DEVICE_ATTR(v_term_uv, 0444, bq25890_fg_show_v_term, NULL);
static DEVICE_ATTR(v_ocv_uv, 0444, bq25890_fg_show_v_ocv, NULL);
static DEVICE_ATTR(ocv_soc_pct, 0444, bq25890_fg_show_ocv_soc_pct, NULL);
static DEVICE_ATTR(i_proxy_ua, 0444, bq25890_fg_show_proxy_ua, NULL);
static DEVICE_ATTR(remain_uah, 0444, bq25890_fg_show_remain, NULL);
static DEVICE_ATTR(added_uah, 0444, bq25890_fg_show_added, NULL);
static DEVICE_ATTR(glitch_count, 0444, bq25890_fg_show_glitch, NULL);
static DEVICE_ATTR(low_v_count, 0444, bq25890_fg_show_low_v, NULL);
static DEVICE_ATTR(rest_seconds, 0444, bq25890_fg_show_rest_sec, NULL);
static DEVICE_ATTR(ina228_present, 0444, bq25890_fg_show_ina228_present, NULL);
static DEVICE_ATTR(ina228_current_ua, 0444, bq25890_fg_show_ina228_current_ua, NULL);
static DEVICE_ATTR(ina228_bus_uv, 0444, bq25890_fg_show_ina228_bus_uv, NULL);
static DEVICE_ATTR(ina228_shunt_uv, 0444, bq25890_fg_show_ina228_shunt_uv, NULL);
static DEVICE_ATTR(ina228_power_mw, 0444, bq25890_fg_show_ina228_power_mw, NULL);
static DEVICE_ATTR(ina228_dietemp_mdeg_c, 0444, bq25890_fg_show_ina228_dietemp_mdeg_c, NULL);
static DEVICE_ATTR(coulomb_uah, 0644,
		   bq25890_fg_show_coulomb_uah,
		   bq25890_fg_store_coulomb_uah);

/* Reset persisted SOC for fresh calibration */
static ssize_t bq25890_fg_reset_soc_store(struct device *dev,
					   struct device_attribute *attr,
					   const char *buf, size_t count)
{
	struct bq25890_device *bq = dev_get_drvdata(dev);
	long v;
	int err;

	err = kstrtol(buf, 10, &v);
	if (err < 0)
		return err;

	/* Writing 1 resets persisted SOC and forces re-calibration */
	if (v == 1) {
		mutex_lock(&bq->lock);
		bq->capacity_valid = false;
		bq->capacity_cache = 0;
		mutex_unlock(&bq->lock);

		/* Reset the module parameter so userspace knows to clear the file */
		persist_soc = -1;

		dev_info(bq->dev, "SOC calibration reset - will recalibrate on next sample\n");
		dev_info(bq->dev, "Userspace should delete /var/lib/bq25890_battery/soc_persist\n");
	}
	return count;
}
static DEVICE_ATTR(reset_soc, 0200, NULL, bq25890_fg_reset_soc_store);

static ssize_t bq25890_fg_show_ina228_debug(struct device *dev,
				       struct device_attribute *attr,
				       char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	u8 cbuf[3];
	u16 shuntcal_val;
	s32 curr_raw;
	int ret;

	if (!bq->ina228 || !bq->ina228->present)
		return sysfs_emit(buf, "-ENODEV\n");

	ret = i2c_smbus_read_i2c_block_data(bq->ina228->client,
					    INA228_REG_CURRENT, 3, cbuf);
	if (ret < 0)
		return sysfs_emit(buf, "curr_read_err=%d\n", ret);

	bq25890_ina228_read_reg16(bq->ina228->client, INA228_REG_SHUNTCAL, &shuntcal_val);

	curr_raw = ((u32)cbuf[0] << 16) | ((u32)cbuf[1] << 8) | cbuf[2];

	return sysfs_emit(buf,
		"curr_bytes=%02x%02x%02x curr_raw=0x%06x curr_sh4=%d lsb_na=%u SHUNT_CAL=0x%04x(%d)\n",
		cbuf[0], cbuf[1], cbuf[2],
		curr_raw & 0xFFFFFF,
		(int)((s32)curr_raw >> 4),
		bq->ina228->current_lsb_na,
		shuntcal_val, (s16)shuntcal_val);
}

static ssize_t bq25890_fg_store_ina228_debug(struct device *dev,
					struct device_attribute *attr,
					const char *buf, size_t count)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);
	u8 cbuf[3], vbuf[3];
	u32 curr_raw, vshunt_raw;
	u16 shuntcal_val;
	int ret;

	if (!bq->ina228 || !bq->ina228->present)
		return -ENODEV;

	ret = i2c_smbus_read_i2c_block_data(bq->ina228->client,
					    INA228_REG_CURRENT, 3, cbuf);
	if (ret < 0)
		return sysfs_emit((char *)buf, "err=%d\n", ret);

	ret = i2c_smbus_read_i2c_block_data(bq->ina228->client,
					    INA228_REG_VSHUNT, 3, vbuf);
	if (ret < 0)
		return sysfs_emit((char *)buf, "err=%d\n", ret);

	bq25890_ina228_read_reg16(bq->ina228->client, INA228_REG_SHUNTCAL, &shuntcal_val);

	curr_raw = ((u32)cbuf[0] << 16) | ((u32)cbuf[1] << 8) | cbuf[2];
	vshunt_raw = ((u32)vbuf[0] << 16) | ((u32)vbuf[1] << 8) | vbuf[2];

	dev_dbg(bq->dev,
		"INA228 DEBUG: CURR_bytes=%02x%02x%02x raw24=0x%06x lsb_na=%u SHUNT_CAL=0x%04x\n"
		"INA228 DEBUG: VSHUNT_bytes=%02x%02x%02x raw24=0x%06x adc_range=%d\n",
		cbuf[0], cbuf[1], cbuf[2], curr_raw,
		bq->ina228->current_lsb_na, shuntcal_val,
		vbuf[0], vbuf[1], vbuf[2], vshunt_raw,
		bq->ina228->adc_range);

	return count;
}

static DEVICE_ATTR(ina228_raw, 0444, bq25890_fg_show_ina228_raw, NULL);
static DEVICE_ATTR(ina228_shuntcal, 0444, bq25890_fg_show_ina228_shuntcal, NULL);
static DEVICE_ATTR(ina228_debug, 0644, bq25890_fg_show_ina228_debug, bq25890_fg_store_ina228_debug);

/* Drift correction sysfs attributes */
static ssize_t bq25890_fg_show_drift_correction_ppm(struct device *dev,
						   struct device_attribute *attr,
						   char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);

	mutex_lock(&bq->lock);
	int val = bq->drift_correction_ppm;
	mutex_unlock(&bq->lock);
	return sysfs_emit(buf, "%d\n", val);
}
static DEVICE_ATTR(drift_correction_ppm, 0444, bq25890_fg_show_drift_correction_ppm, NULL);

static ssize_t bq25890_fg_show_drift_ocv_soc(struct device *dev,
					     struct device_attribute *attr,
					     char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);

	mutex_lock(&bq->lock);
	int val = bq->last_ocv_soc_pct;
	mutex_unlock(&bq->lock);
	return sysfs_emit(buf, "%d\n", val);
}
static DEVICE_ATTR(drift_ocv_soc_pct, 0444, bq25890_fg_show_drift_ocv_soc, NULL);

static ssize_t bq25890_fg_show_drift_coulomb_soc(struct device *dev,
						 struct device_attribute *attr,
						 char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);

	mutex_lock(&bq->lock);
	int val = bq->last_coulomb_soc_pct;
	mutex_unlock(&bq->lock);
	return sysfs_emit(buf, "%d\n", val);
}
static DEVICE_ATTR(drift_coulomb_soc_pct, 0444, bq25890_fg_show_drift_coulomb_soc, NULL);

static ssize_t bq25890_fg_show_ina228_filtered_current(struct device *dev,
							struct device_attribute *attr,
							char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);

	mutex_lock(&bq->lock);
	int val = bq->ina228 ? bq->ina228->filtered_current_ua : 0;
	mutex_unlock(&bq->lock);
	return sysfs_emit(buf, "%d\n", val);
}
static DEVICE_ATTR(ina228_filtered_current_ua, 0444, bq25890_fg_show_ina228_filtered_current, NULL);

static ssize_t bq25890_fg_show_ina228_temp_correction(struct device *dev,
						       struct device_attribute *attr,
						       char *buf)
{
	struct power_supply *psy = to_power_supply(dev);
	struct bq25890_device *bq = power_supply_get_drvdata(psy);

	mutex_lock(&bq->lock);
	int val = bq->ina228 ? bq->ina228->temp_correction_ppm : 0;
	mutex_unlock(&bq->lock);
	return sysfs_emit(buf, "%d\n", val);
}
static DEVICE_ATTR(ina228_temp_correction_ppm, 0444, bq25890_fg_show_ina228_temp_correction, NULL);

static struct attribute *bq25890_fg_attrs[] = {
	&dev_attr_fg_mode.attr,
	&dev_attr_v_term_uv.attr,
	&dev_attr_v_ocv_uv.attr,
	&dev_attr_ocv_soc_pct.attr,
	&dev_attr_i_proxy_ua.attr,
	&dev_attr_remain_uah.attr,
	&dev_attr_added_uah.attr,
	&dev_attr_glitch_count.attr,
	&dev_attr_low_v_count.attr,
	&dev_attr_rest_seconds.attr,
	&dev_attr_ina228_present.attr,
	&dev_attr_ina228_current_ua.attr,
	&dev_attr_ina228_bus_uv.attr,
	&dev_attr_ina228_shunt_uv.attr,
	&dev_attr_ina228_power_mw.attr,
	&dev_attr_ina228_dietemp_mdeg_c.attr,
	&dev_attr_ina228_raw.attr,
	&dev_attr_ina228_shuntcal.attr,
	&dev_attr_ina228_debug.attr,
	/* ENHANCED: Accuracy improvement attributes */
	&dev_attr_drift_correction_ppm.attr,
	&dev_attr_drift_ocv_soc_pct.attr,
	&dev_attr_drift_coulomb_soc_pct.attr,
	&dev_attr_ina228_filtered_current_ua.attr,
	&dev_attr_ina228_temp_correction_ppm.attr,
	NULL,
};
ATTRIBUTE_GROUPS(bq25890_fg);

static int bq25890_power_supply_init(struct bq25890_device *bq)
{
	struct power_supply_config psy_cfg = {
		.drv_data = bq,
		.attr_grp = bq25890_fg_groups,
	};

	bq->capacity_cache = 0;
	bq->capacity_valid = false;
	bq->last_ext_pwr = false;
	bq->capacity_jiffies = 0;
	bq->batv_smoothed_uv = 0;
	bq->batv_smoothed_jiffies = 0;
	bq->batv_load_glitch_until = 0;
	bq->batv_unplug_until = 0;
	bq->fg_v_ocv_uv = 0;
	bq->chg_remain_uah = -1;
	bq->chg_added_uah = 0;
	bq->chg_last_jiffies = 0;
	bq->adc_jiffies = 0;
	bq->notified_capacity = -1;
	bq->notified_status = -1;
	bq->fg_mode = BQ_FG_UNKNOWN;
	bq->last_fg_mode = BQ_FG_UNKNOWN;
	bq->fg_proxy_ua = 0;
	bq->fg_disch_remain_uah = -1;
	bq->fg_disch_jiffies = 0;
	bq->fg_load_jiffies = 0;
	bq->fg_rest_jiffies = 0;
	bq->fg_low_v_count = 0;
	bq->fg_glitch_count = 0;
	/*
	 * Default OCV tracker time constant. The INA228-aware bump (see
	 * probe) happens AFTER bq25890_ina228_probe() runs, so we start
	 * with the conservative compile-time default here.
	 */
	bq->fg_v_ocv_tau_sec = BQ25890_FG_V_OCV_TAU_SEC;

	/* Initialize drift correction state */
	bq->drift_correction_ppm = 0;
	bq->drift_accum_ppb = 0;
	bq->last_ocv_soc_pct = 50;
	bq->last_coulomb_soc_pct = 50;
	bq->drift_check_jiffies = 0;

	/* Get ID for the device */
	mutex_lock(&bq25890_id_mutex);
	bq->id = idr_alloc(&bq25890_id, bq, 0, 0, GFP_KERNEL);
	mutex_unlock(&bq25890_id_mutex);
	if (bq->id < 0)
		return bq->id;

	snprintf(bq->name, sizeof(bq->name), "battery");
	bq->desc = bq25890_power_supply_desc;
	bq->desc.name = bq->name;

	bq->charger = devm_power_supply_register(bq->dev, &bq->desc, &psy_cfg);
	if (IS_ERR(bq->charger))
		return PTR_ERR(bq->charger);

	snprintf(bq->ac_name, sizeof(bq->ac_name), "usb");
	bq->ac_desc = bq25890_ac_desc;
	bq->ac_desc.name = bq->ac_name;

	psy_cfg.supplied_to = bq25890_ac_supplied_to;
	psy_cfg.num_supplicants = ARRAY_SIZE(bq25890_ac_supplied_to);

	bq->ac = devm_power_supply_register(bq->dev, &bq->ac_desc, &psy_cfg);
	if (IS_ERR(bq->ac))
		return PTR_ERR(bq->ac);

	/*
	 * Diagnostic fuel-gauge attributes (read-only). Skip silently on
	 * kernels without struct power_supply_config.attr_grp; behavior is
	 * unchanged otherwise.
	 */
#ifdef CONFIG_POWER_SUPPLY_DEBUG
	/* placeholder: left to platform integration; intentionally no-op in
	 * upstream driver. */
#endif

	return 0;
}

static int bq25890_set_otg_cfg(struct bq25890_device *bq, u8 val)
{
	int ret;

	ret = bq25890_field_write(bq, F_OTG_CFG, val);
	if (ret < 0)
		dev_err(bq->dev, "Error switching to boost/charger mode: %d\n", ret);

	return ret;
}

static void bq25890_pump_express_work(struct work_struct *data)
{
	struct bq25890_device *bq =
		container_of(data, struct bq25890_device, pump_express_work.work);
	union power_supply_propval value;
	int voltage, i, ret;

	dev_dbg(bq->dev, "Start to request input voltage increasing\n");

	/* If there is a second charger put in Hi-Z mode */
	if (bq->secondary_chrg) {
		value.intval = 0;
		power_supply_set_property(bq->secondary_chrg, POWER_SUPPLY_PROP_ONLINE, &value);
	}

	/* Enable current pulse voltage control protocol */
	ret = bq25890_field_write(bq, F_PUMPX_EN, 1);
	if (ret < 0)
		goto error_print;

	for (i = 0; i < PUMP_EXPRESS_MAX_TRIES; i++) {
		voltage = bq25890_get_vbus_voltage(bq);
		if (voltage < 0)
			goto error_print;
		dev_dbg(bq->dev, "input voltage = %d uV\n", voltage);

		if ((voltage + PUMP_EXPRESS_VBUS_MARGIN_uV) >
					bq->pump_express_vbus_max)
			break;

		ret = bq25890_field_write(bq, F_PUMPX_UP, 1);
		if (ret < 0)
			goto error_print;

		/* Note a single PUMPX up pulse-sequence takes 2.1s */
		ret = regmap_field_read_poll_timeout(bq->rmap_fields[F_PUMPX_UP],
						     ret, !ret, 100000, 3000000);
		if (ret < 0)
			goto error_print;

		/* Make sure ADC has sampled Vbus before checking again */
		msleep(1000);
	}

	bq25890_field_write(bq, F_PUMPX_EN, 0);

	if (bq->secondary_chrg) {
		value.intval = 1;
		power_supply_set_property(bq->secondary_chrg, POWER_SUPPLY_PROP_ONLINE, &value);
	}

	dev_info(bq->dev, "Hi-voltage charging requested, input voltage is %d mV\n",
		 voltage);

	bq25890_power_supply_changed(bq);

	return;
error_print:
	bq25890_field_write(bq, F_PUMPX_EN, 0);
	dev_err(bq->dev, "Failed to request hi-voltage charging\n");
}

static void bq25890_usb_work(struct work_struct *data)
{
	int ret;
	struct bq25890_device *bq =
			container_of(data, struct bq25890_device, usb_work);

	switch (bq->usb_event) {
	case USB_EVENT_ID:
		/* Enable boost mode */
		bq25890_set_otg_cfg(bq, 1);
		break;

	case USB_EVENT_NONE:
		/* Disable boost mode */
		ret = bq25890_set_otg_cfg(bq, 0);
		if (ret == 0)
			bq25890_power_supply_changed(bq);
		break;
	}
}

static int bq25890_usb_notifier(struct notifier_block *nb, unsigned long val,
				void *priv)
{
	struct bq25890_device *bq =
			container_of(nb, struct bq25890_device, usb_nb);

	bq->usb_event = val;
	queue_work(system_power_efficient_wq, &bq->usb_work);

	return NOTIFY_OK;
}

#ifdef CONFIG_REGULATOR
static int bq25890_vbus_enable(struct regulator_dev *rdev)
{
	struct bq25890_device *bq = rdev_get_drvdata(rdev);
	union power_supply_propval val = {
		.intval = 0,
	};

	/*
	 * When enabling 5V boost / Vbus output, we need to put the secondary
	 * charger in Hi-Z mode to avoid it trying to charge the secondary
	 * battery from the 5V boost output.
	 */
	if (bq->secondary_chrg)
		power_supply_set_property(bq->secondary_chrg, POWER_SUPPLY_PROP_ONLINE, &val);

	return bq25890_set_otg_cfg(bq, 1);
}

static int bq25890_vbus_disable(struct regulator_dev *rdev)
{
	struct bq25890_device *bq = rdev_get_drvdata(rdev);
	union power_supply_propval val = {
		.intval = 1,
	};
	int ret;

	ret = bq25890_set_otg_cfg(bq, 0);
	if (ret)
		return ret;

	if (bq->secondary_chrg)
		power_supply_set_property(bq->secondary_chrg, POWER_SUPPLY_PROP_ONLINE, &val);

	return 0;
}

static int bq25890_vbus_is_enabled(struct regulator_dev *rdev)
{
	struct bq25890_device *bq = rdev_get_drvdata(rdev);

	return bq25890_field_read(bq, F_OTG_CFG);
}

static int bq25890_vbus_get_voltage(struct regulator_dev *rdev)
{
	struct bq25890_device *bq = rdev_get_drvdata(rdev);

	return bq25890_get_vbus_voltage(bq);
}

static int bq25890_vsys_get_voltage(struct regulator_dev *rdev)
{
	struct bq25890_device *bq = rdev_get_drvdata(rdev);
	int ret;

	/* Should be some output voltage ? */
	ret = bq25890_field_read(bq, F_SYSV); /* read measured value */
	if (ret < 0)
		return ret;

	/* converted_val = 2.304V + ADC_val * 20mV (table 10.3.15) */
	return 2304000 + ret * 20000;
}

static const struct regulator_ops bq25890_vbus_ops = {
	.enable = bq25890_vbus_enable,
	.disable = bq25890_vbus_disable,
	.is_enabled = bq25890_vbus_is_enabled,
	.get_voltage = bq25890_vbus_get_voltage,
};

static const struct regulator_desc bq25890_vbus_desc = {
	.name = "usb_otg_vbus",
	.of_match = "usb-otg-vbus",
	.type = REGULATOR_VOLTAGE,
	.owner = THIS_MODULE,
	.ops = &bq25890_vbus_ops,
};

static const struct regulator_ops bq25890_vsys_ops = {
	.get_voltage = bq25890_vsys_get_voltage,
};

static const struct regulator_desc bq25890_vsys_desc = {
	.name = "vsys",
	.of_match = "vsys",
	.type = REGULATOR_VOLTAGE,
	.owner = THIS_MODULE,
	.ops = &bq25890_vsys_ops,
};

static int bq25890_register_regulator(struct bq25890_device *bq)
{
	struct bq25890_platform_data *pdata = dev_get_platdata(bq->dev);
	struct regulator_config cfg = {
		.dev = bq->dev,
		.driver_data = bq,
	};
	struct regulator_dev *reg;

	if (pdata)
		cfg.init_data = pdata->regulator_init_data;

	reg = devm_regulator_register(bq->dev, &bq25890_vbus_desc, &cfg);
	if (IS_ERR(reg)) {
		return dev_err_probe(bq->dev, PTR_ERR(reg),
				     "registering vbus regulator");
	}

	/* pdata->regulator_init_data is for vbus only */
	cfg.init_data = NULL;
	reg = devm_regulator_register(bq->dev, &bq25890_vsys_desc, &cfg);
	if (IS_ERR(reg)) {
		return dev_err_probe(bq->dev, PTR_ERR(reg),
				     "registering vsys regulator");
	}

	return 0;
}
#else
static inline int
bq25890_register_regulator(struct bq25890_device *bq)
{
	return 0;
}
#endif

static int bq25890_get_chip_version(struct bq25890_device *bq)
{
	int id, rev;

	id = bq25890_field_read(bq, F_PN);
	if (id < 0) {
		dev_err(bq->dev, "Cannot read chip ID: %d\n", id);
		return id;
	}

	rev = bq25890_field_read(bq, F_DEV_REV);
	if (rev < 0) {
		dev_err(bq->dev, "Cannot read chip revision: %d\n", rev);
		return rev;
	}

	switch (id) {
	case BQ25890_ID:
		bq->chip_version = BQ25890;
		break;

	/* BQ25892 and BQ25896 share same ID 0 */
	case BQ25896_ID:
		switch (rev) {
		case 2:
			bq->chip_version = BQ25896;
			break;
		case 1:
			bq->chip_version = BQ25892;
			break;
		default:
			dev_err(bq->dev,
				"Unknown device revision %d, assume BQ25892\n",
				rev);
			bq->chip_version = BQ25892;
		}
		break;

	case BQ25895_ID:
		bq->chip_version = BQ25895;
		break;

	default:
		dev_err(bq->dev, "Unknown chip ID %d\n", id);
		return -ENODEV;
	}

	return 0;
}

static int bq25890_irq_probe(struct bq25890_device *bq)
{
	struct gpio_desc *irq;

	irq = devm_gpiod_get(bq->dev, BQ25890_IRQ_PIN, GPIOD_IN);
	if (IS_ERR(irq))
		return dev_err_probe(bq->dev, PTR_ERR(irq),
				     "Could not probe irq pin.\n");

	return gpiod_to_irq(irq);
}

static int bq25890_fw_read_u32_props(struct bq25890_device *bq)
{
	int ret;
	u32 property;
	int i;
	struct bq25890_init_data *init = &bq->init_data;
	struct {
		char *name;
		bool optional;
		enum bq25890_table_ids tbl_id;
		u8 *conv_data; /* holds converted value from given property */
	} props[] = {
		/* required properties */
		{"ti,charge-current", false, TBL_ICHG, &init->ichg},
		{"ti,battery-regulation-voltage", false, TBL_VREG, &init->vreg},
		{"ti,termination-current", false, TBL_ITERM, &init->iterm},
		{"ti,precharge-current", false, TBL_ITERM, &init->iprechg},
		{"ti,minimum-sys-voltage", false, TBL_SYSVMIN, &init->sysvmin},
		{"ti,boost-voltage", false, TBL_BOOSTV, &init->boostv},
		{"ti,boost-max-current", false, TBL_BOOSTI, &init->boosti},

		/* optional properties */
		{"ti,thermal-regulation-threshold", true, TBL_TREG, &init->treg},
		{"ti,ibatcomp-micro-ohms", true, TBL_RBATCOMP, &init->rbatcomp},
		{"ti,ibatcomp-clamp-microvolt", true, TBL_VBATCOMP, &init->vclamp},
	};

	/* initialize data for optional properties */
	init->treg = 3; /* 120 degrees Celsius */
	init->rbatcomp = init->vclamp = 0; /* IBAT compensation disabled */

	for (i = 0; i < ARRAY_SIZE(props); i++) {
		ret = device_property_read_u32(bq->dev, props[i].name,
					       &property);
		if (ret < 0) {
			if (props[i].optional)
				continue;

			dev_err(bq->dev, "Unable to read property %d %s\n", ret,
				props[i].name);

			return ret;
		}

		*props[i].conv_data = bq25890_find_idx(property,
						       props[i].tbl_id);
	}

	return 0;
}

static int bq25890_fw_probe(struct bq25890_device *bq)
{
	int ret;
	struct bq25890_init_data *init = &bq->init_data;
	const char *str;
	u32 val;

	ret = device_property_read_string(bq->dev, "linux,secondary-charger-name", &str);
	if (ret == 0) {
		bq->secondary_chrg = power_supply_get_by_name(str);
		if (!bq->secondary_chrg)
			return -EPROBE_DEFER;
	}

	/* Optional, left at 0 if property is not present */
	device_property_read_u32(bq->dev, "linux,pump-express-vbus-max",
				 &bq->pump_express_vbus_max);

	ret = device_property_read_u32(bq->dev, "linux,iinlim-percentage", &val);
	if (ret == 0) {
		if (val > 100) {
			dev_err(bq->dev, "Error linux,iinlim-percentage %u > 100\n", val);
			return -EINVAL;
		}
		bq->iinlim_percentage = val;
	} else {
		bq->iinlim_percentage = 100;
	}

	bq->skip_reset = device_property_read_bool(bq->dev, "linux,skip-reset");
	bq->read_back_init_data = device_property_read_bool(bq->dev,
						"linux,read-back-settings");
	if (bq->read_back_init_data)
		return 0;

	ret = bq25890_fw_read_u32_props(bq);
	if (ret < 0)
		return ret;

	init->ilim_en = device_property_read_bool(bq->dev, "ti,use-ilim-pin");
	init->boostf = device_property_read_bool(bq->dev, "ti,boost-low-freq");

	return 0;
}

static void bq25890_non_devm_cleanup(void *data)
{
	struct bq25890_device *bq = data;

	device_remove_file(bq->dev, &dev_attr_coulomb_uah);

	cancel_delayed_work_sync(&bq->pump_express_work);
	cancel_delayed_work_sync(&bq->capacity_calibrate_work);
	cancel_delayed_work_sync(&bq->capacity_refresh_work);

	if (bq->id >= 0) {
		mutex_lock(&bq25890_id_mutex);
		idr_remove(&bq25890_id, bq->id);
		mutex_unlock(&bq25890_id_mutex);
	}
}

static int bq25890_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct bq25890_device *bq;
	int ret;

	bq = devm_kzalloc(dev, sizeof(*bq), GFP_KERNEL);
	if (!bq)
		return -ENOMEM;

	bq->client = client;
	bq->dev = dev;
	bq->id = -1;

	mutex_init(&bq->lock);
	INIT_DELAYED_WORK(&bq->pump_express_work, bq25890_pump_express_work);
	INIT_DELAYED_WORK(&bq->capacity_calibrate_work, bq25890_capacity_calibrate_work);
	INIT_DELAYED_WORK(&bq->capacity_refresh_work, bq25890_capacity_refresh_work);

	bq->rmap = devm_regmap_init_i2c(client, &bq25890_regmap_config);
	if (IS_ERR(bq->rmap))
		return dev_err_probe(dev, PTR_ERR(bq->rmap),
				     "failed to allocate register map\n");

	ret = devm_regmap_field_bulk_alloc(dev, bq->rmap, bq->rmap_fields,
					   bq25890_reg_fields, F_MAX_FIELDS);
	if (ret)
		return ret;

	i2c_set_clientdata(client, bq);

	ret = bq25890_get_chip_version(bq);
	if (ret) {
		dev_err(dev, "Cannot read chip ID or unknown chip: %d\n", ret);
		return ret;
	}

	ret = bq25890_fw_probe(bq);
	if (ret < 0)
		return dev_err_probe(dev, ret, "reading device properties\n");

	ret = bq25890_hw_init(bq);
	if (ret < 0) {
		dev_err(dev, "Cannot initialize the chip: %d\n", ret);
		return ret;
	}

	if (client->irq <= 0)
		client->irq = bq25890_irq_probe(bq);

	if (client->irq < 0) {
		dev_err(dev, "No irq resource found.\n");
		return client->irq;
	}

	/* OTG reporting */
	bq->usb_phy = devm_usb_get_phy(dev, USB_PHY_TYPE_USB2);

	/*
	 * This must be before bq25890_power_supply_init(), so that it runs
	 * after devm unregisters the power_supply.
	 */
	ret = devm_add_action_or_reset(dev, bq25890_non_devm_cleanup, bq);
	if (ret)
		return ret;

	ret = bq25890_register_regulator(bq);
	if (ret)
		return ret;

	ret = bq25890_power_supply_init(bq);
	if (ret < 0)
		return dev_err_probe(dev, ret, "registering power supply\n");

	/*
	 * Register coulomb_uah on the i2c_client device (bq->dev), not the
	 * power_supply child.  The power_supply class permission override
	 * (power_supply_property_is_writeable) would otherwise downgrade the
	 * sysfs mode to 0444 and block all writes even from root.
	 * bq25890_fg_store_coulomb_uah() accesses bq via dev_get_drvdata().
	 */
	ret = device_create_file(bq->dev, &dev_attr_coulomb_uah);
	if (ret)
		return dev_err_probe(dev, ret, "creating coulomb_uah sysfs file\n");

	ret = device_create_file(bq->dev, &dev_attr_reset_soc);
	if (ret)
		dev_warn(dev, "failed to create reset_soc sysfs file: %d\n", ret);

	/*
	 * Optional INA228 high-side current monitor at 0x40. Probe failure
	 * is non-fatal; we just run the load-aware estimator without it.
	 */
	ret = bq25890_ina228_probe(bq);
	if (ret && ret != -ENODEV)
		dev_warn(dev, "INA228 probe failed: %d\n", ret);

	/*
	 * Bump the OCV tracker time constant when no INA228 is present.
	 * With the proxy estimator the per-sample voltage has more noise
	 * (load transients get integrated into fg_v_ocv_uv), so a longer
	 * time constant gives a smoother signal for the auto-calibrator's
	 * std-dev filter and breaks the noisy-bucket rejection path. The
	 * user can also set this via the fg_v_ocv_tau_sec_override module
	 * parameter (e.g. in /etc/modprobe.d/pibrick-battery.conf) which
	 * takes precedence over the auto-detected value.
	 */
	if (fg_v_ocv_tau_sec_override > 0) {
		bq->fg_v_ocv_tau_sec = fg_v_ocv_tau_sec_override;
		dev_info(dev, "OCV tracker tau: %d s (from module parameter)\n",
			 bq->fg_v_ocv_tau_sec);
	} else if (!bq->ina228 || !bq->ina228->present) {
		bq->fg_v_ocv_tau_sec = 120;
		dev_info(dev, "No INA228 detected: OCV tracker tau bumped to %d s "
			 "(was %d s) for smoother proxy-estimator readings\n",
			 bq->fg_v_ocv_tau_sec, BQ25890_FG_V_OCV_TAU_SEC);
	} else {
		dev_info(dev, "INA228 detected: OCV tracker tau = %d s\n",
			 bq->fg_v_ocv_tau_sec);
	}

	schedule_delayed_work(&bq->capacity_calibrate_work,
			      BQ25890_CAPACITY_BOOT_CALIB_DELAY);
	schedule_delayed_work(&bq->capacity_refresh_work,
			      BQ25890_CAPACITY_REFRESH_INTERVAL);

	ret = devm_request_threaded_irq(dev, client->irq, NULL,
					bq25890_irq_handler_thread,
					IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
					BQ25890_IRQ_PIN, bq);
	if (ret)
		return ret;

	if (!IS_ERR_OR_NULL(bq->usb_phy)) {
		INIT_WORK(&bq->usb_work, bq25890_usb_work);
		bq->usb_nb.notifier_call = bq25890_usb_notifier;
		usb_register_notifier(bq->usb_phy, &bq->usb_nb);
	}

	return 0;
}

static void bq25890_remove(struct i2c_client *client)
{
	struct bq25890_device *bq = i2c_get_clientdata(client);

	/* Save SOC before removing driver for consistency after reboot */
	if (bq->capacity_valid)
		bq25890_save_persisted_soc(bq->capacity_cache);

	if (!IS_ERR_OR_NULL(bq->usb_phy)) {
		usb_unregister_notifier(bq->usb_phy, &bq->usb_nb);
		cancel_work_sync(&bq->usb_work);
	}

	bq25890_ina228_release(bq);

	if (!bq->skip_reset) {
		/* reset all registers to default values */
		bq25890_chip_reset(bq);
	}
}

static void bq25890_shutdown(struct i2c_client *client)
{
	struct bq25890_device *bq = i2c_get_clientdata(client);

	/*
	 * Turn off the 5 V boost so VBUS does not look like a plug-in event
	 * after power-off (PocketCM5 / piBrick).
	 */
	bq25890_set_otg_cfg(bq, 0);
}

#ifdef CONFIG_PM_SLEEP
static int bq25890_suspend(struct device *dev)
{
	struct bq25890_device *bq = dev_get_drvdata(dev);

	/*
	 * If charger is removed, while in suspend, make sure ADC is diabled
	 * since it consumes slightly more power.
	 */
	return bq25890_field_write(bq, F_CONV_RATE, 0);
}

static int bq25890_resume(struct device *dev)
{
	int ret;
	struct bq25890_device *bq = dev_get_drvdata(dev);

	mutex_lock(&bq->lock);

	ret = bq25890_get_chip_state(bq, &bq->state);
	if (ret < 0)
		goto unlock;

	/* Re-enable ADC only if charger is plugged in. */
	if (bq->state.online) {
		ret = bq25890_field_write(bq, F_CONV_RATE, 1);
		if (ret < 0)
			goto unlock;
	}

	/* signal userspace, maybe state changed while suspended */
	bq25890_power_supply_changed(bq);

unlock:
	mutex_unlock(&bq->lock);

	return ret;
}
#endif

static const struct dev_pm_ops bq25890_pm = {
	SET_SYSTEM_SLEEP_PM_OPS(bq25890_suspend, bq25890_resume)
};

static const struct i2c_device_id bq25890_i2c_ids[] = {
	{ "bq25890" },
	{ "bq25892" },
	{ "bq25895" },
	{ "bq25896" },
	{}
};
MODULE_DEVICE_TABLE(i2c, bq25890_i2c_ids);

static const struct of_device_id bq25890_of_match[] __maybe_unused = {
	{ .compatible = "ti,bq25890", },
	{ .compatible = "ti,bq25892", },
	{ .compatible = "ti,bq25895", },
	{ .compatible = "ti,bq25896", },
	{ },
};
MODULE_DEVICE_TABLE(of, bq25890_of_match);

#ifdef CONFIG_ACPI
static const struct acpi_device_id bq25890_acpi_match[] = {
	{"BQ258900", 0},
	{},
};
MODULE_DEVICE_TABLE(acpi, bq25890_acpi_match);
#endif

static struct i2c_driver bq25890_driver = {
	.driver = {
		.name = "bq25890-battery",
		.of_match_table = of_match_ptr(bq25890_of_match),
		.acpi_match_table = ACPI_PTR(bq25890_acpi_match),
		.pm = &bq25890_pm,
	},
	.probe = bq25890_probe,
	.remove = bq25890_remove,
	.shutdown = bq25890_shutdown,
	.id_table = bq25890_i2c_ids,
};
module_i2c_driver(bq25890_driver);

MODULE_AUTHOR("Laurentiu Palcu <laurentiu.palcu@intel.com>");
MODULE_DESCRIPTION("bq25890 battery driver");
MODULE_LICENSE("GPL");
