#!/usr/bin/env bash
#
# build-patched-module.sh — build snd-hda-codec-alc269 with the 103c:8ba4
# microphone-mute-LED quirk and install it over the running kernel's module.
#
# Usage (each stage is separate on purpose — inspect the output as you go):
#
#   ./build-patched-module.sh fetch     # download+extract the kernel source
#   ./build-patched-module.sh patch     # apply 0001-*.patch
#   ./build-patched-module.sh build     # modules_prepare + build the module
#   sudo ./build-patched-module.sh install   # back up + install + depmod
#   sudo ./build-patched-module.sh reload    # reload snd_hda_intel, report
#   ./build-patched-module.sh status    # what is installed / what the LEDs do
#   sudo ./build-patched-module.sh revert    # restore the original module
#
# Environment overrides:
#   SRC=<dir>        use an existing kernel source tree (skips `fetch`)
#   WORK=<dir>       scratch dir (default /var/tmp/hda-module-build)
#   SRC_URL=<url>    source tarball to download (default kernel.org for the
#                    running kernel's version)
#
# What this does NOT do: build a whole kernel.  It only builds the one module
# directory, against the running kernel's own .config / Module.symvers, so the
# result loads into the running kernel.  The kernel is built with clang +
# ThinLTO here, so clang, ld.lld, llvm-ar and pahole must be installed
# (they are on this machine).
#
set -euo pipefail

KREL="$(uname -r)"
KBUILD="/usr/lib/modules/$KREL/build"
KVER="$(make -s -C "$KBUILD" kernelversion)"
KREL_LOCAL="${KREL#$KVER}"            # e.g. "-2-cachyos"
KMODDIR="sound/hda/codecs/realtek"
KMOD="snd-hda-codec-alc269.ko"
MODPATH="/usr/lib/modules/$KREL/kernel/$KMODDIR/$KMOD.zst"

WORK="${WORK:-/var/tmp/hda-module-build}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$(ls "$DIR"/0001-ALSA-hda-realtek-*.patch | head -1)"
SRC="${SRC:-$WORK/linux-$KVER}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "this stage needs root: sudo $0 $1"; }
need_src()  { [[ -f "$SRC/$KMODDIR/alc269.c" ]] || die "no source tree at $SRC (run 'fetch' first)"; }

[[ -d "$KBUILD" ]] || die "$KBUILD not found — install linux-cachyos-headers"

# ---------------------------------------------------------------- fetch
stage_fetch() {
	[[ -d "$SRC" ]] && { log "source tree already present: $SRC"; return; }

	local maj="${KVER%%.*}"
	local url="${SRC_URL:-https://cdn.kernel.org/pub/linux/kernel/v${maj}.x/linux-${KVER}.tar.xz}"

	log "kernel release : $KREL"
	log "kernel version : $KVER (localversion '$KREL_LOCAL')"
	log "fetching       : $url"
	mkdir -p "$WORK"
	curl -fL --retry 3 --retry-delay 2 -o "$WORK/linux-$KVER.tar.xz" "$url" \
		|| die "download failed — pass SRC_URL= or SRC= to use another tree"
	log "extracting to $WORK"
	tar -C "$WORK" -xf "$WORK/linux-$KVER.tar.xz"
	[[ -d "$SRC" ]] || die "unexpected tarball layout (no $SRC)"

	log "copying the running kernel's .config and Module.symvers"
	cp "$KBUILD/.config" "$SRC/.config"
	[[ -f "$KBUILD/Module.symvers" ]] && cp "$KBUILD/Module.symvers" "$SRC/Module.symvers"

	log "fetch done"
	echo "    tree: $SRC"
	echo "    note: this is an unpatched upstream tree; the CachyOS kernel"
	echo "          patches are not in it.  If the built module refuses to"
	echo "          load, use the CachyOS source instead (SRC=/path/to/their/tree)."
}

# ---------------------------------------------------------------- patch
stage_patch() {
	need_src
	if grep -q ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV "$SRC/$KMODDIR/alc269.c"; then
		log "quirk already applied in $SRC — nothing to do"
		return
	fi
	log "applying $(basename "$PATCH_FILE")"
	# The shipped patch is against current upstream master; its 3-line
	# context can mention entries that a release tree does not have yet
	# (e.g. linux-7.2.9), so fall back to a string-anchored applier that
	# makes the identical four insertions in the right places.
	# (Do not use 'patch --fuzz': it silently moves the table entry.)
	if ( cd "$SRC" && git apply "$PATCH_FILE" ) 2>/dev/null; then
		echo "    applied with git apply"
	elif python3 "$DIR/apply-quirk.py" "$SRC/$KMODDIR/alc269.c"; then
		echo "    applied with apply-quirk.py (string-anchored fallback)"
	else
		die "could not apply the patch to $SRC/$KMODDIR/alc269.c"
	fi
	grep -q ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV "$SRC/$KMODDIR/alc269.c" \
		|| die "patch applied but the quirk is not in the file"
	log "patch applied"
}

# ---------------------------------------------------------------- build
stage_build() {
	need_src
	(( EUID == 0 )) || warn "building as a user is fine; 'install' needs root"
	cd "$SRC"
	log "olddefconfig (keeps the running kernel's options)"
	make -s olddefconfig
	log "modules_prepare (LOCALVERSION=$KREL_LOCAL)"
	make -s modules_prepare LOCALVERSION="$KREL_LOCAL"
	log "building $KMODDIR"
	make -j"$(nproc)" M="$KMODDIR" modules LOCALVERSION="$KREL_LOCAL"
	[[ -f "$SRC/$KMODDIR/$KMOD" ]] || die "build finished but $KMOD is missing"
	log "built:"
	ls -l "$SRC/$KMODDIR/$KMOD"
	modinfo -F vermagic "$SRC/$KMODDIR/$KMOD" 2>/dev/null | sed 's/^/    vermagic: /'
	echo "    expected: $(cat "$KBUILD/include/config/kernel.release")"
}

# ---------------------------------------------------------------- install
stage_install() {
	need_root install
	need_src
	local built="$SRC/$KMODDIR/$KMOD"
	[[ -f "$built" ]] || die "$built missing (run 'build' first)"
	[[ -f "$MODPATH" ]] || die "$MODPATH not found — unexpected kernel layout"

	# stop the interim userspace daemon if it is running (it would fight
	# with the kernel over COEF 0x35)
	if systemctl is-active --quiet hda-coef35.service 2>/dev/null; then
		log "stopping the interim hda-coef35 daemon"
		systemctl stop hda-coef35.service || true
	fi
	if systemctl is-enabled --quiet hda-coef35.service 2>/dev/null; then
		warn "the interim daemon is still ENABLED (it will start at the next boot)"
		echo "    it would fight the patched kernel over COEF 0x35, and it"
		echo "    bypasses the codec's coef_mutex.  Disable it:"
		echo "      sudo systemctl disable --now hda-coef35.service"
	fi

	# A leftover 'model=' override beats the fixup table and applies to
	# whichever controller probes first, so it can stop the new quirk from
	# being selected at boot.  Warn about any that are still present.
	for f in /etc/modprobe.d/*.conf; do
		[[ -e "$f" ]] || continue
		grep -qsE '^[[:space:]]*options[[:space:]]+snd[-_]hda[-_]intel.*model=' "$f" || continue
		warn "$f forces model= on snd-hda-intel"
		echo "    that bypasses the fixup table (and may hit the ALC236) — remove it:"
		echo "      sudo rm $f && sudo mkinitcpio -P"
	done

	if ! ls "$WORK"/snd-hda-codec-alc269.ko.zst.orig-* >/dev/null 2>&1; then
		mkdir -p "$WORK"
		log "backing up the current module to $WORK/"
		cp -a "$MODPATH" "$WORK/$KMOD.zst.orig-$(date +%Y%m%d-%H%M%S)"
	fi
	log "installing the patched module (zstd)"
	zstd -19 -T0 -f -q "$built" -o "$MODPATH"
	chmod 0644 "$MODPATH"
	chown root:root "$MODPATH"
	depmod -a "$KREL"
	log "installed: $MODPATH"
	ls -l "$MODPATH" "$WORK"/$KMOD.zst.orig-*
	echo "    next: sudo $0 reload"
}

# ---------------------------------------------------------------- reload
stage_reload() {
	need_root reload
	log "reloading snd_hda_intel (audio drops for a few seconds)"
	"$DIR/test-model.sh" --restore

	# an already-loaded module keeps its old code -- make sure ours is the one running
	local want have
	want="$(modinfo -F srcversion "$MODPATH" 2>/dev/null)"
	have="$(cat "/sys/module/${KMOD//-/_}/srcversion" 2>/dev/null)"
	if [[ -n "$want" && "$want" != "$have" ]]; then
		warn "the running codec module is still the OLD one"
		echo "    running=${have:-none}  installed=$want"
		echo "    the unload could not drop it — reboot, then: sudo $0 status"
	fi

	log "kernel fixup line for the codec:"
	journalctl -k --no-pager 2>/dev/null | grep -i 'picked fixup' | tail -3 || true
	echo "    expected: 'picked fixup ... 103c:8ba4' (was 103c:0000)"
	log "LED devices:"
	ls /sys/class/leds/ | grep hda || true
	echo "    expected: hda::mute  AND  hda::micmute"
	echo
	echo "    now test:  F5 (speaker mute) should light the F5 lamp,"
	echo "               F8 (mic mute)      should light the F8 lamp."
}

# ---------------------------------------------------------------- status
stage_status() {
	log "running kernel: $KREL   (kernel release file: $(cat "$KBUILD/include/config/kernel.release"))"
	if [[ -f "$MODPATH" ]]; then
		log "installed module: $MODPATH"
		ls -l "$MODPATH"
		modinfo "$MODPATH" | grep -E '^(filename|vermagic|srcversion)' | sed 's/^/    /'
	else
		warn "$MODPATH not found"
	fi
	log "backups"
	ls -l "$WORK"/$KMOD.zst.orig-* 2>/dev/null || echo "    (none)"
	log "LED devices"
	ls /sys/class/leds/ | grep hda || echo "    (no hda:: LEDs)"
	log "module in use by the codec"
	modinfo -F srcversion "$MODPATH" 2>/dev/null > "$WORK/.want" || true
	modinfo -F srcversion snd-hda-codec-alc269 2>/dev/null > "$WORK/.have" || true
	if [[ -s "$WORK/.want" && -s "$WORK/.have" ]]; then
		if diff -q "$WORK/.want" "$WORK/.have" >/dev/null; then
			echo "    running srcversion matches the installed file"
		else
			echo "    running srcversion DIFFERS from the installed file (reload needed)"
		fi
	fi
	log "fixup line"
	journalctl -k --no-pager 2>/dev/null | grep -i 'picked fixup' | tail -2 || true
	if [[ -x "$DIR/hda-coef35" ]]; then
		log "current COEF 0x35 (if permitted)"
		"$DIR/hda-coef35" read 2>&1 | sed 's/^/    /' || true
	fi
}

# ---------------------------------------------------------------- revert
stage_revert() {
	need_root revert
	local backup
	backup="$(ls -t "$WORK"/$KMOD.zst.orig-* 2>/dev/null | head -1 || true)"
	[[ -n "$backup" ]] || die "no backup found in $WORK/"
	log "restoring $backup"
	cp -a "$backup" "$MODPATH"
	chmod 0644 "$MODPATH"
	depmod -a "$KREL"
	log "restored"
	ls -l "$MODPATH"
	echo "    (run '$0 reload' to go back to the stock module, and"
	echo "     'systemctl start hda-coef35.service' if you use the daemon)"
}

case "${1:-}" in
	fetch)   stage_fetch ;;
	patch)   stage_patch ;;
	build)   stage_build ;;
	install) stage_install ;;
	reload)  stage_reload ;;
	status)  stage_status ;;
	revert)  stage_revert ;;
	*)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
esac
