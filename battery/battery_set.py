#!/usr/bin/env python3
#!/usr/bin/env python3
"""
Battery/INA228 interactive parameter setter.

This tool configures battery driver parameters for the piBrick system.
It provides both interactive and non-interactive modes for reading and
modifying battery-related settings.

USAGE:
    sudo python3 battery_set.py                  # Interactive menu mode
    sudo python3 battery_set.py <param> <value> # Set value directly
    sudo python3 battery_set.py <param>          # Read current value
    sudo python3 battery_set.py --list           # Show all parameters with details
    sudo python3 battery_set.py --list-verbose   # Show extended explanations

IMPORTANT - PERSISTENCE:
    Changes to module parameters take effect IMMEDIATELY but are NOT saved
    across reboots by default. To persist changes across reboots, use the
    --persist flag or manually create a /etc/modprobe.d configuration file.

    Example to persist a change:
        sudo python3 battery_set.py <param> <value> --persist

PERSISTENCE MODES:
    1. LIVE values (e.g., coulomb_uah): Changed immediately, but overwritten
       by the fuel gauge within seconds. These cannot be persisted.

    2. SYSFS values: Changed immediately, lost on reboot unless saved to
       a startup script or systemd service.

    3. MODULE parameters: Changed immediately, RESET on driver reload/reboot.
       Use --persist to save to modprobe.d and automatically reload the driver.
"""

import os
import sys
import argparse
import subprocess

# ANSI color codes for terminal output
COLOR_RESET = "\033[0m"
COLOR_BOLD = "\033[1m"
COLOR_RED = "\033[91m"
COLOR_YELLOW = "\033[93m"
COLOR_GREEN = "\033[92m"
COLOR_CYAN = "\033[96m"
COLOR_DIM = "\033[2m"

# Whether to use colored output (auto-detect terminal support)
USE_COLOR = sys.stdout.isatty()

def colored(text, color):
    """Apply color to text if terminal supports it."""
    if USE_COLOR:
        return f"{color}{text}{COLOR_RESET}"
    return text

def bold(text):
    return colored(text, COLOR_BOLD)

def warn(text):
    return colored(text, COLOR_YELLOW)

def error(text):
    return colored(text, COLOR_RED)

def success(text):
    return colored(text, COLOR_GREEN)

def info(text):
    return colored(text, COLOR_CYAN)

BASE_POWER = "/sys/class/power_supply/battery"
BASE_MODULE = "/sys/module/bq25890_battery/parameters"


# =============================================================================
# PARAMETER DEFINITIONS
# =============================================================================
# Each parameter has metadata explaining its purpose, units, and behavior.
#
# KIND classification determines persistence behavior:
#   "module"  - Written to /sys/module/.../parameters/<name>
#               Changes take effect immediately
#               RESET to driver defaults on driver reload (modprobe -r && modprobe)
#               PERSISTENT only if saved to /etc/modprobe.d/*.conf or
#               passed as modprobe options
#
#   "sysfs"   - Written to /sys/class/power_supply/battery/<name>
#               Changes take effect immediately
#               RESET to driver defaults on reboot
#               PERSISTENT only if saved to a startup script
#
#   "live"    - Written to sysfs, but VALUE IS OVERWRITTEN by the fuel gauge
#               within seconds of writing
#               CANNOT BE PERSISTED - treat as momentary bias only
#
# UNIT_SCALES: Display units are shown in human-friendly format (mAh, mV, etc.)
#              Internal storage uses raw kernel units (uAh, uV, etc.)


def _find_i2c_client_path():
    """Locate the bq25890 i2c client sysfs dir by walking /sys.

    After the driver fix, the writable coulomb_uah sysfs file is attached to
    the i2c_client device (bq->dev), not the power_supply child. The path
    looks like:
        /sys/devices/platform/<bus>/i2c-<n>/<n>-00XX/
    where the leaf directory name contains the chip's i2c address (e.g. 6a).

    We identify it by walking the i2c bus subtree and looking for a leaf
    directory that has a 'name' file containing "bq25890" (standard i2c
    client name).
    """
    devs_root = "/sys/bus/i2c/devices"
    if not os.path.isdir(devs_root):
        return None
    for entry in os.listdir(devs_root):
        name_path = os.path.join(devs_root, entry, "name")
        try:
            with open(name_path) as f:
                name = f.read().strip().lower()
        except (FileNotFoundError, PermissionError, OSError):
            continue
        if "bq25890" in name or "bq25895" in name:
            return os.path.join(devs_root, entry)
    return None


_I2C_CLIENT_CACHE = [None, None]  # [resolved_path]


def _i2c_client_path():
    """Cached lookup of the bq25890 i2c client sysfs dir."""
    if _I2C_CLIENT_CACHE[0] is not None:
        return _I2C_CLIENT_CACHE[0]
    _I2C_CLIENT_CACHE[0] = _find_i2c_client_path()
    return _I2C_CLIENT_CACHE[0]


def sysfs_path(name):
    p = PARAMS[name]
    if p["kind"] == "module":
        return f"{BASE_MODULE}/{name}"
    # Live value: prefer the i2c client path (where the driver fix placed it).
    # Fall back to the power_supply class path for older driver builds, or to
    # whichever one actually has the file present.
    base = _i2c_client_path()
    if base is not None and os.path.exists(os.path.join(base, name)):
        return f"{base}/{name}"
    if os.path.exists(os.path.join(BASE_POWER, name)):
        return f"{BASE_POWER}/{name}"
    if base is not None:
        return f"{base}/{name}"
    return f"{BASE_POWER}/{name}"

# Module parameters (need driver reload to take effect; not persistent without
# passing them on the modprobe command line or via /etc/modprobe.d/<name>.conf)
# Sysfs parameters (immediate effect; some are live fuel-gauge values).
#
# Three persistence classes are exposed:
#   "module"  -> /sys/module/.../parameters/<name>, reload_required, persistable
#   "sysfs"   -> /sys/class/power_supply/battery/<name>, immediate, NOT persistable
#   "live"    -> like sysfs but the value is overwritten by the running fuel-gauge
#                logic within seconds; treat writes as a momentary bias, not a set
PARAMS = {
    "charge_full_uah": {
        "desc": "Battery design capacity (microamp-hours)",
        "detail": (
            "The total capacity of the battery as designed (in microamp-hours). "
            "This value is used as the reference '100%%' for state-of-charge "
            "calculations. Set this to match your battery's actual rated "
            "capacity. The PocketCM5 ships with a 3800 mAh pack, so the "
            "compile-time default is 4800000 uAh. For a 5000 mAh battery, "
            "enter 5000000 uAh.\n"
            "\n"
            "Note: The kernel also exports 'charge_full' (current full capacity) "
            "and 'charge_full_design' (original design capacity). This parameter "
            "corresponds to 'charge_full_design' - the rated capacity, not the "
            "current capacity which may decrease with battery wear over time."
        ),
        "unit": "mAh",
        "unit_hint": "mAh",
        "kind": "module",
        "default": 4800000,
    },
    "ina228_shunt_uohm": {
        "desc": "INA228 shunt resistance",
        "detail": (
            "The resistance value (in micro-ohms) of the physical shunt resistor "
            "connected to the INA228 current sensor. This value is used to convert "
            "the INA228's voltage reading to current. Common values: 15mΩ (15000uΩ) "
            "for typical battery packs. Using the wrong value will cause incorrect "
            "current and capacity readings."
        ),
        "unit": "mΩ",
        "unit_hint": "mΩ",
        "kind": "module",
        "default": 15000,
    },
    "ina228_max_current_ua": {
        "desc": "INA228 max current range",
        "detail": (
            "The maximum current range (in microamps) that the INA228 sensor is "
            "configured to measure. This affects the resolution and range of current "
            "measurements. Common values: 6400000uA (6.4A) for typical use. "
            "Higher values allow measuring larger currents but reduce resolution."
        ),
        "unit": "mA",
        "unit_hint": "mA",
        "kind": "module",
        "default": 6400000,
    },
    "discharge_current_ua": {
        "desc": "Assumed average discharge current (time-to-empty only)",
        "detail": (
            "The assumed average discharge current used to estimate time-to-empty "
            "when the system is not drawing a predictable load. This is a "
            "fallback estimate and is less accurate than actual current measurements. "
            "Value should be in microamps (e.g., 900000 = 900mA = 0.9A)."
        ),
        "unit": "mA",
        "unit_hint": "mA",
        "kind": "module",
        "default": 900000,
    },
    "batt_ir_mohm": {
        "desc": "Pack internal resistance (charge-time OCV estimate only)",
        "detail": (
            "The internal resistance of the battery pack (in milli-ohms). This value "
            "is used during charging to estimate the open-circuit voltage (OCV) by "
            "compensating for voltage drop across the internal resistance. Typical "
            "values: 100-200mΩ for most Li-ion packs. An inaccurate value can "
            "cause incorrect state-of-charge estimates during charging."
        ),
        "unit": "mΩ",
        "unit_hint": "mΩ",
        "kind": "module",
        "default": 180,
    },
    "discharge_avg_ua": {
        "desc": "Nominal idle discharge current (0 disables)",
        "detail": (
            "The nominal discharge current when the system is idle, used by the "
            "state-of-charge integrator to estimate battery drain. Setting to 0 "
            "disables this feature. This helps maintain accurate SOC estimates "
            "when the system is sleeping or in low-power states. "
            "Value in microamps (e.g., 700000 = 700mA)."
        ),
        "unit": "mA",
        "unit_hint": "mA",
        "kind": "module",
        "default": 700000,
    },
    "discharge_load_factor_pct": {
        "desc": "Extra %% added to discharge proxy under sustained load",
        "detail": (
            "A percentage multiplier applied to the discharge current estimate "
            "when the system is under sustained load. This helps account for "
            "additional battery drain that might not be captured by instant "
            "measurements. For example, a value of 40 means 40%% extra current "
            "is added to the estimate under load. Range: 0-100."
        ),
        "unit": "%",
        "unit_hint": "%",
        "kind": "module",
        "default": 40,
    },
    "discharge_max_ua": {
        "desc": "Hard ceiling for SOC integrator proxy current",
        "detail": (
            "The maximum discharge current value (in microamps) that the "
            "state-of-charge integrator will use as a proxy. This prevents "
            "unrealistic SOC calculations during very high current draws. "
            "Value in microamps (e.g., 2200000 = 2.2A). The PocketCM5 "
            "default is 2.2 A."
        ),
        "unit": "mA",
        "unit_hint": "mA",
        "kind": "module",
        "default": 4000000,
    },
    "rest_min_sec": {
        "desc": "Seconds of quiet required to enter DISCHARGING_RESTING",
        "detail": (
            "The number of seconds of low/no current draw required before the "
            "battery driver considers the system to be in a 'resting' state. "
            "During rest, more accurate open-circuit voltage measurements can "
            "be taken. Longer times provide better accuracy but delay the "
            "transition to resting state. PocketCM5 default: 300 (5 minutes)."
        ),
        "unit": "s",
        "unit_hint": "s",
        "kind": "module",
        "default": 300,
    },
    "low_v_persistent_count": {
        "desc": "Consecutive low-voltage samples before SOC drops to critical",
        "detail": (
            "The number of consecutive low-voltage readings required before "
            "the state-of-charge is dropped to 'critical' level. This "
            "debouncing prevents transient voltage dips from immediately "
            "triggering critical state. A higher value provides more "
            "stability but delays critical warnings. Range: 1-20."
        ),
        "unit": "samples",
        "unit_hint": "samples",
        "kind": "module",
        "default": 5,
    },
    "ina228_shunt_tcr_ppm": {
        "desc": "INA228 shunt resistor TCR (ppm/°C) for temperature compensation",
        "detail": (
            "Temperature Coefficient of Resistance for the shunt resistor. "
            "Used to compensate for shunt resistance drift with temperature. "
            "Typical values: 50 ppm/°C for precision metal foil, 100 ppm/°C for "
            "standard SMD sense resistors, 200 ppm/°C for low-cost thick film. "
            "The driver applies automatic correction when temperature differs from "
            "calibration. Default: 100 ppm/°C. Set to 0 to disable compensation."
        ),
        "unit": "ppm/°C",
        "unit_hint": "ppm",
        "kind": "module",
        "default": 100,
    },
    "ina228_filter_alpha": {
        "desc": "INA228 EMA filter alpha (0-1000)",
        "detail": (
            "Exponential Moving Average filter coefficient for INA228 current readings. "
            "Controls smoothing of current measurements. "
            "Value is α × 1000: 250=balanced (default), 100=very smooth, "
            "500=responsive, 1000=no filtering (raw ADC). "
            "Lower values reduce noise but slow response to current changes. "
            "Recommended: 250 for general use, 100 for long-term accuracy."
        ),
        "unit": "α×1000",
        "unit_hint": "0-1000",
        "kind": "module",
        "default": 250,
    },
    "coulomb_uah": {
        "desc": "Remaining capacity (coulomb counter; fuel gauge overwrites)",
        "detail": (
            "WARNING: This is a LIVE fuel-gauge value that is OVERWRITTEN by "
            "the driver's fuel gauge integration within seconds of any change. "
            "Treat writes as momentary biases only. "
            "Setting this to the battery's full capacity after a full charge "
            "can help recalibrate the fuel gauge. The value represents remaining "
            "charge in microamp-hours (uAh)."
        ),
        "unit": "mAh",
        "unit_hint": "mAh",
        "kind": "live",
        "default": None,
    },
}

UNIT_SCALES = {
    "uAh": 1,       "mAh": 1_000,      "Ah":  1_000_000,
    "uA":  1,       "mA":  1_000,      "A":   1_000_000,
    "uV":  1,       "mV":  1_000,      "V":   1_000_000,
    "uΩ":  1,       "mΩ":  1_000,      "Ω":   1_000_000,
    "mW":  1,
}

INTERNAL_SCALES = {  # for sysfs writing
    "uAh": 1,       "mAh": 1_000,      "Ah":  1_000_000,
    "uA":  1,       "mA":  1_000,      "A":   1_000_000,
    "uV":  1,       "mV":  1_000,      "V":   1_000_000,
    "uΩ":  1,       "mΩ":  1_000,      "Ω":   1_000_000,
}


def read_param(name):
    path = sysfs_path(name)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return f.read().strip()
    except PermissionError:
        return None


def write_param(name, value):
    path = sysfs_path(name)
    rounded = int(round(value))
    with open(path, "w") as f:
        f.write(f"{rounded}\n")
    return rounded


def probe_writable(name):
    """Return (ok, info) where info is a human-readable diagnostic.

    ok=True:  we expect writes to succeed.
    ok=False: writes will likely fail with EACCES or EBUSY; info explains why.
    """
    path = sysfs_path(name)
    if not os.path.exists(path):
        return False, f"path does not exist: {path} (is the driver loaded?)"
    try:
        st = os.stat(path)
    except OSError as e:
        return False, f"cannot stat {path}: {e}"
    # Decode POSIX mode bits.
    mode = st.st_mode & 0o777
    mode_str = oct(mode)
    uid_writable = (mode & 0o200) != 0
    if uid_writable:
        return True, f"mode={mode_str}, writable by owner"
    # Mode does not allow writes. Detect whether running as root and distinguish:
    is_root = (os.geteuid() == 0)
    if is_root:
        # Root can normally open anything, but kernel sysfs nodes can override.
        return False, (
            f"mode={mode_str} but the kernel is still rejecting writes (EACCES).\n"
            f"  This typically happens when the driver registers a sysfs file as\n"
            f"  'writable' in DEVICE_ATTR but the surrounding power_supply class\n"
            f"  marks the property as not writeable via property_is_writeable().\n"
            f"  Fix in the driver: either declare the property writeable in\n"
            f"  bq25890_power_supply_property_is_writeable(), or move the\n"
            f"  attribute out of the power_supply child device group."
        )
    return False, (
        f"mode={mode_str}, not writable by uid {os.geteuid()}.\n"
        f"  Re-run with sudo, or fix the file's owner/permissions."
    )


MODPROBE_CONF = "/etc/modprobe.d/pibrick-battery.conf"


def persist_available():
    """True iff we can write to /etc/modprobe.d (i.e., root + parent dir exists)."""
    return os.geteuid() == 0 and os.path.isdir(os.path.dirname(MODPROBE_CONF))


def persist_to_modprobe_d(name, value):
    """Update the value of `name` in MODPROBE_CONF.

    Reads the file, removes any prior `name=value` pair (whether on its
    own options line or co-located with other pairs), then merges the new
    value into the LAST remaining `options bq25890_battery` line — or
    appends a fresh options line if none exists. Comments, blank lines,
    and unrelated `options` lines for other modules are preserved.

    Merging rather than appending is important for two reasons:
      1. modprobe.d treats multiple `options MODNAME ...` lines as
         independent command-line overrides: each is applied to the
         kernel as the entire parameter set, with later lines winning
         wholesale over earlier ones.  A two-line file like:
             options bq25890_battery A=1 B=2
             options bq25890_battery charge_full_uah=4800000
         causes the kernel to load bq25890_battery with ONLY
         charge_full_uah=4800000, dropping A and B back to defaults.
      2. Our boot-time applier (pibrick-battery-apply-modprobe.service)
         applies "last wins" semantics to mirror modprobe's behaviour,
         which makes a single-line conf much easier to reason about.

    Net effect after persist: at most ONE `options bq25890_battery ...`
    line in the file, with all persisted params side by side.
    """
    new_pair = f"{name}={value}"
    new_line = f"options bq25890_battery {new_pair}"

    if os.path.exists(MODPROBE_CONF):
        with open(MODPROBE_CONF) as f:
            existing = f.read()
        trailing_nl = existing.endswith("\n")
    else:
        existing = ""
        trailing_nl = True

    lines = existing.split("\n")
    if trailing_nl and lines and lines[-1] == "":
        lines.pop()

    # Strip any "name=value" pair that matches our parameter from each
    # `options bq25890_battery ...` line, and remember the LAST such line
    # so we can merge our new pair into it instead of appending a new line.
    last_battery_idx = -1
    kept = []
    for ln in lines:
        stripped = ln.strip()
        if not stripped:
            kept.append(ln)
            continue

        if not (stripped.startswith("options bq25890_battery") or
                stripped.startswith("# options bq25890_battery")):
            kept.append(ln)
            continue

        tokens = stripped.split()
        if len(tokens) < 2 or tokens[0] != "options":
            kept.append(ln)
            continue
        is_commented = ln.lstrip().startswith("#")
        prefix = "# " if is_commented else ""
        head = tokens[:2]
        body = []
        for tok in tokens[2:]:
            if "=" in tok and tok.split("=", 1)[0] == name:
                continue
            body.append(tok)
        if body:
            kept.append(f"{prefix}{head[0]} {head[1]} " + " ".join(body))
            last_battery_idx = len(kept) - 1
        # else: this line is now empty, drop it entirely.

    if last_battery_idx >= 0:
        # Merge our new pair into the trailing battery options line.
        existing_line = kept[last_battery_idx]
        sep = "" if existing_line.endswith(" ") or new_pair.startswith(" ") else " "
        kept[last_battery_idx] = existing_line + sep + new_pair
    else:
        # No existing battery options line — add a fresh one.
        kept.append(new_line)

    body = "\n".join(kept) + "\n"
    tmp = MODPROBE_CONF + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, MODPROBE_CONF)
    print(f"  -> Persisted to {MODPROBE_CONF}:")
    print(f"       {new_pair}")


def save_soc_persist():
    """Save current SOC to persistent storage for consistency across reboots.

    This is called after coulomb_uah calibration to ensure the SOC
    remains consistent after reboot.
    """
    import subprocess

    # Try the Python script first. Look in any of the candidate install
    # locations (per-user or system-wide) so the user does not need to
    # reconfigure after running install.sh.
    candidates = []
    if os.environ.get("PIBRICK_USER_HOME"):
        candidates.append(os.environ["PIBRICK_USER_HOME"])
    if os.environ.get("HOME"):
        candidates.append(os.path.join(os.environ["HOME"], "battery-tools"))
    candidates.append("/usr/lib/pibrick/battery-tools")

    for tools_dir in candidates:
        script_path = os.path.join(tools_dir, "battery-soc-persist.py")
        if os.path.exists(script_path):
            try:
                result = subprocess.run(
                    ["python3", script_path],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0:
                    return True
            except Exception:
                pass

    # Fallback: directly write to the persistence file
    persist_file = "/var/lib/bq25890_battery/soc_persist"
    capacity_path = "/sys/class/power_supply/battery/capacity"

    try:
        # Read current SOC
        with open(capacity_path, "r") as f:
            soc = int(f.read().strip())

        # Ensure directory exists
        os.makedirs(os.path.dirname(persist_file), exist_ok=True)

        # Write to file
        with open(persist_file, "w") as f:
            f.write(f"soc={soc}\n")

        return True
    except Exception:
        return False


def reload_driver(name=None):
    """Reload the bq25890_battery driver to apply modprobe.d settings.

    This performs: modprobe -r bq25890_battery && modprobe bq25890_battery
    The driver will be loaded with parameters from /etc/modprobe.d/pibrick-battery.conf
    if that file exists.
    """
    MODULE_NAME = "bq25890_battery"

    print()
    print(f"{bold('=')*60}")
    print(f"  Reloading driver to apply persisted settings")
    print(f"{'='*60}")

    # Step 1: Unload the driver
    print(f"\n  Step 1: Unloading {MODULE_NAME}...")
    try:
        result = subprocess.run(
            ["modprobe", "-r", MODULE_NAME],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            # Try alternative removal method
            print(f"    modprobe -r failed, trying rmmod...")
            result = subprocess.run(
                ["rmmod", MODULE_NAME],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                print(f"    {warn('Warning:')} Could not unload driver:")
                print(f"      {result.stderr.strip() if result.stderr else 'Unknown error'}")
                print(f"    Settings will still be saved and applied on next reboot.")
                return False
        print(f"    {success('OK')} - Driver unloaded")
    except subprocess.TimeoutExpired:
        print(f"    {warn('Warning:')} Driver unload timed out. Settings saved but will apply on reboot.")
        return False
    except FileNotFoundError:
        print(f"    {warn('Warning:')} modprobe/rmmod not found. Settings saved but will apply on reboot.")
        return False

    # Small delay to ensure module is fully unloaded
    print(f"\n  Step 2: Waiting for module cleanup...")
    import time
    time.sleep(0.5)

    # Step 3: Reload the driver (will pick up modprobe.d settings)
    print(f"\n  Step 3: Loading {MODULE_NAME} with modprobe.d settings...")
    try:
        result = subprocess.run(
            ["modprobe", MODULE_NAME],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            print(f"    {error('Error:')} Failed to load driver:")
            print(f"      {result.stderr.strip() if result.stderr else 'Unknown error'}")
            return False
        print(f"    {success('OK')} - Driver loaded with persisted settings")
    except subprocess.TimeoutExpired:
        print(f"    {error('Error:')} Driver load timed out.")
        return False
    except FileNotFoundError:
        print(f"    {error('Error:')} modprobe not found.")
        return False

    # Small delay for driver to initialize
    time.sleep(0.5)

    # Step 4: Verify the new value
    print(f"\n  Step 4: Verifying applied value...")
    new_val = read_param(name) if name else None
    if new_val:
        print(f"    {name} = {new_val}")

    print()
    print(f"{success('=')*60}")
    print(f"  Driver reloaded successfully!")
    print(f"  Settings will persist across future reboots.")
    print(f"{'='*60}")
    print()
    return True


def kind_label(kind):
    if kind == "module":
        return info("MODULE")
    if kind == "live":
        return warn("LIVE")
    return "sysfs"


def kind_description(kind):
    """Return a detailed description of what this kind means."""
    if kind == "module":
        return (
            f"{bold('MODULE PARAMETER')}: Written to kernel module parameters.\n"
            f"  - Change takes effect IMMEDIATELY\n"
            f"  - Will RESET to driver defaults on driver reload or reboot\n"
            f"  - {success('To persist:')} Use --persist flag or configure modprobe.d"
        )
    if kind == "live":
        return (
            f"{warn('LIVE VALUE')}: Fuel gauge continuously updates this.\n"
            f"  - Change takes effect but is OVERWRITTEN within seconds\n"
            f"  - Cannot be persisted - only a momentary bias\n"
            f"  - Use case: calibrate fuel gauge after full charge"
        )
    return (
        f"{bold('SYSFS')}: Standard sysfs parameter.\n"
        f"  - Change takes effect IMMEDIATELY\n"
        f"  - Will RESET on reboot\n"
        f"  - To persist: save to startup script"
    )


# Below this fraction of charge_full_uah, a write to coulomb_uah is considered
# dangerous: it forces capacity_level=CRITICAL and UPower / KDE may shut the
# device down within seconds. Refuse such writes unless --force is given.
COULOMB_SAFETY_FLOOR_PCT = 10


def check_coulomb_safety(value, force=False):
    """Return (ok, message). ok=False means we should refuse the write.

    Below COULOMB_SAFETY_FLOOR_PCT, a write to coulomb_uah forces
    capacity_level=CRITICAL and UPower / KDE may shut the device down
    within seconds. Refuse such writes unless --force is given.
    """
    full_raw = read_param("charge_full_uah")
    if full_raw is None:
        return True, None  # can't verify, don't block
    try:
        full_uah = int(full_raw)
    except ValueError:
        return True, None
    if full_uah <= 0:
        return True, None
    pct = 100.0 * value / full_uah
    if pct >= COULOMB_SAFETY_FLOOR_PCT:
        # Value is safely above the critical floor; proceed.
        return True, None

    # Value is BELOW the safety floor: refuse unless force.
    msg = (
        f"Refusing to set coulomb_uah to {int(round(value))} uAh "
        f"({pct:.1f}% of charge_full_uah={full_uah}).\n"
        f"  At <{COULOMB_SAFETY_FLOOR_PCT}% capacity the kernel reports "
        f"capacity_level=CRITICAL, and UPower / KDE typically initiate a\n"
        f"  graceful shutdown within a few seconds (this is what happened in "
        f"the field).\n"
        f"  Use --force if you really mean it, or set coulomb_uah to "
        f"charge_full_uah\n"
        f"  right after a confirmed full charge."
    )
    return (False, msg) if not force else (True, msg)


def parse_value(value_str, unit_hint):
    # Try splitting unit from numeric part
    for unit in sorted(INTERNAL_SCALES.keys(), key=len, reverse=True):
        if value_str.lower().endswith(unit.lower()):
            num_str = value_str[:-len(unit)].strip()
            return float(num_str) * INTERNAL_SCALES[unit]
    # No unit given — use hint
    scale = INTERNAL_SCALES.get(unit_hint, 1)
    return float(value_str) * scale


def fmt_readable(name, raw_val):
    p = PARAMS[name]
    unit = p["unit"]
    if raw_val is None:
        return "(not available)", "(not available)"
    try:
        raw = int(raw_val)
    except ValueError:
        return raw_val, raw_val
    scale = INTERNAL_SCALES.get(unit, 1)
    display = raw / scale
    if scale >= 1_000_000:
        return f"{display:.3f} {unit}", str(raw)
    elif scale >= 1_000:
        return f"{display:.1f} {unit}", str(raw)
    return f"{display} {unit}", str(raw)


def interactive():
    print(f"\n{bold('='*60)}")
    print(f"  {bold('piBrick Battery Parameter Setter')}")
    print(f"{'='*60}\n")
    print(f"  This tool modifies battery driver parameters in real-time.")
    print(f"  Use --list-verbose for extended parameter explanations.")
    print()

    # Show current values first
    print(f"\n{bold('Current Values')}:\n")
    header = f"  {'Parameter':<30}  {'Current':<15}  {'Type':<10}"
    print(header)
    print(f"  {COLOR_DIM}{'-'*30}  {'-'*15}  {'-'*10}{COLOR_RESET}")
    for name, p in PARAMS.items():
        path = sysfs_path(name)
        val_str, _ = fmt_readable(name, read_param(name))
        kind_str = "MODULE" if p['kind'] == "module" else ("LIVE" if p['kind'] == "live" else "SYSFS")
        print(f"  {name:<30}  {val_str:<15}  {kind_str:<10}")
    print()

    print(f"{bold('Parameter Selection')}:")
    print(f"  Choose a parameter to modify, or use these shortcuts:\n")
    print(f"    {bold('--list')}        Show all parameters with basic info")
    print(f"    {bold('--list-verbose')} Show all parameters with detailed explanations")
    print()
    for i, name in enumerate(PARAMS, 1):
        print(f"    {i}) {name}")
    print(f"    0) Quit")
    print()

    while True:
        try:
            choice = input(f"{bold('Enter number')}: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

        if choice == "0":
            print("Goodbye!")
            return
        try:
            idx = int(choice) - 1
            name = list(PARAMS.keys())[idx]
            break
        except (ValueError, IndexError):
            print(warn(f"Invalid choice. Enter a number from 1-{len(PARAMS)}."))

    p = PARAMS[name]
    unit = p["unit"]
    unit_hint = p["unit_hint"]

    # Display detailed parameter info
    print(f"\n{bold('=')*60}")
    print(f"  Parameter: {bold(name)}")
    print(f"{'='*60}")
    print(f"\n  {bold('Description')}:")
    print(f"    {p['desc']}")
    print(f"\n  {bold('Detailed Explanation')}:")
    # Word wrap the detail text
    detail_lines = p.get("detail", "No detailed explanation available.").split(". ")
    for line in detail_lines:
        if line:
            print(f"    {line.strip()}{'.' if not line.endswith('.') else ''}")
    print(f"\n  {bold('Current Value')}: {info(read_param(name) or '(not available)')}")
    print(f"  {bold('Unit')}: {unit}")
    print(f"  {bold('Driver Default')}: {p.get('default', 'N/A')}")
    print(f"  {bold('Storage Location')}: {sysfs_path(name)}")
    print()

    # Show persistence warning based on kind
    if p["kind"] == "module":
        print(f"\n  {warn('=')*40}")
        print(f"  {warn('PERSISTENCE WARNING')}")
        print(f"{'='*40}")
        print(f"  This is a {bold('MODULE PARAMETER')}:")
        print(f"    - Change takes effect IMMEDIATELY")
        print(f"    - Will RESET to driver defaults on:")
        print(f"        * Driver reload (modprobe -r && modprobe)")
        print(f"        * System reboot")
        print(f"\n  {success('To persist this change across reboots:')}")
        print(f"    Run: {bold('python3 battery_set.py <param> <value> --persist')}")
        print(f"    Or manually: echo 'options bq25890_battery {name}=<value>' | sudo tee /etc/modprobe.d/pibrick-battery.conf")
        print()
    elif p["kind"] == "live":
        print(f"\n  {warn('=')*40}")
        print(f"  {warn('LIVE VALUE WARNING')}")
        print(f"{'='*40}")
        print(f"  This is a {warn('LIVE fuel-gauge value')}:")
        print(f"    - Any change will be OVERWRITTEN by the fuel gauge")
        print(f"    - Overwrite happens within SECONDS of writing")
        print(f"    - Cannot be persisted - this is a momentary bias only")
        print(f"\n  {info('Legitimate use cases:')}")
        print(f"    - Calibrate fuel gauge after a full charge cycle")
        print(f"    - Force recalculation at known battery state")
        print()
        if name == "coulomb_uah":
            print(f"  {error('=')*40}")
            print(f"  {error('DANGER - coulomb_uah')}")
            print(f"{'='*40}")
            print(f"  Writing a small value here will force capacity_level=CRITICAL.")
            print(f"  {error('UPower / KDE will initiate immediate shutdown!')}")
            print(f"  Script refuses writes below {COULOMB_SAFETY_FLOOR_PCT}% of charge_full_uah")
            print(f"  unless you explicitly override with --force.")
            print()

    while True:
        try:
            val_input = input(f"\n{bold('New value')} (in {unit_hint}, e.g. '100 {unit_hint}' or just '100'): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            return

        if not val_input:
            print("No value entered.")
            continue

        try:
            value = parse_value(val_input, unit_hint)
        except ValueError:
            print(warn(f"Invalid number: '{val_input}'. Try again."))
            continue

        if value < 0:
            print(warn("Value cannot be negative."))
            continue

        # Check coulomb safety for dangerous values
        if name == "coulomb_uah":
            ok, msg = check_coulomb_safety(value, force=False)
            if not ok:
                print(f"\n{error('=')*40}")
                print(f"{error('SAFETY CHECK FAILED')}")
                print(f"{'='*40}")
                print(msg)
                print()
                try:
                    confirm = input(f"{warn('Type \"yes\" to override and write anyway:')} ").strip()
                except (EOFError, KeyboardInterrupt):
                    print("\nAborted.")
                    return
                if confirm != "yes":
                    print("Aborted. (Re-run with --force in non-interactive mode.)")
                    return
                print(success("Override accepted, proceeding."))

        # Pre-flight write check
        write_ok, write_info = probe_writable(name)
        if not write_ok:
            print(f"\n{error('=')*40}")
            print(f"{error('WRITE PRE-CHECK FAILED')}")
            print(f"{'='*40}")
            print(f"  {write_info}")
            if not (name == "coulomb_uah" and confirm == "yes"):
                print("\nSkipping write.")
                return

        print(f"\n  Setting {bold(name)} = {int(round(value))} ({val_input})")
        try:
            written = write_param(name, value)
            print(f"  {success('Written:')} {written} to {sysfs_path(name)}")
        except PermissionError:
            print(f"\n  {error('ERROR:')} Write was rejected with EACCES.")
            _, info_text = probe_writable(name)
            print(f"     {info_text}")
            return
        except FileNotFoundError:
            print(f"\n  {error('ERROR:')} Path not found. Is the driver loaded?")
            return
        except Exception as e:
            print(f"\n  {error('ERROR:')} {e}")
            return

        # Verify write and show persistence guidance
        new_val = read_param(name)
        print(f"  {success('Verified:')} {sysfs_path(name)} now reads {new_val}")

        if p["kind"] == "module":
            print(f"\n  {warn('=')*40}")
            print(f"  {warn('PERSISTENCE SETUP')}")
            print(f"{'='*40}")
            print(f"  This change is LIVE but will RESET on reboot!")
            print()
            print(f"  {success('Option A:')} Auto-reload driver now (RECOMMENDED)")
            print(f"           Persists immediately without reboot")
            print()
            print(f"  {info('Option B:')} Save to modprobe.d for next reboot")
            print(f"           Applies on next driver load (reboot)")
            print()
            try:
                choice = input(f"  Choose [{bold('A')}/{bold('B')}/N (default=N=skip)]: ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print()
                choice = ""
            if choice == "a":
                # Persist and reload
                try:
                    persist_to_modprobe_d(name, written)
                    reload_driver(name)
                except PermissionError:
                    print(f"  Cannot write {MODPROBE_CONF} without sudo; skipping.")
            elif choice == "b":
                # Persist only (no reload)
                try:
                    persist_to_modprobe_d(name, written)
                    print(f"\n  {info('Saved!')} Settings will apply on next reboot.")
                except PermissionError:
                    print(f"  Cannot write {MODPROBE_CONF} without sudo; skipping.")
        elif p["kind"] == "live":
            print(f"\n  {info('Note:')} This value will change again within seconds as the")
            print(f"         fuel gauge continues integrating from the INA228 sensor.")

        # Save SOC for consistency after reboot if coulomb_uah was calibrated
        if name == "coulomb_uah":
            print(f"\n  {info('Saving SOC for consistency after reboot...')}")
            if save_soc_persist():
                print(f"  {success('SOC saved successfully')}")
            else:
                print(f"  {warn('Could not save SOC (non-critical)')}")

        print()
        return


def noninteractive(name, value_str, persist=False, force=False):
    if name not in PARAMS:
        print(f"{error('Unknown parameter:')} {name}")
        print(f"Use {bold('python3 battery_set.py --list')} to see available parameters.")
        sys.exit(1)

    p = PARAMS[name]
    unit = p["unit"]
    unit_hint = p["unit_hint"]

    # Explain live values upfront
    if p["kind"] == "live":
        print(f"\n{warn('=')*60}")
        print(f"  {warn('NOTICE: Live Fuel-Gauge Value')}")
        print(f"{'='*60}")
        print(f"  {bold(name)} is a {warn('live fuel-gauge value')}.")
        print(f"  The driver will OVERWRITE your write within seconds.")
        print(f"  --persist has NO effect for live values.")
        print(f"  Treat this as a momentary bias only.")
        print()

    try:
        value = parse_value(value_str, unit_hint)
    except ValueError:
        print(f"{error('Invalid value:')} '{value_str}'")
        sys.exit(1)

    if value < 0:
        print(f"{error('Value cannot be negative.')}")
        sys.exit(1)

    # Safety check for coulomb_uah
    if name == "coulomb_uah":
        ok, msg = check_coulomb_safety(value, force=force)
        if not ok:
            print(msg)
            print(f"{error('Refusing to write.')} Re-run with {bold('--force')} to override.")
            sys.exit(3)
        if msg and force:
            print(msg)
            print(f"{warn('--force given, proceeding anyway.')}")

    # Pre-flight write check
    write_ok, write_info = probe_writable(name)
    if not write_ok:
        print(f"\n{error('Pre-flight check FAILED:')}")
        print(f"  {write_info}")
        if not force:
            print(f"\n{error('Write aborted.')} Re-run with {bold('--force')} to attempt anyway.")
            sys.exit(4)
        print(f"{warn('--force given, attempting write anyway.')}")

    written = int(round(value))

    # Display what we're doing
    print(f"\n{bold('=')*60}")
    print(f"  Setting {bold(name)}")
    print(f"{'='*60}")
    print(f"  Value:    {written} {unit} ({value_str})")
    print(f"  Type:     {kind_label(p['kind'])}")
    print(f"  Path:     {sysfs_path(name)}")
    print()

    # Persistence warning for module params
    if p["kind"] == "module":
        print(f"{warn('PERSISTENCE WARNING:')}")
        print(f"  This change takes effect IMMEDIATELY.")
        print(f"  However, it will RESET to driver defaults on:")
        print(f"    * Driver reload (sudo modprobe -r bq25890_battery && modprobe bq25890_battery)")
        print(f"    * System reboot")
        print()
        print(f"  {success('To persist this change, use --persist flag:')}")
        print(f"    sudo python3 battery_set.py {name} {value_str} {bold('--persist')}")
        print()

    try:
        write_param(name, value)
        verified = read_param(name)
        print(f"  {success('SUCCESS:')} {sysfs_path(name)} now reads {verified}")
    except PermissionError:
        print(f"\n  {error('ERROR:')} Write rejected with EACCES (permission denied).")
        print(f"  {error('Run with sudo.')}")
        sys.exit(5)
    except FileNotFoundError:
        print(f"\n  {error('ERROR:')} Path not found. Is the driver loaded?")
        sys.exit(1)
    except Exception as e:
        print(f"\n  {error('ERROR:')} {e}")
        sys.exit(1)

    # Auto-persist if requested
    if persist and p["kind"] == "module":
        try:
            persist_to_modprobe_d(name, written)
            # Automatically reload driver to apply settings
            reload_driver(name)
        except PermissionError:
            print(f"\n  {error('ERROR:')} Cannot write {MODPROBE_CONF} without sudo.")
            sys.exit(1)
    elif persist and p["kind"] == "live":
        print(f"\n  {info('Note:')} --persist was requested but has no effect on live values.")

    # Save SOC for consistency after reboot if coulomb_uah was calibrated
    if name == "coulomb_uah":
        print(f"\n  {info('Saving SOC for consistency after reboot...')}")
        if save_soc_persist():
            print(f"  {success('SOC saved successfully')}")
        else:
            print(f"  {warn('Could not save SOC (non-critical)')}")


def show_all():
    print(f"\n{bold('=')*60}")
    print(f"  Current Values")
    print(f"{'='*60}\n")
    header = f"  {'Parameter':<30}  {'Current':<15}  {'Type':<10}  {'Persists?':<12}"
    print(bold(header))
    print(f"  {COLOR_DIM}{'-'*30}  {'-'*15}  {'-'*10}  {'-'*12}{COLOR_RESET}")
    for name, p in PARAMS.items():
        val_str, _ = fmt_readable(name, read_param(name))
        kind_str = "MODULE" if p['kind'] == "module" else ("LIVE" if p['kind'] == "live" else "SYSFS")
        persist_str = "No" if p['kind'] in ("module", "live") else "No"
        if p['kind'] == "module":
            persist_str = f"{info('No')}, use --persist"
        elif p['kind'] == "live":
            persist_str = f"{warn('No')}, overwritten"
        print(f"  {name:<30}  {val_str:<15}  {kind_str:<10}  {persist_str:<12}")
    print()


def list_params(verbose=False):
    print(f"\n{bold('=')*60}")
    print(f"  {bold('Available Parameters')}")
    print(f"{'='*60}")
    print()
    for name, p in PARAMS.items():
        cur, raw = fmt_readable(name, read_param(name))
        kind_str = "MODULE" if p['kind'] == "module" else ("LIVE" if p['kind'] == "live" else "SYSFS")

        print(f"  {bold(name)} [{kind_label(p['kind'])}]")
        print(f"    {p['desc']}")

        if verbose:
            print(f"\n    {bold('Detailed Explanation')}:")
            detail = p.get("detail", "No detailed explanation available.")
            # Word wrap detail text
            words = detail.split()
            line = "      "
            for word in words:
                if len(line) + len(word) > 70:
                    print(line)
                    line = "      " + word + " "
                else:
                    line += word + " "
            if line.strip():
                print(line)

        print(f"    {bold('Current')}: {info(cur)}")
        if p.get("default") is not None:
            print(f"    {bold('Driver Default')}: {p['default']}")

        # Persistence status
        if p['kind'] == "module":
            print(f"    {warn('Persistence')}: No (resets on reboot)")
            print(f"    {success('Solution')}: Use --persist flag")
        elif p['kind'] == "live":
            print(f"    {warn('Persistence')}: Cannot be persisted")
            print(f"    {info('Reason')}: Fuel gauge overwrites within seconds")
        else:
            print(f"    {warn('Persistence')}: No (resets on reboot)")
        print()


def main():
    parser = argparse.ArgumentParser(
        description="piBrick battery parameter setter - configure battery driver parameters",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
PERSISTENCE EXPLANATION:
    Module parameters are stored in kernel memory and reset to driver defaults
    whenever the driver is reloaded (modprobe -r) or the system reboots.

    To make changes persistent, use one of these methods:

    1. Use --persist flag (RECOMMENDED):
        sudo python3 battery_set.py <param> <value> --persist
        This saves to modprobe.d AND automatically reloads the driver.

    2. Manual modprobe.d configuration:
        echo 'options bq25890_battery <param>=<value>' | sudo tee /etc/modprobe.d/pibrick-battery.conf
        Then reload manually: sudo modprobe -r bq25890_battery && sudo modprobe bq25890_battery

EXAMPLES:
    List all parameters:
        sudo python3 battery_set.py --list

    Show detailed parameter info:
        sudo python3 battery_set.py --list-verbose

    Show current values:
        sudo python3 battery_set.py --show

    Read a specific parameter:
        sudo python3 battery_set.py charge_full_uah

    Set a value (non-persistent):
        sudo python3 battery_set.py charge_full_uah 5000000

    Set a value with persistence:
        sudo python3 battery_set.py charge_full_uah 5000000 --persist

    Force dangerous coulomb_uah write:
        sudo python3 battery_set.py coulomb_uah 4500000 --force
"""
    )
    parser.add_argument("param", nargs="?", help="Parameter name")
    parser.add_argument("value", nargs="?", help="New value")
    parser.add_argument("--list", action="store_true",
                       help="List all parameters with basic info")
    parser.add_argument("--list-verbose", action="store_true",
                       help="List all parameters with detailed explanations")
    parser.add_argument("--show", action="store_true",
                       help="Show current values of all parameters")
    parser.add_argument(
        "--persist",
        action="store_true",
        help=f"Save to {MODPROBE_CONF} AND automatically reload the driver "
             "so the value takes effect immediately and survives future reboots. "
             "Only works for module parameters. Live values (coulomb_uah) cannot be persisted.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help=f"Bypass the coulomb_uah safety floor. Refuses writes that would "
             f"drop capacity below {COULOMB_SAFETY_FLOOR_PCT}%% of charge_full_uah, "
             "as this triggers immediate userspace shutdown. DANGEROUS.",
    )
    args = parser.parse_args()

    # Show usage summary if no args
    if len(sys.argv) == 1:
        print(f"\n{bold('piBrick Battery Parameter Setter')}")
        print(f"\nUsage: sudo python3 battery_set.py [command]")
        print(f"\nQuick commands:")
        print(f"  {bold('--list')}           List all parameters")
        print(f"  {bold('--list-verbose')}   List with detailed explanations")
        print(f"  {bold('--show')}           Show current values")
        print(f"  {bold('<param>')}           Read current value")
        print(f"  {bold('<param> <value>')}  Set value")
        print(f"\nFor help: sudo python3 battery_set.py --help")
        print()
        return

    if args.list_verbose:
        list_params(verbose=True)
        return

    if args.list:
        list_params(verbose=False)
        return

    if args.show:
        show_all()
        return

    if args.param is None:
        if os.isatty(sys.stdin.fileno()):
            interactive()
        else:
            print(f"{error('Error:')} No TTY detected. Use non-interactive mode:")
            print(f"  sudo python3 battery_set.py --show          # Show all values")
            print(f"  sudo python3 battery_set.py --list          # List parameters")
            print(f"  sudo python3 battery_set.py <param>         # Read one value")
            print(f"  sudo python3 battery_set.py <param> <value> # Set a value")
            print(f"  sudo python3 battery_set.py <param> <value> --persist # Set with persistence")
            sys.exit(1)
        return

    if args.value is None:
        # Just reading the parameter
        if args.param in PARAMS:
            val = read_param(args.param)
            val_display, _ = fmt_readable(args.param, val)
            p = PARAMS[args.param]
            print(f"\n{bold('Parameter:')} {args.param}")
            print(f"{bold('Value:')} {info(val_display)}")
            print(f"{bold('Type:')} {kind_label(p['kind'])}")
            print(f"{bold('Description:')} {p['desc']}")

            # Persistence reminder
            if p['kind'] == "module":
                print(f"\n{warn('Note:')} This is a module parameter. Changes reset on reboot.")
                print(f"{success('To persist:')} Use --persist flag")
            elif p['kind'] == "live":
                print(f"\n{warn('Note:')} This is a live value, overwritten by fuel gauge within seconds.")
            print()
        else:
            print(f"{error('Unknown parameter:')} {args.param}")
            print(f"Use {bold('--list')} to see available parameters.")
            sys.exit(1)
        return

    noninteractive(args.param, args.value, persist=args.persist, force=args.force)


if __name__ == "__main__":
    main()
