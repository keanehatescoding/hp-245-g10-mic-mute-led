#!/usr/bin/env bash
#
# install-coef35-daemon.sh — build and enable the interim userspace daemon that
# makes the F8 microphone-mute LED work on the HP 245 14 inch G10 (103c:8ba4)
# *before* the kernel quirk is available.
#
# Usage:
#   sudo ./install-coef35-daemon.sh              # build + enable + start
#   sudo ./install-coef35-daemon.sh --uninstall  # stop + remove
#
# The daemon writes ALC236 COEF 0x35 bits 2-3 through /dev/snd/hwC1D0
# (masked read-modify-write, so the other bits are untouched) and follows
# /sys/class/sound/ctl-led/mic/*/brightness, which is 1 while the microphone
# is muted.
#
# It is a workaround, not a fix: remove it when the patched kernel module
# (0001-ALSA-hda-realtek-Add-mic-mute-LED-quirk-for-the-HP-245.patch) is in
# your kernel.  build-patched-module.sh stops it automatically on install.
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/hda-coef35
UNIT=/etc/systemd/system/hda-coef35.service

[[ $EUID -eq 0 ]] || { echo "run me as root: sudo $0 ${1:-}" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
	systemctl disable --now hda-coef35.service 2>/dev/null || true
	rm -f "$UNIT" "$BIN"
	systemctl daemon-reload
	echo "removed $UNIT and $BIN"
	exit 0
fi

command -v gcc >/dev/null || { echo "gcc is required" >&2; exit 1; }
[[ -f "$DIR/hda-coef35.c" ]] || { echo "$DIR/hda-coef35.c not found" >&2; exit 1; }

echo "==> building $BIN"
gcc -O2 -Wall -Wextra -o "$BIN" "$DIR/hda-coef35.c"
chown root:root "$BIN"
chmod 0755 "$BIN"

echo "==> installing $UNIT"
install -m 0644 "$DIR/hda-coef35.service" "$UNIT"

echo "==> quick check before enabling it"
echo "    COEF 0x35 now: $("$BIN" read || true)"
echo "    mic state now: $(cat /sys/class/sound/ctl-led/mic/card1/brightness 2>/dev/null || echo '?')  (1 = muted)"

systemctl daemon-reload
systemctl enable --now hda-coef35.service
sleep 1
systemctl --no-pager --lines=5 status hda-coef35.service || true

echo
echo "==> test it: press your mic-mute key (or 'wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle')"
echo "    the F8 lamp should light while the microphone is muted."
echo
echo "    undo with: sudo $0 --uninstall"
