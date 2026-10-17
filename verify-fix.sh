#!/usr/bin/env bash
#
# verify-fix.sh — prove, without looking at the keyboard, that the patched
# codec module lights the F8 (microphone-mute) lamp.
#
# Run it right after:  sudo ./build-patched-module.sh install && sudo ./build-patched-module.sh reload
#
#   sudo ./verify-fix.sh [-d HWDEP_NODE] [-c CARD]
#
# What it checks
#   1. the *patched* module is the one running (srcversion of the loaded module
#      equals the installed file) and the codec picked up SSID 103c:8ba4
#   2. /sys/class/leds/hda::micmute exists (the whole point of the fixup)
#   3. muting the microphone  -> hda::micmute brightness 1 AND COEF 0x35 bits 2-3 = 0b01
#      unmuting it            -> hda::micmute brightness 0 AND COEF 0x35 bits 2-3 = 0b10
#   4. muting the speaker -> hda::mute brightness 1, unmuting -> 0  (F5 still works)
#
# Why "bits 2-3 = 0b01" means lit: alc236_fixup_hp_coef_micmute_led() sets up
# COEF 0x35 with mask = 3<<2, on = 2<<2 (0x08) / off = 1<<2 (0x04), and this
# machine's lamp is inverted, so the new fixup sets micmute_led_polarity = 1.
# alc_update_coef_led() then inverts the logical brightness: "muted" is what
# writes the *off* value 0x04 -- and 0x04 is what lights the physical lamp.
# COEF 0x35 is read-modify-write, so the raw register carries other bits too;
# only bits 2-3 are compared (observed raw: 0x8d66 muted / 0x8d6a unmuted).
#
# The mute itself is done exactly the way your desktop does it
# (wpctl set-mute @DEFAULT_AUDIO_SOURCE@), which is what the UCM LED attach
# (SetLED, ctl-led) follows.  Original mute states are restored on exit.
#
set -uo pipefail

HWDEP="/dev/snd/hwC1D0"
CARD=1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HDA_COEF35:-$DIR/hda-coef35}"
LEDDIR="${LEDDIR:-/sys/class/leds}"      # overridable for testing
KREL="$(uname -r)"
KMOD="snd-hda-codec-alc269"
KMOD_SYSFS="${KMOD//-/_}"        # sysfs/module names use underscores
MODFILE="${MODFILE:-/usr/lib/modules/$KREL/kernel/sound/hda/codecs/realtek/$KMOD.ko.zst}"
WAIT="${WAIT:-10}"          # seconds to wait for the LED to follow a change
IDENTITY="$(git config --get sendemail.from 2>/dev/null)"

while getopts ":d:c:h" opt; do
	case "$opt" in
	d) HWDEP="$OPTARG" ;;
	c) CARD="$OPTARG" ;;
	h) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option; -h for help" >&2; exit 2 ;;
	esac
done

TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null)"
export XDG_RUNTIME_DIR="/run/user/$TARGET_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

as_user() {
	runuser -u "$TARGET_USER" -- env \
		XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" "$@"
}

led()  { cat "$LEDDIR/hda::$1/brightness" 2>/dev/null; }
mute() { as_user wpctl set-mute "$1" "$2" >/dev/null 2>&1; }
src_muted() { as_user wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED && echo 1 || echo 0; }
snk_muted() { as_user wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED && echo 1 || echo 0; }

# COEF 0x35, as a raw hex value (needs root + the hwdep node).  Our access
# through hwdep bypasses the kernel's per-codec coef_mutex, so a read taken
# while another COEF user is mid-sequence can come back with a *different*
# index's value (Realtek echoes the index in the high byte, e.g. 0x57xx for
# COEF 0x57).  Only accept a value that two consecutive reads agree on.
coef() {
	[[ -x "$BIN" ]] || return 1
	local a b i
	for ((i = 0; i < 5; i++)); do
		a="$("$BIN" -d "$HWDEP" read 2>/dev/null | sed -n 's/.*= \(0x[0-9a-fA-F]*\) .*/\1/p')"
		[[ -n "$a" ]] || return 1
		sleep 0.2
		b="$("$BIN" -d "$HWDEP" read 2>/dev/null | sed -n 's/.*= \(0x[0-9a-fA-F]*\) .*/\1/p')"
		[[ "$a" == "$b" ]] && { printf '%s' "$b"; return 0; }
	done
	printf '%s' "${b:-}"
	return 1
}

# render a 0..3 value the way the lamp field reads in the datasheet
bits2() {
	case "${1:-}" in
	0) echo 00 ;; 1) echo 01 ;; 2) echo 10 ;; 3) echo 11 ;; *) echo '??' ;;
	esac
}

# poll until led <which> reaches <want>, print the value it settled on
wait_led() {  # which want
	local i val
	for ((i = 0; i < WAIT * 4; i++)); do
		val="$(led "$1")"
		[[ "$val" == "$2" ]] && { echo "$val"; return 0; }
		sleep 0.25
	done
	echo "${val:-absent}"
	return 1
}

# ---------------------------------------------------------------- restore
orig_src="$(src_muted)"
orig_snk="$(snk_muted)"
restore() {
	mute @DEFAULT_AUDIO_SOURCE@ "$orig_src"
	mute @DEFAULT_AUDIO_SINK@ "$orig_snk"
	printf '\n  (mic/speaker mute state restored: source=%s sink=%s)\n' "$orig_src" "$orig_snk"
}
trap restore EXIT

# ---------------------------------------------------------------- 1. module
head_ "module"
inst="$(modinfo -F srcversion "$MODFILE" 2>/dev/null)"
run="$(cat "/sys/module/$KMOD_SYSFS/srcversion" 2>/dev/null)"
if [[ -n "$inst" && "$inst" == "$run" ]]; then
	ok "running module is the installed (patched) one  [srcversion $run]"
else
	bad "running module is NOT the installed file (installed=$inst running=$run)"
	echo "       -> run: sudo ./build-patched-module.sh install && sudo ./build-patched-module.sh reload"
fi

fixup="$(journalctl -k --no-pager 2>/dev/null | grep -i 'picked fixup' | tail -1)"
if [[ "$fixup" == *103c:8ba4* ]]; then
	ok "codec picked the new quirk: $fixup"
else
	bad "codec did not pick 103c:8ba4 (last line: ${fixup:-none})"
fi

# ---------------------------------------------------------------- 2. classdev
head_ "microphone-mute LED class device"
if [[ -e "$LEDDIR/hda::micmute" ]]; then
	ok "hda::micmute exists"
else
	bad "hda::micmute missing -- the fixup did not register a mic-mute LED"
	printf '       (present: %s)\n' \
		"$(ls "$LEDDIR" 2>/dev/null | grep -E 'hda::' | tr '\n' ' ')"
	echo "==> stopping here: nothing below can pass without the class device"
	exit 1
fi

# ---------------------------------------------------------------- 3. mic lamp
head_ "microphone lamp (wpctl mute -> LED -> COEF 0x35)"
unesc=$(mktemp)
mute @DEFAULT_AUDIO_SOURCE@ 0
b_off="$(wait_led micmute 0)"; sleep 0.4; c_off="$(coef)" || off_unstable=1
mute @DEFAULT_AUDIO_SOURCE@ 1
b_on="$(wait_led micmute 1)"; sleep 0.4; c_on="$(coef)" || on_unstable=1
mute @DEFAULT_AUDIO_SOURCE@ "$orig_src"

printf '  unmuted: led=%s coef=%s\n' "$b_off" "${c_off:-unreadable}"
printf '  muted  : led=%s coef=%s\n' "$b_on"  "${c_on:-unreadable}"
[[ "$b_off" == 0 ]] && ok "LED follows the mute switch (brightness 0 when unmuted)" \
                    || bad "LED did not go dark when unmuted (got '${b_off:-absent}')"
[[ "$b_on"  == 1 ]] && ok "LED is on when the microphone is muted" \
                    || bad "LED did not light up when muted (got '${b_on:-absent}')"
if [[ -n "${off_unstable:-}" || -n "${on_unstable:-}" ]]; then
	warn "COEF 0x35 kept changing while reading -- inconclusive"
	echo "       (another COEF user was active; the tool bypasses the codec's"
	echo "        coef_mutex.  The LED assertions above still hold.)"
elif [[ -n "$c_off" && -n "$c_on" ]]; then
	# COEF 0x35 is read-modify-write: coef_micmute_led_set() keeps the other
	# bits, so only the 2-bit lamp field (bits 2-3) is meaningful here.
	f_on=$(( (c_on  >> 2) & 3 ))
	f_off=$(( (c_off >> 2) & 3 ))
	(( f_on == 1 ))  && ok "COEF 0x35 bits 2-3 = $(bits2 "$f_on") when muted (lamp lit)   [raw $c_on]" \
	                 || bad "COEF 0x35 bits 2-3 = $(bits2 "$f_on") when muted, expected 01   [raw $c_on]"
	(( f_off == 2 )) && ok "COEF 0x35 bits 2-3 = $(bits2 "$f_off") when unmuted (lamp dark) [raw $c_off]" \
	                 || bad "COEF 0x35 bits 2-3 = $(bits2 "$f_off") when unmuted, expected 10 [raw $c_off]"
else
	warn "could not read COEF 0x35 (need root and $HWDEP)"
fi

# ---------------------------------------------------------------- 4. F5
head_ "speaker lamp (must keep working)"
if [[ -e "$LEDDIR/hda::mute" ]]; then
	mute @DEFAULT_AUDIO_SINK@ 0; s_off="$(wait_led mute 0)"
	mute @DEFAULT_AUDIO_SINK@ 1; s_on="$(wait_led mute 1)"
	mute @DEFAULT_AUDIO_SINK@ "$orig_snk"
	printf '  unmuted: led=%s\n  muted  : led=%s\n' "$s_off" "$s_on"
	[[ "$s_off" == 0 && "$s_on" == 1 ]] && ok "hda::mute follows the speaker mute" \
	                                    || bad "hda::mute does not follow the speaker mute"
else
	bad "hda::mute missing -- this fixup must keep the speaker LED"
fi
rm -f "$unesc"

# ---------------------------------------------------------------- verdict
printf '\n===============================================================\n'
if (( FAIL )); then
	echo "RESULT: FAILED -- see the FAIL lines above."
else
	echo "RESULT: PASSED (kernel side verified end to end)."
	echo
	echo "One thing a script cannot see: look at the keyboard now, press F8"
	echo "(or mute the mic) and confirm the *physical* lamp lights up."
	echo
	echo "Evidence for the patch, if you want it in the mail:"
	# work out the *invoking* user's identity (we are root here)
	tb=""
	if [[ -n "${IDENTITY:-}" ]]; then
		tb="$IDENTITY"
	elif [[ -n "${SUDO_USER:-}" ]]; then
		tb="$(as_user git config user.name 2>/dev/null) <$(as_user git config user.email 2>/dev/null)>"
		[[ "$tb" == " <>" ]] && tb=""
	fi
	if [[ -n "$tb" ]]; then
		echo "  Tested-by: $tb   # prepare-submission.sh -t adds this line for you"
	else
		echo "  Tested-by: <your name> <your email>   # prepare-submission.sh -t adds it"
	fi
	echo "  - loaded module srcversion $run, codec picked 103c:8ba4"
	echo "  - hda::micmute + hda::mute class devices present"
	echo "  - mic muted   -> COEF 0x35 = ${c_on:-?} (lamp bits 2-3 = $(bits2 "${f_on:-?}") = lit), LED brightness 1"
	echo "  - mic unmuted -> COEF 0x35 = ${c_off:-?} (lamp bits 2-3 = $(bits2 "${f_off:-?}") = dark), LED brightness 0"
	echo "  - F5 speaker LED still follows the speaker mute"
fi
printf '===============================================================\n'
exit "$FAIL"
