#!/bin/bash
# Pi diagnostic — gather state for broken top-bar issue.
# Run on the Pi as the desktop user (NOT root) and paste all output.

set +e

echo "============================================================"
echo " Pi diagnostic — top bar missing"
echo " Date:        $(date)"
echo " Hostname:    $(hostname)"
echo " User:        $(whoami)"
echo " Kernel:      $(uname -r)"
echo "============================================================"

echo
echo "──── /etc/os-release ────"
cat /etc/os-release 2>/dev/null | head -10

echo
echo "──── DE / session ────"
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
echo "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "DISPLAY=$DISPLAY"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
loginctl show-session "$(loginctl | awk '/c[0-9]/ {print $1; exit}')" 2>/dev/null \
    | grep -E '^(Id|User|Name|Type|Remote|Active|State|Original)' | sort

echo
echo "──── SDDM / display manager ────"
systemctl is-active sddm 2>/dev/null && echo "sddm: active" || echo "sddm: NOT active"
ls -la /etc/sddm.conf.d/ 2>/dev/null
echo "--- relevant SDDM config files ---"
for f in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
    [ -f "$f" ] && echo "=== $f ===" && cat "$f" | grep -vE '^\s*#|^\s*$'
done

echo
echo "──── systemd default target ────"
systemctl get-default

echo
echo "──── Loaded pibrick-related modules ────"
lsmod | grep -Ei 'pibrick|bq25890|mma|hyn|ft5'

echo
echo "──── pibrick system services ────"
for svc in pibrick.service pibrickbtn.service pibrick-autorotation.service pibrickbattery-load-soc.service pibrick-battery-load-soc.service pibrick-battery-soc-persist.service; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    en=$(systemctl is-enabled "$svc" 2>/dev/null)
    echo "  $svc: active=$state enabled=$en"
done

echo
echo "──── user-level pibrick services (run as desktop user) ────"
for svc in pibrick-rotation-ui.service pibrick-autorotation.service; do
    if command -v systemctl >/dev/null; then
        out=$(systemctl --user status "$svc" 2>&1 | head -5)
        [ -n "$out" ] && echo "--- $svc ---" && echo "$out"
    fi
done

echo
echo "──── KWin user drop-ins ────"
echo "Drop-in dir: $HOME/.config/systemd/user/plasma-kwin_wayland.service.d/"
ls -la "$HOME/.config/systemd/user/plasma-kwin_wayland.service.d/" 2>/dev/null
for f in "$HOME/.config/systemd/user/plasma-kwin_wayland.service.d/"*.conf; do
    [ -f "$f" ] && echo "=== $f ===" && cat "$f" | grep -vE '^\s*#|^\s*$'
done

echo
echo "──── SDDM override dir (system) ────"
ls -la /etc/systemd/system/sddm.service.d/ 2>/dev/null
for f in /etc/systemd/system/sddm.service.d/*.conf; do
    [ -f "$f" ] && echo "=== $f ===" && cat "$f" | grep -vE '^\s*#|^\s*$'
done

echo
echo "──── /boot/firmware/config.txt (pibrick lines only) ────"
grep -nE 'ignore_lcd|dtoverlay|dtparam.*i2c|hyn|panel|mma|bq25890' /boot/firmware/config.txt 2>/dev/null

echo
echo "──── I2C bus summary (look for bq25890@6a, mma8451@1c/1d) ────"
for bus in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
    if [ -e "/dev/i2c-$bus" ]; then
        out=$(i2cdetect -y "$bus" 2>/dev/null | awk '/^[0-9]+:/ {print}')
        if echo "$out" | grep -qE ' 6a | 1c | 1d '; then
            echo "--- i2c-$bus ---"
            echo "$out"
        fi
    fi
done

echo
echo "──── /sys/class/power_supply entries ────"
ls -la /sys/class/power_supply/ 2>/dev/null
for ps in /sys/class/power_supply/*/; do
    name=$(basename "$ps")
    [ "$name" = "*" ] && continue
    type=$(cat "$ps/type" 2>/dev/null)
    status=$(cat "$ps/status" 2>/dev/null)
    ina=$(cat "$ps/ina228_present" 2>/dev/null)
    echo "  $name: type=$type status=$status ina228_present=$ina"
done

echo
echo "──── /sys/class/graphics entries (panel/fbcon) ────"
ls -la /sys/class/graphics/ 2>/dev/null
for fb in /sys/class/graphics/fb*/; do
    [ -d "$fb" ] && echo "  $fb" && cat "$fb/name" 2>/dev/null && echo "  modes: $(cat "$fb/modes" 2>/dev/null | tr '\n' ' ')"
done

echo
echo "──── Qt / KDE / Plasma versions ────"
dpkg -l plasma-mobile 2>/dev/null | grep -E '^ii ' | awk '{print "  plasma-mobile " $3}'
dpkg -l plasma-workspace 2>/dev/null | grep -E '^ii ' | awk '{print "  plasma-workspace " $3}'
dpkg -l kwin-wayland 2>/dev/null | grep -E '^ii ' | awk '{print "  kwin-wayland " $3}'
dpkg -l kwin 2>/dev/null | grep -E '^ii ' | awk '{print "  kwin " $3}'
dpkg -l sddm 2>/dev/null | grep -E '^ii ' | awk '{print "  sddm " $3}'
dpkg -l upower 2>/dev/null | grep -E '^ii ' | awk '{print "  upower " $3}'
dpkg -l libqt6core6 2>/dev/null | grep -E '^ii ' | awk '{print "  libqt6core6 " $3}'
dpkg -l libkf6coreaddons6 2>/dev/null | grep -E '^ii ' | awk '{print "  libkf6coreaddons6 " $3}'

echo
echo "──── upowerd (patched?) ────"
ls -la /usr/libexec/upowerd /usr/lib/upower/upowerd 2>/dev/null
ls /usr/libexec/upowerd.bak-pibrick-* /usr/lib/upower/upowerd.bak-pibrick-* 2>/dev/null
# Check if our marker is present
file /usr/libexec/upowerd 2>/dev/null | head -1
strings /usr/libexec/upowerd 2>/dev/null | grep -i 'pibrick' | head -3

echo
echo "──── pibrick helper scripts ────"
ls -la /usr/local/bin/pibrick-tools 2>/dev/null
ls -la /usr/lib/pibrick/autorotation-service/ 2>/dev/null
ls -la /usr/lib/pibrick/ 2>/dev/null

echo
echo "──── autorotation D-Bus service ────"
ls -la "$HOME/.local/share/dbus-1/services/com.pibrick.Autorotation.service" 2>/dev/null
ls -la "$HOME/.local/share/plasma/plasmoids/pibrick-rotation-lock/" 2>/dev/null
ls -la "$HOME/.local/share/kservices5/pibrick-rotation-lock/" 2>/dev/null

echo
echo "──── pibrick-rotation-ui.service ────"
ls -la "$HOME/.config/systemd/user/pibrick-rotation-ui.service" 2>/dev/null
[ -f "$HOME/.config/systemd/user/pibrick-rotation-ui.service" ] && \
    cat "$HOME/.config/systemd/user/pibrick-rotation-ui.service"

echo
echo "──── /usr/bin autorotation tools ────"
ls -la /usr/bin/autorotation-lock /usr/bin/pibrick-autorotation-ctl 2>/dev/null

echo
echo "──── Wayland / KWin env from journalctl (last 50 lines) ────"
journalctl --user -n 200 --no-pager 2>/dev/null | grep -iE 'kwin|plasma|composit|wayland|egl|gbm|libinput|seatd' | tail -40

echo
echo "──── system journal (KWin / SDDM / disaster last 200) ────"
journalctl -n 500 --no-pager 2>/dev/null | grep -iE 'sddm|kwin|plasma-kwin|composit|wayland|egl|gbm|emergency|disaster|failed' | tail -30

echo
echo "──── pibrick-autorotation.service status (last 30) ────"
journalctl -u pibrick-autorotation.service -n 30 --no-pager 2>/dev/null

echo
echo "──── pibrick-rotation-ui.service status (user, last 30) ────"
journalctl --user -u pibrick-rotation-ui.service -n 30 --no-pager 2>/dev/null

echo
echo "──── Plasma Mobile shell panel / shell cmp process ────"
ps -ef | grep -E 'plasmashell|plasma_mobile|kscreenlocker|kwin_wayland|orchid' | grep -v grep

echo
echo "──── XDG_CONFIG_DIRS / XDG_DATA_DIRS (passes to Qt) ────"
echo "  XDG_CONFIG_DIRS=$XDG_CONFIG_DIRS"
echo "  XDG_DATA_DIRS=$XDG_DATA_DIRS"
echo "  QT_WAYLAND_DISABLE_WINDOWDECORATION=$QT_WAYLAND_DISABLE_WINDOWDECORATION"
echo "  QT_QPA_PLATFORM=$QT_QPA_PLATFORM"
echo "  QT_QPA_PLATFORMTHEME=$QT_QPA_PLATFORMTHEME"

echo
echo "──── /tmp/pibrick flags (if any) ────"
ls -la /tmp/pibrick* /var/lib/pibrick/* 2>/dev/null

echo
echo "============================================================"
echo " Diagnostic complete."
echo "============================================================"
