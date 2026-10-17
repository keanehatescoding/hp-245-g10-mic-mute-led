#!/usr/bin/env bash
#
# test-model.sh -- try a codec fixup (via the SSID-alias model option)
# without rebooting, and report whether a microphone mute LED appears.
#
# Usage:
#   sudo ./test-model.sh 103c:8b65     # apply that fixup
#   sudo ./test-model.sh --restore     # go back to the default (no model=)
#   sudo ./test-model.sh --status      # just print the current LED state
#
# What it does:
#   1. stops the user's PipeWire sockets *and* services (sockets first, or
#      socket activation just restarts them), then verifies the card is
#      actually released
#   2. unloads and reloads snd_hda_intel with model=<alias>
#   3. waits, then prints the LED devices / ctl-led bindings
#   4. restarts the user's audio stack
#
# WARNING: your audio will drop for a few seconds.  If anything goes
# wrong, just reboot -- the override is not permanent (this script
# passes model= on the modprobe command line only).
#
set -uo pipefail

TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo keane)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
export XDG_RUNTIME_DIR="/run/user/$TARGET_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus"

as_user() {
    runuser -u "$TARGET_USER" -- env \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        "$@"
}

report() {
    echo
    echo "==> LED class devices:"
    ls /sys/class/leds/ 2>/dev/null | grep -E 'hda::|micmute' || echo "    (none matching hda::)"
    echo
    if [[ -e /sys/class/leds/hda::micmute ]]; then
        echo "    *** hda::micmute EXISTS ***  -> press F8 and check the LED"
        echo "        trigger: $(cat /sys/class/leds/hda::micmute/trigger 2>/dev/null | tr ' ' '\n' | grep '\[' || true)"
    else
        echo "    no hda::micmute -> this fixup did not give you a mic LED"
    fi
    echo
    echo "==> ctl-led bindings (card1):"
    for l in speaker mic; do
        printf '    %-8s list = %s\n' "$l" "$(cat /sys/class/sound/ctl-led/$l/card1/list 2>/dev/null || echo n/a)"
    done
}

if [[ "${1:-}" == "--status" ]]; then
    report
    exit 0
fi

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
    echo "==> stopping user audio (sockets first, then services)"
    as_user systemctl --user stop \
        pipewire.socket pipewire-pulse.socket \
        wireplumber pipewire-pulse pipewire 2>&1 | sed 's/^/    /'

    local i
    for i in $(seq 1 20); do
        audio_procs_running || break
        sleep 0.5
    done

    # last resort: if the manager refused, kill the processes outright
    if audio_procs_running; then
        echo "    systemd stop did not take effect; killing processes"
        local sig
        for sig in TERM KILL; do
            for n in pipewire wireplumber pipewire-pulse; do
                pkill -"$sig" -u "$TARGET_UID" -x "$n" 2>/dev/null
            done
            sleep 1
        done
    fi

    if audio_procs_running; then
        echo "    remaining audio processes: yes"
        return 1
    fi
    echo "    remaining audio processes: none"
    return 0
}

start_audio() {
    echo "==> restarting user audio"
    as_user systemctl --user start \
        pipewire.socket pipewire-pulse.socket \
        pipewire pipewire-pulse wireplumber 2>&1 | sed 's/^/    /'
    sleep 1
}

MODEL=""
if [[ "${1:-}" == "--restore" || -z "${1:-}" ]]; then
    MODEL=""
    echo "==> restoring default fixup (no model=)"
else
    MODEL="$1"
    # `model` is an array of charp indexed by HDA *controller*, not by codec.
    # snd_hda_intel assigns those indices with find_first_zero_bit(probed_devs)
    # i.e. in PCI probe order -- so on this laptop model[0] is the HDMI
    # controller (03:00.1) and the ALC236 (03:00.6) is model[1].
    # A bare "VVVV:DDDD" would only reach index 0, so fan it out over the
    # first few controller slots (the non-matching codecs just ignore it).
    if [[ "$MODEL" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$ ]]; then
        MODEL="$MODEL,$MODEL,$MODEL,$MODEL"
    fi
    echo "==> applying model=$MODEL"
fi

stop_audio

REF="$(cat /sys/module/snd_hda_intel/refcnt 2>/dev/null || echo '?')"
echo "==> snd_hda_intel refcnt after stop: $REF"

echo "==> unloading snd_hda_intel"
unload_out="$(modprobe -r snd_hda_intel 2>&1)"; unload_rc=$?
[[ -n "$unload_out" ]] && printf '%s\n' "$unload_out" | sed 's/^/    /'
if [[ $unload_rc -ne 0 ]] || grep -q '^snd_hda_intel' /proc/modules; then
    echo "    !! could not unload snd_hda_intel." >&2
    echo "       Something still holds the card.  Restarting audio;" >&2
    echo "       use the reboot method instead (see README.md)." >&2
    start_audio
    exit 1
fi

# A codec module that is already resident keeps running its old code, so a
# freshly installed snd-hda-codec-*.ko would otherwise never be loaded (this
# is why a rebuilt alc269 module used to appear to have no effect).
echo "==> unloading codec modules, so a rebuilt one is really re-loaded"
for m in snd_hda_codec_alc269 snd_hda_codec_realtek_lib snd_hda_codec_generic \
	 snd_hda_codec; do
	grep -q "^${m} " /proc/modules || continue
	if ! out="$(modprobe -r "$m" 2>&1)"; then
		printf '%s\n' "$out" | sed 's/^/    /'
	fi
	grep -q "^${m} " /proc/modules && echo "    !! $m is still resident"
done

echo "==> loading snd_hda_intel ${MODEL:+model=$MODEL}"
if [[ -n "$MODEL" ]]; then
    modprobe snd_hda_intel model="$MODEL"
else
    modprobe snd_hda_intel
fi
sleep 3

report
start_audio

echo
echo "==> kernel fixup log line:"
journalctl -k --no-pager 2>/dev/null | grep -iE 'picked fixup|Detected mute LED' | tail -3 || true
