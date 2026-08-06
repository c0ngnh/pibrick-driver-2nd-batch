#!/bin/sh
# Revert Pi HDMI cards from pro-audio back to stereo HDMI output.
# Plasma Settings can still request pro-audio; this keeps desktop audio working.

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/default-profile"

fix_hdmi_profiles() {
    changed=0
    for card in $(pactl list cards short 2>/dev/null | awk '/platform-.*hdmi/ {print $2}'); do
        active=$(pactl list cards 2>/dev/null | sed -n "/Name: $card\$/,/^$/p" | awk '/Active Profile:/ {print $3; exit}')
        if [ "$active" = "pro-audio" ]; then
            if pactl set-card-profile "$card" output:hdmi-stereo 2>/dev/null; then
                changed=1
            fi
        fi
    done

    if [ "$changed" = "1" ] && [ -f "$STATE_FILE" ]; then
        sed -i 's/=pro-audio/=output:hdmi-stereo/g' "$STATE_FILE"
    fi

    sink=$(pactl list sinks short 2>/dev/null | awk '/platform-.*hdmi.*hdmi-stereo/ {print $2; exit}')
    if [ -n "$sink" ]; then
        default_sink=$(pactl info 2>/dev/null | awk -F': ' '/Default Sink:/ {print $2}')
        if [ "$default_sink" = "auto_null" ] || [ -z "$default_sink" ]; then
            pactl set-default-sink "$sink" 2>/dev/null || true
        fi
    fi
}

fix_hdmi_profiles

pactl subscribe 2>/dev/null | while read -r _ event _rest; do
    case "$event" in
        "'change'")
            fix_hdmi_profiles
            ;;
    esac
done
