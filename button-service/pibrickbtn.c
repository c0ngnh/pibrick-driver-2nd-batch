#include <errno.h>
#include <fcntl.h>
#include <gpiod.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define LONG_PRESS_MS		2000
#define SETTLE_MS		15
#define RELEASE_DEBOUNCE_MS	30
#define POLL_US			5000
#define IDENTITY_SAMPLES	3
#define GPIO_INIT_RETRIES	15
#define GPIO_INIT_RETRY_MS	200

#define PRESS_CHIP_PATH		"/dev/gpiochip0"
#define PRESS_LINE_OFFSET	23
#define SELECT_CHIP_PATH	"/dev/gpiochip10"
#define SELECT_LINE_OFFSET	20

static int uk_fd = -1;
static int power_key_held = 0;

static struct gpiod_chip *press_chip;
static struct gpiod_chip *select_chip;
static struct gpiod_line_request *press_request;
static struct gpiod_line_request *select_request;

static int last_button_down = 0;
static int last_button_valid = 0;

static inline long monotonic_ms(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now))
		return 0;

	return (long)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static struct gpiod_line_request *request_input_line(struct gpiod_chip *chip,
						     unsigned int offset,
						     int active_low)
{
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *line_cfg;
	struct gpiod_request_config *req_cfg;
	struct gpiod_line_request *request;
	unsigned int offsets[] = { offset };

	settings = gpiod_line_settings_new();
	if (!settings)
		return NULL;

	gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_INPUT);
	gpiod_line_settings_set_bias(settings, GPIOD_LINE_BIAS_PULL_UP);
	if (active_low)
		gpiod_line_settings_set_active_low(settings, true);

	line_cfg = gpiod_line_config_new();
	if (!line_cfg) {
		gpiod_line_settings_free(settings);
		return NULL;
	}

	if (gpiod_line_config_add_line_settings(line_cfg, offsets, 1, settings) < 0) {
		gpiod_line_settings_free(settings);
		gpiod_line_config_free(line_cfg);
		return NULL;
	}
	gpiod_line_settings_free(settings);

	req_cfg = gpiod_request_config_new();
	if (!req_cfg) {
		gpiod_line_config_free(line_cfg);
		return NULL;
	}
	gpiod_request_config_set_consumer(req_cfg, "pibrickbtn");

	request = gpiod_chip_request_lines(chip, req_cfg, line_cfg);
	gpiod_request_config_free(req_cfg);
	gpiod_line_config_free(line_cfg);

	return request;
}

static void unload_gpio_keys(void)
{
	/*
	 * gpio_keys binds the button GPIOs from device tree at boot.
	 * Must release before gpiod can request the same lines (EBUSY otherwise).
	 */
	system("/sbin/modprobe -r gpio_keys 2>/dev/null");
	system("/sbin/rmmod gpio_keys 2>/dev/null");
}

static void gpio_release_partial(void)
{
	if (press_request) {
		gpiod_line_request_release(press_request);
		press_request = NULL;
	}
	if (select_request) {
		gpiod_line_request_release(select_request);
		select_request = NULL;
	}
	if (press_chip) {
		gpiod_chip_close(press_chip);
		press_chip = NULL;
	}
	if (select_chip) {
		gpiod_chip_close(select_chip);
		select_chip = NULL;
	}
}

static int gpio_init_once(void)
{
	press_chip = gpiod_chip_open(PRESS_CHIP_PATH);
	if (!press_chip)
		return -1;

	select_chip = gpiod_chip_open(SELECT_CHIP_PATH);
	if (!select_chip) {
		gpiod_chip_close(press_chip);
		press_chip = NULL;
		return -1;
	}

	press_request = request_input_line(press_chip, PRESS_LINE_OFFSET, 1);
	if (!press_request)
		goto fail;

	select_request = request_input_line(select_chip, SELECT_LINE_OFFSET, 0);
	if (!select_request)
		goto fail;

	return 0;

fail:
	gpio_release_partial();
	return -1;
}

static int gpio_init(void)
{
	int attempt;

	unload_gpio_keys();

	for (attempt = 0; attempt < GPIO_INIT_RETRIES; attempt++) {
		if (attempt > 0) {
			if (attempt % 3 == 0)
				unload_gpio_keys();
			usleep(GPIO_INIT_RETRY_MS * 1000);
		}

		if (gpio_init_once() == 0)
			return 0;
	}

	return -1;
}

static void gpio_close(void)
{
	if (press_request) {
		gpiod_line_request_release(press_request);
		press_request = NULL;
	}
	if (select_request) {
		gpiod_line_request_release(select_request);
		select_request = NULL;
	}
	if (press_chip) {
		gpiod_chip_close(press_chip);
		press_chip = NULL;
	}
	if (select_chip) {
		gpiod_chip_close(select_chip);
		select_chip = NULL;
	}
}

/*
 * PiBrick wiring (measured on hardware):
 *   idle:  press=0 select=1
 *   user:  press=1 select=0  (chip0:23 pulled low)
 *   power: press=0 select=0  (only chip10:20 changes)
 *
 * Press line (active-low): 1 = user button pulling line 23 low.
 * Select line: 0 = held, 1 = idle.
 */
static int gpio_press_read(void)
{
	enum gpiod_line_value value;

	value = gpiod_line_request_get_value(press_request, PRESS_LINE_OFFSET);
	if (value == GPIOD_LINE_VALUE_ERROR)
		return -1;
	return (value == GPIOD_LINE_VALUE_ACTIVE) ? 1 : 0;
}

static int gpio_select_read(void)
{
	enum gpiod_line_value value;

	value = gpiod_line_request_get_value(select_request, SELECT_LINE_OFFSET);
	if (value == GPIOD_LINE_VALUE_ERROR)
		return -1;
	return (value == GPIOD_LINE_VALUE_ACTIVE) ? 1 : 0;
}

static int read_button_down(void)
{
	int press = gpio_press_read();
	int select = gpio_select_read();

	if (press < 0 || select < 0)
		return -1;

	/* idle: press=0 select=1; any held button: select=0 */
	return (press == 1) || (select == 0);
}

static int button_is_down(void)
{
	int down = read_button_down();

	if (down < 0)
		return last_button_valid ? last_button_down : 0;

	last_button_down = down;
	last_button_valid = 1;
	return last_button_down;
}

static int sample_is_power(void)
{
	int press = gpio_press_read();
	int select = gpio_select_read();

	if (press < 0 || select < 0)
		return -1;

	return (press == 0 && select == 0);
}

static int button_is_power(void)
{
	int power_votes = 0;
	int i;

	for (i = 0; i < IDENTITY_SAMPLES; i++) {
		int is_power = sample_is_power();

		if (is_power > 0)
			power_votes++;
		usleep(3000);
	}

	return power_votes > (IDENTITY_SAMPLES / 2);
}

static int uk_init(void)
{
	struct uinput_user_dev uidev;

	uk_fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (uk_fd < 0)
		return -1;

	if (ioctl(uk_fd, UI_SET_EVBIT, EV_KEY) < 0)
		return -1;
	if (ioctl(uk_fd, UI_SET_KEYBIT, KEY_POWER) < 0)
		return -1;

	memset(&uidev, 0, sizeof(uidev));
	snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "pibrickbtn");
	uidev.id.bustype = BUS_USB;
	uidev.id.vendor = 0x1234;
	uidev.id.product = 0x5678;
	uidev.id.version = 1;

	if (write(uk_fd, &uidev, sizeof(uidev)) < 0)
		return -1;
	if (ioctl(uk_fd, UI_DEV_CREATE) < 0)
		return -1;

	return 0;
}

static int uk_send_key(int keycode, int keystate)
{
	struct input_event ev;

	if (uk_fd < 0)
		return -1;

	memset(&ev, 0, sizeof(ev));
	ev.type = EV_KEY;
	ev.code = keycode;
	ev.value = keystate;
	if (write(uk_fd, &ev, sizeof(ev)) < 0)
		return -1;

	memset(&ev, 0, sizeof(ev));
	ev.type = EV_SYN;
	ev.code = SYN_REPORT;
	ev.value = 0;
	if (write(uk_fd, &ev, sizeof(ev)) < 0)
		return -1;

	return 0;
}

static void uk_close(void)
{
	if (uk_fd >= 0) {
		if (power_key_held) {
			uk_send_key(KEY_POWER, 0);
			power_key_held = 0;
		}
		ioctl(uk_fd, UI_DEV_DESTROY);
		close(uk_fd);
		uk_fd = -1;
	}
}

#define POWER_KEY_TAP_US 100000

static void power_key_short_tap(void)
{
	syslog(LOG_INFO, "power short -> KEY_POWER tap");
	uk_send_key(KEY_POWER, 1);
	usleep(POWER_KEY_TAP_US);
	uk_send_key(KEY_POWER, 0);
}

static void run_script_async(const char *path)
{
	char command[180];

	snprintf(command, sizeof(command), "/bin/bash %s >/dev/null 2>&1 &", path);
	if (system(command) != 0)
		syslog(LOG_WARNING, "script failed to start: %s", path);
}

static void run_script(const char *path)
{
	char command[160];

	snprintf(command, sizeof(command), "/bin/bash %s", path);
	if (system(command) != 0)
		syslog(LOG_WARNING, "script failed: %s", path);
}

static void power_key_long_press_down(void)
{
	syslog(LOG_INFO, "power long -> KEY_POWER hold (shutdown)");
	uk_send_key(KEY_POWER, 1);
	power_key_held = 1;
}

static void power_key_long_press_up(void)
{
	if (!power_key_held)
		return;
	uk_send_key(KEY_POWER, 0);
	power_key_held = 0;
}

static int wait_stable_release(void)
{
	for (;;) {
		if (button_is_down()) {
			usleep(POLL_US);
			continue;
		}

		usleep(RELEASE_DEBOUNCE_MS * 1000);
		if (button_is_down())
			continue;

		return 1;
	}
}

static void handle_one_gesture(void)
{
	long press_start_ms;
	long held_ms;
	int is_power;
	int long_done = 0;

	while (!button_is_down())
		usleep(POLL_US);

	press_start_ms = monotonic_ms();
	usleep(SETTLE_MS * 1000);
	if (!button_is_down())
		return;

	is_power = button_is_power();

	for (;;) {
		if (!button_is_down()) {
			usleep(RELEASE_DEBOUNCE_MS * 1000);
			if (button_is_down())
				continue;
			break;
		}

		if (!long_done &&
		    monotonic_ms() - press_start_ms >= LONG_PRESS_MS) {
			long_done = 1;
			if (is_power)
				power_key_long_press_down();
		}

		usleep(POLL_US);
	}

	held_ms = monotonic_ms() - press_start_ms;

	if (long_done && is_power) {
		power_key_long_press_up();
		return;
	}

	if (!long_done && held_ms < LONG_PRESS_MS) {
		if (is_power) {
			syslog(LOG_INFO, "power short -> desktop power menu (%ld ms)", held_ms);
			power_key_short_tap();
			run_script_async("/etc/pibrick/power-short.sh");
		} else {
			syslog(LOG_INFO, "user short -> display toggle (%ld ms)", held_ms);
			run_script("/etc/pibrick/user-short.sh");
		}
	}
}

static void service_loop(void)
{
	for (;;) {
		handle_one_gesture();
		wait_stable_release();
	}
}

static void warn_if_service_running(void)
{
	if (system("systemctl is-active --quiet pibrickbtn 2>/dev/null") == 0) {
		printf("Note: stop pibrickbtn.service first for a clean test:\n");
		printf("  sudo systemctl stop pibrickbtn\n\n");
	}
}

static void gpio_test_loop(void)
{
	int last_press = -2;
	int last_select = -2;

	warn_if_service_running();

	printf("GPIO monitor (Ctrl+C to exit)\n");
	printf("  idle:  press=0 select=1\n");
	printf("  user:  press=1 select=0\n");
	printf("  power: press=0 select=0\n\n");

	for (;;) {
		int press = gpio_press_read();
		int select = gpio_select_read();
		const char *state = "idle";

		if (press == 1 && select == 0)
			state = "user";
		else if (press == 0 && select == 0)
			state = "power";

		if (press != last_press || select != last_select) {
			printf("press=%d select=%d -> %s\n", press, select, state);
			last_press = press;
			last_select = select;
		}

		usleep(50000);
	}
}

int main(int argc, char *argv[])
{
	openlog("pibrickbtn", LOG_PID, LOG_DAEMON);

	if (gpio_init() < 0) {
		fprintf(stderr,
			"pibrickbtn: GPIO init failed (%s) — unload gpio_keys and retry\n",
			strerror(errno));
		syslog(LOG_ERR,
		       "GPIO init failed (%s); gpio_keys may still own gpiochip0:23 / gpiochip10:20",
		       strerror(errno));
		return 1;
	}

	if (argc > 1 && strcmp(argv[1], "--test") == 0) {
		gpio_test_loop();
		gpio_close();
		return 0;
	}

	if (uk_init() < 0) {
		fprintf(stderr, "pibrickbtn: uinput init failed\n");
		syslog(LOG_ERR, "uinput init failed");
		gpio_close();
		return 1;
	}

	syslog(LOG_INFO, "started");
	service_loop();

	uk_close();
	gpio_close();
	closelog();
	return 0;
}
