#!/usr/bin/env bash
#
# probe-led.sh -- reload a codec fixup, then walk through the mute states one
# at a time so you can see *which* physical key LED lights up.
#
# The point: the earlier test toggled the microphone while the speaker was
# already muted, and the fixup also re-routes the speaker LED, so the result
# was ambiguous.  This script changes exactly one thing per step and leaves
# it alone long enough to look at the keyboard.
#
# Usage:
#   sudo ./probe-led.sh 103c:8b65     # test a fixup
#   sudo ./probe-led.sh --restore     # baseline: default (vendor) fixup
#
# At the end it prints the three questions to answer and restores your
# original mute state.

set -uo pipefail

TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo keane)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
export XDG_RUNTIME_DIR="/run/user/$TARGET_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus"

STEP_WAIT="${STEP_WAIT:-6}"

as_user() {
    runuser -u "$TARGET_USER" -- env \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        "$@"
}

if [[ $EUID -ne 0 ]]; then
    echo "This needs root:  sudo $0 ${1:-103c:8b65}" >&2
    exit 1
fi

audio_procs_running() {
    local n
    for n in pipewire wireplumber pipewire-pulse; do
        pgrep -u "$TARGET_UID" -x "$n" >/dev/null 2>&1 && return 0
    done
    return 1
}

stop_audio() {
    as_user systemctl --user stop \
        pipewire.socket pipewire-pulse.socket \
        wireplumber pipewire-pulse pipewire >/dev/null 2>&1
    local i
    for i in $(seq 1 20); do
        audio_procs_running || break
        sleep 0.5
    done
    if audio_procs_running; then
        local sig
        for sig in TERM KILL; do
            for n in pipewire wireplumber pipewire-pulse; do
                pkill -"$sig" -u "$TARGET_UID" -x "$n" 2>/dev/null
            done
            sleep 1
        done
    fi
    audio_procs_running && return 1
    return 0
}

start_audio() {
    as_user systemctl --user start \
        pipewire.socket pipewire-pulse.socket \
        pipewire pipewire-pulse wireplumber >/dev/null 2>&1
    sleep 2
}

mute_ctl() {  # mute_ctl source|sink 0|1
    local what="$1" on="$2"
    case "$what" in
        source) as_user wpctl set-mute @DEFAULT_AUDIO_SOURCE@ "$on" ;;
        sink)   as_user wpctl set-mute @DEFAULT_AUDIO_SINK@  "$on" ;;
    esac
}

state() {
    printf '        [state] speaker-led=%s mic-led=%s  hda::mute=%s hda::micmute=%s\n' \
        "$(cat /sys/class/sound/ctl-led/speaker/card1/brightness 2>/dev/null || echo n/a)" \
        "$(cat /sys/class/sound/ctl-led/mic/card1/brightness 2>/dev/null || echo n/a)" \
        "$(cat /sys/class/leds/hda::mute/brightness 2>/dev/null || echo -)" \
        "$(cat /sys/class/leds/hda::micmute/brightness 2>/dev/null || echo -)"
}

step() {  # step <seconds> <headline>
    echo
    echo "  >>> $2"
    state
    sleep "$1"
}

# ---------------------------------------------------------------- load fixup

MODEL=""
if [[ "${1:-}" == "--restore" || -z "${1:-}" ]]; then
    echo "==> baseline: default vendor fixup (no model=)"
else
    MODEL="$1"
    if [[ "$MODEL" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$ ]]; then
        MODEL="$MODEL,$MODEL,$MODEL,$MODEL"
    fi
    echo "==> applying model=$MODEL"
fi

echo "==> stopping user audio"
stop_audio || { echo "    !! audio processes stuck; giving up" >&2; start_audio; exit 1; }
echo "==> refcnt after stop: $(cat /sys/module/snd_hda_intel/refcnt 2>/dev/null || echo '?')"
modprobe -r snd_hda_intel 2>/dev/null
if grep -q '^snd_hda_intel' /proc/modules; then
    echo "    !! could not unload snd_hda_intel" >&2
    start_audio
    exit 1
fi
if [[ -n "$MODEL" ]]; then
    modprobe snd_hda_intel model="$MODEL"
else
    modprobe snd_hda_intel
fi
sleep 2
start_audio

echo
echo "==> LED class devices now present:"
ls /sys/class/leds/ | grep -E 'hda::' | sed 's/^/    /'

# ------------------------------------------------------- remember + reset state

orig_src="$(as_user wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED && echo 1 || echo 0)"
orig_snk="$(as_user wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED && echo 1 || echo 0)"

echo
echo "=========================================================================="
echo "Watch the keyboard LEDs (F5 = speaker-mute, F8 = microphone-mute)."
echo "Every step below changes ONE thing and then waits ${STEP_WAIT}s."
echo "=========================================================================="

mute_ctl source 0
mute_ctl sink 0
step "$STEP_WAIT" "STEP 1: nothing muted.  Both LEDs should be dark -> note which are lit anyway"

mute_ctl source 1
step "$STEP_WAIT" "STEP 2: MICROPHONE muted -> WHICH LED IS LIT?  (F5 / F8 / both / neither)"

mute_ctl source 0
sleep 2
mute_ctl sink 1
step "$STEP_WAIT" "STEP 3: SPEAKER muted -> WHICH LED IS LIT?  (F5 / F8 / both / neither)"

# ---------------------------------------------------------------- restore

mute_ctl source "$orig_src"
mute_ctl sink "$orig_snk"

echo
echo "=========================================================================="
echo "Answer these three (a photo/typing of what you saw is enough):"
echo "  STEP 2 (mic muted)     -> which LED lit?"
echo "  STEP 3 (speaker muted) -> which LED lit?"
echo "=========================================================================="
echo "mute state restored: source=$orig_src sink=$orig_snk"
echo "kernel fixup log line:"
journalctl -k --no-pager 2>/dev/null | grep -iE 'picked fixup|Detected mute LED' | tail -2 | sed 's/^/    /'
