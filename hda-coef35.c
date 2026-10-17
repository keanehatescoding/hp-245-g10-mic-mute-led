/*
 * hda-coef35.c — read/write the microphone-mute LED of the HP 245 14 inch G10
 *                (Realtek ALC236, codec SSID 103c:8ba4) from userspace.
 *
 * The F8 (microphone mute) lamp on this laptop is driven by COEF 0x35 bits
 * 2-3, with an inverted sense compared to what the kernel's ALC236 mic-mute
 * LED fixups assume:
 *
 *     bits 2-3 = 01  ->  lamp ON    (value 0x04)
 *     bits 2-3 = 10  ->  lamp OFF   (value 0x08)
 *
 * The kernel only writes that COEF when a microphone mute LED class device
 * exists, which requires the fixup added by
 * 0001-ALSA-hda-realtek-Add-mic-mute-LED-quirk-for-the-HP-245.patch.  Until
 * that patch is in the running kernel, this tool can:
 *
 *   - prove the wiring by hand        (read / on / off / state)
 *   - act as an interim daemon        (follow)
 *
 * It talks to the HDA codec through /dev/snd/hwC1D0, the same interface
 * hda-verb(1) uses, so it needs write access to that node (root).
 *
 * Build:  gcc -O2 -Wall -o hda-coef35 hda-coef35.c
 * Usage:  ./hda-coef35 --help
 *
 * Reading COEF 0x35 is a read-modify-write, other bits are preserved.
 * Do not run this while a kernel fixup that drives COEF 0x35 is active
 * (e.g. the 103c:869d model alias) — the two would fight over the bits.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* from include/sound/hda_hwdep.h */
struct hda_verb_ioctl {
	uint32_t verb;	/* HDA_VERB(nid, verb, param) */
	uint32_t res;	/* response */
};
#define HDA_IOCTL_VERB_WRITE _IOWR('H', 0x11, struct hda_verb_ioctl)

#define HDA_VERB(nid, verb, param) (((nid) << 24) | ((verb) << 8) | (param))

/* from include/sound/hda_verbs.h */
#define AFG			0x20
#define VERB_SET_COEF_INDEX	0x500
#define VERB_SET_PROC_COEF	0x400
#define VERB_GET_PROC_COEF	0xc00

/* the F8 lamp */
#define MIC_LED_IDX		0x35
#define MIC_LED_MASK		0x0c	/* bits 2-3 */
#define MIC_LED_ON		0x04	/* bits 2-3 = 01 */
#define MIC_LED_OFF		0x08	/* bits 2-3 = 10 */

/* 1 = the microphone is muted */
static const char *state_files[] = {
	"/sys/class/sound/ctl-led/mic/card1/brightness",
	"/sys/class/sound/ctl-led/mic/brightness",
	NULL,
};

static const char *dev = "/dev/snd/hwC1D0";
static int fd = -1;
static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static void usage(void)
{
	printf(
"hda-coef35 — control the HP 245 G10 (103c:8ba4) microphone-mute LED\n"
"\n"
"usage: hda-coef35 [-d DEV] COMMAND [ARGS]\n"
"\n"
"commands:\n"
"  read            read COEF 0x35 and decode the lamp bits\n"
"  on              light the F8 lamp\n"
"  off             extinguish the F8 lamp\n"
"  state 0|1       lamp off for 0 (mic unmuted), on for 1 (mic muted)\n"
"  follow [MS]     daemon: mirror ctl-led/mic brightness every MS ms\n"
"                  (default 200); needs root, used by the systemd unit\n"
"  selftest        read, light the lamp, restore, report\n"
"\n"
"options:\n"
"  -d DEV          hwdep node (default /dev/snd/hwC1D0; the ALC236 is\n"
"                  codec 0 of card 1 on this laptop)\n"
"  -h              this help\n"
"\n"
"examples:\n"
"  sudo ./hda-coef35 read     # e.g. bits 2-3 = 0b01 -> lamp ON, 0b10 -> lamp OFF\n"
"  sudo ./hda-coef35 on       # F8 lamp lights up\n"
"  sudo ./hda-coef35 off      # F8 lamp goes dark\n"
"  sudo ./hda-coef35 follow & # interim fix: lamp follows the mic mute\n");
}

static int hda_verb(uint32_t verb, uint32_t *res)
{
	struct hda_verb_ioctl arg;

	arg.verb = verb;
	arg.res = 0;
	if (ioctl(fd, HDA_IOCTL_VERB_WRITE, &arg) < 0)
		return -1;
	if (res)
		*res = arg.res;
	return 0;
}

/* set the COEF index and read the value back (kernel: alc_read_coefex_idx) */
static int coef_read(unsigned int idx, unsigned int *val)
{
	uint32_t res;

	if (hda_verb(HDA_VERB(AFG, VERB_SET_COEF_INDEX, idx), NULL) < 0)
		return -1;
	if (hda_verb(HDA_VERB(AFG, VERB_GET_PROC_COEF, 0), &res) < 0)
		return -1;
	*val = res & 0xffff;
	return 0;
}

/*
 * The kernel serialises its own COEF accesses with a per-codec coef_mutex,
 * but we reach the codec through hwdep and bypass it.  If another COEF user
 * is mid-sequence (jack detect, the mic-VREF setup, the codec's own runtime
 * PM), our SET_COEF_INDEX can land between its index-select and its
 * SET_PROC_COEF, and GET_PROC_COEF then returns a *different* index's value
 * -- Realtek echoes the index in the high byte, so e.g. COEF 0x57 reads back
 * as 0x57xx.  Only trust a value that two consecutive reads agree on.
 * Returns 0 if stable, 1 if the value kept changing (val is then the last
 * one read), -1 on error.
 */
static int coef_read_stable(unsigned int idx, unsigned int *val)
{
	unsigned int a, b;
	int i;

	if (coef_read(idx, &a) < 0)
		return -1;
	for (i = 0; i < 5; i++) {
		usleep(20000);
		if (coef_read(idx, &b) < 0)
			return -1;
		if (a == b) {
			*val = b;
			return 0;
		}
		a = b;
	}
	*val = b;
	return 1;
}

/* kernel: alc_write_coefex_idx (read-modify-write keeps the other bits) */
static int coef_rmw(unsigned int idx, unsigned int mask, unsigned int bits)
{
	unsigned int val;
	unsigned int nval;

	if (coef_read_stable(idx, &val) < 0)
		return -1;
	nval = (val & ~mask) | (bits & mask);
	if (nval == val)
		return 0;
	if (hda_verb(HDA_VERB(AFG, VERB_SET_COEF_INDEX, idx), NULL) < 0)
		return -1;
	if (hda_verb(HDA_VERB(AFG, VERB_SET_PROC_COEF, nval), NULL) < 0)
		return -1;
	return 0;
}

static int lamp_set(int on)
{
	return coef_rmw(MIC_LED_IDX, MIC_LED_MASK, on ? MIC_LED_ON : MIC_LED_OFF);
}

static const char *lamp_name(unsigned int val)
{
	unsigned int bits = val & MIC_LED_MASK;

	if ((bits & MIC_LED_MASK) == MIC_LED_ON)
		return "F8 lamp ON";
	if ((bits & MIC_LED_MASK) == MIC_LED_OFF)
		return "F8 lamp OFF";
	return "F8 lamp in an unknown state";
}

static int mic_muted(void)
{
	int i;

	for (i = 0; state_files[i]; i++) {
		FILE *f = fopen(state_files[i], "r");
		int v;

		if (!f)
			continue;
		if (fscanf(f, "%d", &v) == 1) {
			fclose(f);
			return v ? 1 : 0;
		}
		fclose(f);
	}
	return -1;
}

static int open_codec(int quiet)
{
	if (fd >= 0)
		return 0;
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		if (!quiet) {
			fprintf(stderr, "hda-coef35: open %s: %s\n", dev,
				strerror(errno));
			fprintf(stderr, "hda-coef35: run as root (the hwdep node "
				"is root:audio)\n");
		}
		return -1;
	}
	return 0;
}

static int cmd_read(void)
{
	unsigned int val;
	int st;

	st = coef_read_stable(MIC_LED_IDX, &val);
	if (st < 0) {
		fprintf(stderr, "hda-coef35: COEF 0x35 read failed\n");
		return 1;
	}
	printf("COEF 0x%02x = 0x%04x (bits 2-3 = 0b%02x) -> %s\n",
	       MIC_LED_IDX, val, (val & MIC_LED_MASK) >> 2, lamp_name(val));
	if (st > 0)
		fprintf(stderr, "hda-coef35: warning: COEF 0x%02x kept changing "
			"while reading (another COEF user is active; the value "
			"above may belong to a different index)\n", MIC_LED_IDX);
	return 0;
}

static int cmd_state(int on)
{
	if (lamp_set(on) < 0) {
		fprintf(stderr, "hda-coef35: COEF 0x35 write failed\n");
		return 1;
	}
	return 0;
}

static int cmd_follow(int interval_ms)
{
	int last = -1;
	int fails = 0;
	int force_ticks = 0;

	fprintf(stderr, "hda-coef35: following the microphone mute state "
		"(interval %d ms), device %s\n", interval_ms, dev);
	while (!stop) {
		int state = mic_muted();
		int i;

		if (state < 0) {
			if (fails++ == 0)
				fprintf(stderr, "hda-coef35: no ctl-led/mic brightness "
					"file yet, waiting...\n");
		} else {
			if (state != last || force_ticks <= 0) {
				if (open_codec(fails > 0) == 0 && cmd_state(state) == 0) {
					if (state != last)
						fprintf(stderr, "hda-coef35: mic %s -> "
							"F8 lamp %s\n",
							state ? "muted" : "unmuted",
							state ? "on" : "off");
					last = state;
					fails = 0;
					force_ticks = 5 * 1000 / interval_ms;
				} else {
					fails++;
					fd = -1;
				}
			}
			force_ticks--;
		}
		for (i = 0; i < interval_ms / 10 + 1 && !stop; i++)
			usleep(10000);
	}
	fprintf(stderr, "hda-coef35: stopped\n");
	return 0;
}

int main(int argc, char **argv)
{
	int argi = 1;

	while (argi < argc && argv[argi][0] == '-' && argv[argi][1] != '\0') {
		if (!strcmp(argv[argi], "-d") && argi + 1 < argc) {
			dev = argv[++argi];
		} else if (!strcmp(argv[argi], "-h") || !strcmp(argv[argi], "--help")) {
			usage();
			return 0;
		} else {
			fprintf(stderr, "hda-coef35: unknown option %s\n", argv[argi]);
			usage();
			return 2;
		}
		argi++;
	}

	if (argi >= argc) {
		usage();
		return 2;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (!strcmp(argv[argi], "read")) {
		if (open_codec(0) < 0)
			return 1;
		return cmd_read();
	}
	if (!strcmp(argv[argi], "on")) {
		if (open_codec(0) < 0)
			return 1;
		return cmd_state(1);
	}
	if (!strcmp(argv[argi], "off")) {
		if (open_codec(0) < 0)
			return 1;
		return cmd_state(0);
	}
	if (!strcmp(argv[argi], "state")) {
		int on;

		if (argi + 1 >= argc) {
			fprintf(stderr, "hda-coef35: state needs 0 or 1\n");
			return 2;
		}
		on = atoi(argv[argi + 1]) ? 1 : 0;
		if (open_codec(0) < 0)
			return 1;
		return cmd_state(on);
	}
	if (!strcmp(argv[argi], "follow")) {
		int ms = 200;

		if (argi + 1 < argc)
			ms = atoi(argv[argi + 1]);
		if (ms < 20)
			ms = 20;
		return cmd_follow(ms);
	}
	if (!strcmp(argv[argi], "selftest")) {
		unsigned int before;

		if (open_codec(0) < 0)
			return 1;
		if (coef_read(MIC_LED_IDX, &before) < 0) {
			fprintf(stderr, "hda-coef35: COEF 0x35 read failed\n");
			return 1;
		}
		printf("before: 0x%04x -> %s\n", before, lamp_name(before));
		printf("switching the F8 lamp on...\n");
		if (lamp_set(1) < 0)
			return 1;
		sleep(2);
		printf("switching it off...\n");
		if (lamp_set(0) < 0)
			return 1;
		sleep(1);
		if (coef_rmw(MIC_LED_IDX, MIC_LED_MASK,
			     before & MIC_LED_MASK) < 0)
			return 1;
		printf("restored: 0x%04x\n", before);
		return 0;
	}

	fprintf(stderr, "hda-coef35: unknown command %s\n", argv[argi]);
	usage();
	return 2;
}
