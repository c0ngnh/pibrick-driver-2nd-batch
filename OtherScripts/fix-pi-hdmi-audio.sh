#!/bin/sh
# Fix HDMI audio on Raspberry Pi with PipeWire/WirePlumber + Plasma Mobile.
#
# Problem: Choosing "Pro Audio" in sound settings switches the HDMI card to the
# pro-audio profile. That profile exposes raw PCM devices, not a normal playback
# sink, so desktop audio goes to "Dummy Output" and HDMI is silent.
#
# Fix: Force HDMI stereo on startup and run a guard that reverts Pro Audio if
# selected in Settings (WirePlumber cannot block manual profile changes).
#
# Usage:
#   ./fix-pi-hdmi-audio.sh
#   ./fix-pi-hdmi-audio.sh --card alsa_card.platform-107c701400.hdmi
#
# After running, audio should work immediately; the fix persists across reboots.
# Pro Audio may appear in Settings but will be reverted automatically.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CARD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --card)
            CARD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--card CARD_NAME]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this script as the desktop user (not root)." >&2
    exit 1
fi

if ! command -v wpctl >/dev/null 2>&1 || ! command -v pactl >/dev/null 2>&1; then
    echo "wpctl and pactl are required (pipewire / wireplumber)." >&2
    exit 1
fi

WP_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
WP_CONF="$WP_CONF_DIR/51-pi-hdmi-profile.conf"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber"
GUARD_BIN="${XDG_DATA_HOME:-$HOME/.local}/bin/pi-hdmi-audio-guard.sh"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SERVICE_DIR/pi-hdmi-audio-guard.service"

mkdir -p "$WP_CONF_DIR" "${GUARD_BIN%/*}" "$SERVICE_DIR"

# Auto-detect Pi vc4 HDMI cards if not specified.
if [ -z "$CARD" ]; then
    CARD_LIST=$(pactl list cards short 2>/dev/null | awk '/platform-.*hdmi/ {print $2}' | tr '\n' ' ')
    if [ -z "$CARD_LIST" ]; then
        echo "No platform HDMI cards found. If your card name differs, rerun with:" >&2
        echo "  $0 --card alsa_card.YOUR_CARD_NAME" >&2
        echo "Find names with: pactl list cards short" >&2
        exit 1
    fi
fi

cat > "$WP_CONF" <<'EOF'
# Raspberry Pi vc4 HDMI: keep normal stereo output and hide Pro Audio.
# Pro Audio exposes raw PCM nodes without a normal playback sink, which
# breaks desktop/Plasma audio when selected in Settings.
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.platform-.*\\.hdmi" }
    ]
    actions = {
      update-props = {
        api.acp.auto-profile = false
        api.acp.auto-port = false
        api.acp.disable-pro-audio = true
        device.profile = "output:hdmi-stereo"
      }
    }
  }
]
EOF

# Replace any previously saved pro-audio profile choice.
if [ -f "$STATE_DIR/default-profile" ]; then
    sed -i 's/=pro-audio/=output:hdmi-stereo/g' "$STATE_DIR/default-profile"
fi

if [ -f "$SCRIPT_DIR/pi-hdmi-audio-guard.sh" ]; then
    cp "$SCRIPT_DIR/pi-hdmi-audio-guard.sh" "$GUARD_BIN"
else
    cat > "$GUARD_BIN" <<'GUARDEOF'
#!/bin/sh
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
        "'change'") fix_hdmi_profiles ;;
    esac
done
GUARDEOF
fi
chmod +x "$GUARD_BIN"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Keep Raspberry Pi HDMI on stereo output (block pro-audio)
After=pipewire-pulse.service wireplumber.service
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$GUARD_BIN
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now pi-hdmi-audio-guard.service 2>/dev/null || true
    systemctl --user restart wireplumber pipewire-pulse 2>/dev/null || true
    sleep 2
    systemctl --user restart pi-hdmi-audio-guard.service 2>/dev/null || true
fi

# Apply immediately for the primary HDMI card (first connected port).
PRIMARY_CARD=$(pactl list cards short 2>/dev/null | awk '/platform-.*hdmi/ {print $2; exit}')
if [ -n "$PRIMARY_CARD" ]; then
    pactl set-card-profile "$PRIMARY_CARD" output:hdmi-stereo 2>/dev/null || true
    SINK=$(pactl list sinks short 2>/dev/null | awk '/platform-.*hdmi.*hdmi-stereo/ {print $2; exit}')
    if [ -n "$SINK" ]; then
        pactl set-default-sink "$SINK" 2>/dev/null || true
    fi
fi

echo ""
echo "Installed:"
echo "  $WP_CONF"
echo "  $GUARD_BIN"
echo "  $SERVICE_FILE"
echo ""
echo "What this does:"
echo "  - Starts HDMI on profile output:hdmi-stereo (Digital Stereo HDMI)"
echo "  - Runs pi-hdmi-audio-guard.service to revert Pro Audio if selected"
echo ""
echo "Pro Audio may still appear in Settings, but HDMI sound is restored automatically."
echo ""
echo "Current status:"
pactl list cards 2>/dev/null | grep -E 'Name:|Active Profile:' | head -6 || true
pactl info 2>/dev/null | grep 'Default Sink' || true
systemctl --user is-active pi-hdmi-audio-guard.service 2>/dev/null || true
