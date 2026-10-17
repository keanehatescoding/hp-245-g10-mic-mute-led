#!/usr/bin/env python3
"""Apply the 103c:8ba4 microphone-mute-LED quirk to alc269.c.

The shipped 0001-*.patch is generated against current upstream master, so its
3-line context can include entries that do not exist yet in a release tree
(e.g. linux-7.2.9).  This script makes the same four insertions using
string anchors that have been stable for years, so it works on both:

  * a new fixup function        (next to alc233_fixup_lenovo_coef_micmute_led)
  * an enum entry               (next to ALC236_FIXUP_HP_MUTE_LED_MICMUTE_VREF)
  * a fixup definition          (next to the VREF variant)
  * the SND_PCI_QUIRK table line (right after the 0x8b97 entry)

Idempotent: exits 0 without touching the file if the quirk is already there.

usage: apply-quirk.py <path/to/sound/hda/codecs/realtek/alc269.c>
"""
import sys

FUNC = """/*
 * HP 245 14 inch G10 Notebook PC (SSID 103c:8ba4): the speaker mute LED is
 * controlled through the HP_Mute_LED DMI string (NID 0x1a), same as the
 * ALC269_FIXUP_HP_MUTE_LED fallback, but the microphone mute LED is wired to
 * COEF 0x35 bits 2-3 with an inverted sense.
 */
static void alc236_fixup_hp_mute_led_micmute_coef_inv(struct hda_codec *codec,
						      const struct hda_fixup *fix,
						      int action)
{
	struct alc_spec *spec = codec->spec;

	if (action == HDA_FIXUP_ACT_PRE_PROBE)
		spec->micmute_led_polarity = 1;

	alc269_fixup_hp_mute_led(codec, fix, action);
	alc236_fixup_hp_coef_micmute_led(codec, fix, action);
}

"""

FIXUP_DEF = """	[ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = alc236_fixup_hp_mute_led_micmute_coef_inv,
	},
"""

QUIRK_LINE = """	SND_PCI_QUIRK(0x103c, 0x8ba4, "HP 245 14 inch G10 Notebook PC",
		      ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV),
"""


def main():
	if len(sys.argv) != 2:
		print(__doc__)
		return 2
	path = sys.argv[1]
	src = open(path).read()

	if "ALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV" in src:
		print("apply-quirk: quirk already present, nothing to do")
		return 0

	# 1. the fixup function
	anchor = "static void alc233_fixup_lenovo_coef_micmute_led(struct hda_codec *codec,"
	if src.count(anchor) != 1:
		print("apply-quirk: function anchor not found", file=sys.stderr)
		return 1
	src = src.replace(anchor, FUNC + anchor, 1)

	# 2. the enum entry
	anchor = "\tALC236_FIXUP_HP_MUTE_LED_MICMUTE_VREF,\n"
	if src.count(anchor) != 1:
		print("apply-quirk: enum anchor not found", file=sys.stderr)
		return 1
	src = src.replace(
		anchor,
		"\tALC236_FIXUP_HP_MUTE_LED_MICMUTE_COEF_INV,\n" + anchor, 1)

	# 3. the fixup definition, right after the VREF variant
	anchor = """	[ALC236_FIXUP_HP_MUTE_LED_MICMUTE_VREF] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = alc236_fixup_hp_mute_led_micmute_vref,
	},
"""
	if src.count(anchor) != 1:
		print("apply-quirk: fixup definition anchor not found", file=sys.stderr)
		return 1
	src = src.replace(anchor, anchor + FIXUP_DEF, 1)

	# 4. the PCI quirk table entry (keeps numeric order: after 0x8b97)
	anchor = ('\tSND_PCI_QUIRK(0x103c, 0x8b97, "HP", '
		  'ALC236_FIXUP_HP_MUTE_LED_MICMUTE_VREF),\n')
	if src.count(anchor) != 1:
		print("apply-quirk: PCI table anchor not found", file=sys.stderr)
		return 1
	src = src.replace(anchor, anchor + QUIRK_LINE, 1)

	open(path, "w").write(src)
	print("apply-quirk: quirk applied to %s" % path)
	return 0


if __name__ == "__main__":
	sys.exit(main())
