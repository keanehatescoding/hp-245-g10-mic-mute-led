# HP 245 14" G10 — F8 microphone-mute LED fix

Everything here is diagnostic/test/repair material for one issue: the LED on
the F8 (mic mute) key never lights on this laptop.

## TL;DR

The mute itself works. The F8 LED is **codec-driven** — it is wired to
Realtek COEF `0x35` bits 2-3 — but this machine's lamp is **inverted**
relative to the one ALC236 fixup that uses that register, and the codec
SSID `103c:8ba4` is missing from the quirk table, so *no* mic-mute LED is
registered at all.

- Laptop: HP 245 14 inch G10 Notebook PC, board `8BA4`
- Codec: Realtek ALC236, codec SSID `103c:8ba4`, card1 (`hwC1D0`)
- The F8 key is delivered by `hp-wmi` (`WMI event 0x270 -> KEY_MICMUTE`),
  which your Hyprland bind turns into
  `wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle`.  That works: muting flips
  the ALSA control `Mic ACP LED Capture Switch` (card1 `numid=16`) from
  `on` to `off`.
- That control is created and bound by UCM, not by the codec:
  `/usr/share/alsa/ucm2/HDA/HDA.conf` lines 56-57 do
  `CtlNew { Arg="name='Mic ACP LED Capture Switch' …" }` and
  `SetLED { LED="mic" Action="attach" CtlId="Mic ACP LED Capture Switch" }`,
  i.e. *attach this control to the "mic" LED group* handled by
  `snd_ctl_led`.  The attachment needs a `hda::micmute` LED class device to
  exist — and on the stock driver it does not, which is why
  `/sys/class/sound/ctl-led/` is empty here and the lamp never moves.
- But `103c:8ba4` is not in `alc269_fixup_tbl[]`, so the driver falls back
  to the vendor-wide entry `ALC269_FIXUP_HP_MUTE_LED`, which only creates
  the **speaker** LED (`/sys/class/leds/hda::mute`).  No `hda::micmute`
  device exists, so nothing writes the mic LED COEF and the F8 lamp never
  reacts.

So the whole chain is: F8 key → `wpctl` → `Mic ACP LED Capture Switch`
(0/1) → UCM `SetLED` attach → LED class device → `coef_micmute_led_set()`
→ COEF `0x35` bits 2-3.  Only the class device is missing, and that is
exactly what the new quirk registers.  (Evidence: booting the driver with
the existing `103c:869d` entry — which also registers a `hda::micmute`
class device — made COEF `0x35` follow the microphone mute; the lamp just
came out inverted.)

The fix is a new quirk, `ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV`:

- speaker LED: as today, from the `HP_Mute_LED` DMI string (codec pin `0x1a`);
- mic LED: COEF `0x35` bits 2-3 with `micmute_led_polarity = 1` (inverted),
  which makes `alc_update_coef_led()` write the levels this hardware wants.

Patch: `0001-ALSA-hda-realtek-Add-mic-mute-LED-quirk-for-the-HP-245.patch`.

Three ways to use this directory:

| Goal | Do this |
|---|---|
| confirm the diagnosis in 5 minutes | `sudo ./hda-coef35 read` / `on` / `off` (Step 0) |
| have a working F8 lamp **now** | interim daemon: `sudo ./install-coef35-daemon.sh` (Step 2a — needs the state-source rework noted there) |
| run the real fix | build the module: `./build-patched-module.sh fetch …` (Step 2b), then submit (Step 3) |

## How the F8 lamp was identified

`/sys/class/leds/hda::mute`'s trigger list contains `audio-micmute`, so any
fixup that calls `snd_hda_gen_add_micmute_led_cdev()` gets a working
trigger; all that was missing was the wiring.  To find the wiring without
rebuilding the kernel we borrowed other HP fixups through the `model=`
SSID-alias mechanism (`test-model.sh` / `probe-led.sh`).

The decisive run was the alias `103c:869d`, i.e. `ALC236_FIXUP_HP_MUTE_LED`,
which drives the mic LED from COEF `0x35` bits 2-3 (values from
`alc236_fixup_hp_coef_micmute_led()`:

```c
spec->mic_led_coef.idx  = 0x35;
spec->mic_led_coef.mask = 3 << 2;
spec->mic_led_coef.on   = 2 << 2;   /* 0x08 */
spec->mic_led_coef.off  = 1 << 2;   /* 0x04 */
```

) and the speaker LED from COEF `0x34` bit 5.  Toggling one thing at a time
gave:

| STEP | speaker | mic | driver writes | F5 lamp | F8 lamp |
|------|---------|-----|---------------|---------|---------|
| 1 | unmuted | unmuted | mic COEF `0x35` = `0x04` (`off`) | off | **ON** |
| 2 | unmuted | **muted** | mic COEF `0x35` = `0x08` (`on`) | off | **OFF** |
| 3 | **muted** | unmuted | mic COEF `0x35` = `0x04`, spk COEF `0x34` bit 5 | off (COEF `0x34` bit 5 does **not** drive it) | **ON** |

(Those raw `0x04` / `0x08` values were read on a freshly reset codec, where the
neighbouring bits of `0x35` happened to be zero.  The COEF is written
read-modify-write, so on a live system the same lamp field sits inside a larger
value — after the patched module loads here the raw register reads `0x8d66`
when muted and `0x8d6a` when unmuted.  Only bits 2-3 are the lamp.)

So the lamp follows COEF `0x35` bits 2-3, but with the opposite sense of the
kernel's ALC236 mic-LED code: `1 << 2` lights the lamp, `2 << 2` turns it
off.  The kernel can be told this with `spec->micmute_led_polarity = 1`:

```c
/* alc269.c */
static void alc_update_coef_led(struct hda_codec *codec, struct alc_coef_led *led,
				bool polarity, bool on)
{
	if (polarity)
		on = !on;
	alc_update_coef_idx(codec, led->idx, led->mask, on ? led->on : led->off);
}
```

The same idiom is already used for HP machines with an active-low mic LED
(e.g. `alc236_fixup_hp_mute_led_micmute_gpio()`, and the newest sibling
quirk `alc236_fixup_hp_15_fd0xxx()` for SSID `103c:8bb6`).

The F5 (speaker) lamp is a different lamp on codec pin `0x1a`, which is what
the DMI string `HP_Mute_LED_0_C` parses to (`pin 0x0c - 0x0a + 0x18`), and
what the current fallback already drives — that is why the alias
`103c:8b65` (mic LED -> VREF pin `0x1a`) lit the **F5** lamp when the *mic*
was muted.  `103c:8bb6`'s fixup uses pin `0x1a` for the speaker lamp too, so
the mapping is confirmed from two directions.

### Negative results (all ruled out)

- `hp-wmi` has no LED support: it only maps the key
  (`{ KE_KEY, 0x270, { KEY_MICMUTE } }`).
- No ACPI/EC mic-LED method: `strings /sys/firmware/acpi/tables/DSDT`
  contains no `MLED`/mic-LED object (only `PLED`, `SMIC`).
- `Mic ACP LED Capture Switch` is a *virtual* control created by UCM
  (`CtlNew` in `/usr/share/alsa/ucm2/HDA/HDA.conf:56`, exposed as card1
  `numid=16`, write-only), not a hardware mixer; card2 (`acp`) exposes 0
  controls.  It is the control that gets `SetLED`-attached to the HDA mic LED
  (see the chain in TL;DR) — the codec-level truth is that muting moves this
  control and nothing else on card1 (verified by diffing `amixer -c1 contents`
  around a `wpctl set-mute`).
- Aliases tried with `probe-led.sh`, none of which lit F8 while muting the
  mic: `103c:8b65`, `103c:85f1`, `103c:8b34`, `103c:84a6`, `103c:1586`
  (speaker LED -> pin `0x19`), `103c:8497` (speaker LED -> pin `0x1b`).
  Pin `0x19`/`0x1b` therefore do not drive the F8 lamp (in those runs the
  lamp just kept whatever COEF `0x35` state it was left in, because nothing
  wrote it).

## Files

| File | Purpose |
|---|---|
| `0001-ALSA-hda-realtek-Add-mic-mute-LED-quirk-for-the-HP-245.patch` | upstream kernel patch (the real fix) |
| `prepare-submission.sh` | rebuild the patch with your real `From:`/`Signed-off-by:`/`Tested-by:` + run checkpatch |
| `apply-quirk.py` | string-anchored applier (same 4 insertions) used when the patch's context does not match an older release tree |
| `build-patched-module.sh` | staged build/install/revert of the patched module |
| `verify-fix.sh` | after install+reload: asserts the LED + COEF follow the mic mute (pass/fail) |
| `src/alc269.c` | `sound/hda/codecs/realtek/alc269.c` with the patch applied |
| `src/alc269.c.upstream` | pristine upstream file the patch applies to |
| `hda-coef35.c` / `hda-coef35` | userspace tool: read/light/extinguish the F8 lamp, or follow the mute state |
| `hda-coef35.service` | systemd unit for the interim daemon |
| `install-coef35-daemon.sh` | build + enable the interim daemon (`--uninstall` to remove) |
| `smtp-test.py` | check the Gmail app password `git send-email` uses (STARTTLS + AUTH PLAIN, raw reply) |
| `probe-led.sh` | guided single-variable LED probe (reload + STEP1/2/3) |
| `test-model.sh` | reload `snd_hda_intel` with a candidate fixup alias, no reboot |
| `hda-mic-led.conf` | modprobe override (test only) — see the findings inside |

## Step 0 — prove the wiring directly (5 minutes)

`hda-coef35` talks to the codec through `/dev/snd/hwC1D0` (the same interface
`hda-verb` uses, but with a masked read-modify-write).  The hwdep node is
`root:audio`, so run it as root:

```bash
cd ~/hda-mic-led
./hda-coef35 --help                 # no root needed
sudo ./hda-coef35 read              # e.g. "COEF 0x35 = 0x8d66 (bits 2-3 = 0b01) -> F8 lamp ON"
sudo ./hda-coef35 off               # F8 lamp goes dark
sudo ./hda-coef35 on                # F8 lamp lights up
sudo ./hda-coef35 selftest          # read, light, extinguish, restore
```

Expected: bits 2-3 = `01` means **lamp on**, `10` means **lamp off** — i.e. the
inverse of what the kernel's `alc236_fixup_hp_coef_micmute_led()` writes.  Only
bits 2-3 are decoded; the raw value additionally carries unrelated bits of
COEF `0x35` (`0x8d66` muted / `0x8d6a` unmuted on this machine).

Equivalent with `alsa-tools` (`hda-verb`), if you prefer the packaged tool:

```bash
sudo pacman -S alsa-tools
sudo hda-verb /dev/snd/hwC1D0 0x20 SET_COEF_INDEX 0x35
sudo hda-verb /dev/snd/hwC1D0 0x20 GET_PROC_COEF   0      # read current value
sudo hda-verb /dev/snd/hwC1D0 0x20 SET_PROC_COEF   0x0004 # -> F8 lamp ON
sudo hda-verb /dev/snd/hwC1D0 0x20 SET_PROC_COEF   0x0008 # -> F8 lamp OFF
```

Note: COEF registers survive module reloads, so after the `103c:869d`
experiment the lamp can stay lit until the codec is reset (reboot).
`hda-coef35 read` always shows the live value.

## Step 1 — reproduce the diagnosis (optional)

`model=` is an **array of charp indexed by HDA controller**, and
`snd_hda_intel` assigns the indices in PCI probe order
(`find_first_zero_bit(probed_devs, ...)`), passing only `model[dev]` to
that controller via `azx_bus_init()`.  The HDMI controller (03:00.1)
probes first on this laptop, so the ALC236 (03:00.6) is index 1 — a bare
`model=VVVV:DDDD` never reaches it.  `test-model.sh` therefore fans a bare
alias out to four controller slots; that is why earlier runs still logged
`picked fixup  for PCI SSID 103c:0000` (the fallback).

```bash
sudo ~/hda-mic-led/probe-led.sh --restore     # baseline: F8 does not react
sudo ~/hda-mic-led/probe-led.sh 103c:869d     # F8 lamp now INVERTED
```

## Step 2a — working F8 lamp *now*, without a kernel patch (interim daemon)

**Status: needs a rework before it works on this machine** — see the caveat
at the end of this section.  If you are taking the kernel route (Step 2b),
skip this.

The daemon follows `/sys/class/sound/ctl-led/mic/*/brightness` (1 while the
microphone is muted) and writes COEF `0x35` bits 2-3 accordingly, every
200 ms, with a periodic re-write so it also survives resume:

```bash
sudo ~/hda-mic-led/install-coef35-daemon.sh
# ... press the mic-mute key; the F8 lamp should light while muted
sudo ~/hda-mic-led/install-coef35-daemon.sh --uninstall   # to remove it
```

It is a workaround, not a fix, and must run as root.  Do **not** combine it
with the `103c:869d` alias (the kernel fixup and the daemon would both write
COEF `0x35`).  `build-patched-module.sh install` stops it automatically.

**Once the patched module is in the running kernel, remove the daemon** — it is
still `enabled`, so it would come back at the next boot and fight the kernel
over COEF `0x35` (and it reaches the codec through hwdep, bypassing the
codec's `coef_mutex`):

```bash
sudo systemctl disable --now hda-coef35.service
sudo ~/hda-mic-led/install-coef35-daemon.sh --uninstall   # removes it entirely
```

Caveat: the daemon's state source is the `ctl-led/mic` brightness file, which
is part of the same attachment that the missing quirk breaks — without a
`hda::micmute` class device there is nothing for UCM's `SetLED` to attach, so
`/sys/class/sound/ctl-led/` stays empty here (`snd_ctl_led` is loaded, the
card just has no mic LED).  To make the interim daemon work it has to read a
state it *can* see: `wpctl get-volume @DEFAULT_AUDIO_SOURCE@` as the desktop
user (`Mic ACP LED Capture Switch` itself is write-only, `access=rw----W-`).
That is a small change to `hda-coef35`'s follow loop.

## Step 2b — run the real fix: build the patched module

The Arch/CachyOS `linux-cachyos-headers` package ships only `Kconfig` /
`Makefile` files under `sound/`, so the module cannot be rebuilt from the
headers alone; the source tree for `7.2.9-2-cachyos` is needed.  The script
does one module directory only (not a whole kernel), against the running
kernel's `.config` and `Module.symvers`, so the result loads into the
running kernel:

```bash
cd ~/hda-mic-led
./build-patched-module.sh fetch          # kernel.org linux-7.2.9 + .config
./build-patched-module.sh patch          # apply 0001-*.patch
./build-patched-module.sh build          # modules_prepare + build the module
sudo ./build-patched-module.sh install   # back up + install + depmod
sudo ./build-patched-module.sh reload    # reload snd_hda_intel, report
sudo ./verify-fix.sh                     # automatic pass/fail on the LED + COEF
./build-patched-module.sh status         # what is installed / what the LEDs do
sudo ./build-patched-module.sh revert    # restore the stock module
```

`verify-fix.sh` does the checking for you: it confirms the *patched* module is
the one running (srcversion), that the codec picked `103c:8ba4`, that
`hda::micmute` exists, then mutes/unmutes the microphone and the speaker via
`wpctl` and asserts

```
mic muted   -> /sys/class/leds/hda::micmute/brightness = 1, COEF 0x35 bits 2-3 = 01 (lamp lit)
mic unmuted -> /sys/class/leds/hda::micmute/brightness = 0, COEF 0x35 bits 2-3 = 10 (lamp dark)
speaker     -> hda::mute still follows the speaker mute (F5 keeps working)
```

and restores your original mute state on exit.  Only the physical lamp needs
your eyes.

What to look for after `reload`:

```
kernel: snd_hda_codec_alc269 hdaudioC1D0: ALC236: picked fixup  for PCI SSID 103c:8ba4
                                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                       was 103c:0000 before
$ ls /sys/class/leds/ | grep hda
hda::mute        <- F5 (speaker), as before
hda::micmute     <- F8 (microphone), NEW
```

then press F5 / F8: each lamp should follow its own mute state.

Two gotchas worth knowing (and worth mentioning in the commit message if a
maintainer asks you to re-test):

(1) A plain `modprobe -r snd_hda_intel` does **not** unload
`snd_hda_codec_alc269`.  The codec module keeps running its old code, so a
freshly installed `snd-hda-codec-alc269.ko` is silently ignored and you still
see the old quirk being picked.  `test-model.sh` therefore drops the codec stack
(`snd_hda_codec_alc269`, `..._realtek_lib`, `..._generic`, `snd_hda_codec`)
after unloading `snd_hda_intel`; `reload` then compares the running
`srcversion` against the installed one and tells you if the old module somehow
survived (in which case: reboot).

(2) The COEF check is inherently racy from userspace.  The kernel serialises its
own COEF accesses with a per-codec `coef_mutex`, but `hda-coef35` talks to the
codec through `/dev/snd/hwC1D0` and bypasses that mutex.  If another COEF user
is mid-sequence, our `SET_COEF_INDEX` can land between its index-select and its
`SET_PROC_COEF`, and `GET_PROC_COEF` then returns a *different* index's value —
Realtek echoes the index in the high byte, so COEF `0x57` comes back as `0x57xx`.
That is exactly how a read of `0x5757` appeared once during testing.
`hda-coef35 read` and `verify-fix.sh` therefore only trust a value that two
consecutive reads agree on, and the verifier reports `SKIP (inconclusive)`
rather than a bogus FAIL if the register will not settle.

This machine
is built with `CONFIG_CC_IS_CLANG=y` + `CONFIG_LTO_CLANG_THIN=y`, so the
build needs `clang`, `ld.lld`, `llvm-ar` and `pahole` (all present here).
The download is 153 MB and the extracted tree ~1.6 GB.  The build is done
with the running kernel's `.config`, so the module's vermagic comes out as
`7.2.9-2-cachyos SMP preempt mod_unload`, identical to the stock one (checked
— a local clang 23.1.3 vs the 23.1.1 the kernel was built with is only
warned about, not an error).  Module signature is not enforced
(`CONFIG_MODULE_SIG_FORCE` is unset), so the unsigned rebuilt module loads;
BTF for the module is skipped because the headers ship no `vmlinux`.

The patch file is generated against current upstream master, so on a release
tree it can hit context lines that do not exist yet (checked: `git apply`
fails on upstream `v7.2.9`, because that tree has no
`ALC236_FIXUP_HP_15_FD0XXX` / `0x8ba9` entries).  The `patch` stage handles
that automatically: it tries `git apply` first, and otherwise runs
`apply-quirk.py`, which makes the identical four insertions using anchors
that are years old (verified: the result is byte-identical to the patched
master file, and the table entry still lands right after `0x8b97`).

Caveat: `fetch` downloads the *upstream* 7.2.9 tree, which does not contain
CachyOS's own patches.  If the built module is rejected at load time
(`unknown symbol` / version mismatch) or behaves oddly, use their source
tree instead:

```bash
git clone --depth=1 https://github.com/CachyOS/linux-cachyos
cd linux-cachyos && makepkg -o        # downloads+prepares their src/linux-*
SRC=.../src/linux-* ~/hda-mic-led/build-patched-module.sh build
```

## Notes / caveats

- The quirk borrows the speaker-LED handling from the DMI string, i.e. the
  exact code path the driver uses today for this machine (`hda::mute` ->
  pin `0x1a`).  If a BIOS lacks `HP_Mute_LED_*`, no speaker LED is
  registered — same as the current fallback.
- `alc_update_coef_idx()` (kernel) and `hda-coef35` both do a
  read-modify-write on COEF `0x35`, so bits other than 2-3 are preserved.
- Nothing here modifies the running system until you install the modprobe
  file, run a test script as root, install the daemon or install the module.
