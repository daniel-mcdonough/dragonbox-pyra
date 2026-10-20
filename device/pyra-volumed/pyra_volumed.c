// pyra_volumed -- the volume wheel, mapped the way the wheel is built.
//
// A replacement for pyra-hacks' pyra_volumed (0.38). That one computes
//
//     volume = raw * max / 2052
//
// which assumes the ADC reading rises evenly with rotation. It does not: the
// wheel is a tapered potentiometer. Held at quarter turns on 2026-10-20 it
// read 16, 144, 394, 1071 and 2068: nearly all of its rise is at the top,
// and in log terms the bottom quarter is steeper than the rest. The control it
// drives, "Handsfree Playback Volume", is already in dB (0..29, -52..+6 dB in
// 2 dB steps), so the two logarithms stacked: the lower half of the wheel
// covered -52..-42 dB, all of it inaudible, and the upper half the other
// 48 dB. "You have to go near max to hear it."
//
// This turns the reading back into wheel travel through those five measured
// points, interpolating in log(raw) between them, so equal turns of the wheel
// are equal steps in dB. It spans STEP_LO..STEP_HI rather than the whole control,
// because below about -40 dB the speakers are silent. The very bottom of the
// wheel still goes to step 0.
//
// It needs nothing but libc and libm, so a fresh card can build it on its
// first boot with the gcc the image already has (pyra-trixie-prep.sh, fix 12;
// the image has no libasound2-dev or libiio-dev). The ADC is read from sysfs,
// the same channel libiio reads, and the volume is written with the ALSA
// control ioctl, the same control alsa-lib's simple mixer writes.
//
//     cc -O2 -Wall -o pyra_volumed pyra_volumed.c -lm

#include <fcntl.h>
#include <glob.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>

#define CARD_ID "L15"
#define CONTROL "Handsfree Playback Volume"
#define ADCNAME "palmas-gpadc"
#define CHANNEL "in_voltage2_raw"

// The wheel's reading at 0, 1/4, 1/2, 3/4 and full travel, measured on one
// unit on 2026-10-20. Another unit's pot may differ; re-measure by holding
// the wheel at each quarter and reading
// /sys/bus/iio/devices/iio:deviceN/in_voltage2_raw (N whose name is
// palmas-gpadc).
static const double CAL[] = { 16, 144, 394, 1071, 2068 };
#define NCAL (sizeof(CAL) / sizeof(CAL[0]))

// Readings this close to the bottom are "all the way down".
#define RAW_OFF 20.0

// Control steps the wheel spans: 6 = -40 dB, 29 = +6 dB. At or below
// RAW_OFF the volume goes to 0 (-52 dB), the quietest the codec does.
#define STEP_LO 6
#define STEP_HI 29

// The log mapping magnifies ADC noise at the bottom of the travel, where
// one count is a large ratio. Only move once the wheel's position is this
// far past the edge of the current step (in steps).
#define HYSTERESIS 0.3

#define MIN_DELAY 100000
#define MAX_DELAY 1000000

static int open_adc(void)
{
	glob_t g;
	int fd = -1;
	char path[512], name[64];

	if (glob("/sys/bus/iio/devices/iio:device*", 0, NULL, &g) != 0)
		return -1;
	for (size_t i = 0; i < g.gl_pathc && fd < 0; i++) {
		snprintf(path, sizeof(path), "%s/name", g.gl_pathv[i]);
		FILE *n = fopen(path, "r");
		if (!n)
			continue;
		if (fgets(name, sizeof(name), n) &&
		    strncmp(name, ADCNAME, strlen(ADCNAME)) == 0) {
			snprintf(path, sizeof(path), "%s/%s",
				 g.gl_pathv[i], CHANNEL);
			fd = open(path, O_RDONLY | O_CLOEXEC);
		}
		fclose(n);
	}
	globfree(&g);
	return fd;
}

// The card's control device, found by id: its number moves between boots.
static int open_card(void)
{
	glob_t g;
	int fd = -1;

	if (glob("/dev/snd/controlC*", 0, NULL, &g) != 0)
		return -1;
	for (size_t i = 0; i < g.gl_pathc && fd < 0; i++) {
		struct snd_ctl_card_info info;
		int c = open(g.gl_pathv[i], O_RDWR | O_CLOEXEC);

		if (c < 0)
			continue;
		memset(&info, 0, sizeof(info));
		if (ioctl(c, SNDRV_CTL_IOCTL_CARD_INFO, &info) == 0 &&
		    strcmp((const char *)info.id, CARD_ID) == 0)
			fd = c;
		else
			close(c);
	}
	globfree(&g);
	return fd;
}

static int set_volume(int card, long v)
{
	struct snd_ctl_elem_value val;

	memset(&val, 0, sizeof(val));
	val.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
	strncpy((char *)val.id.name, CONTROL, sizeof(val.id.name) - 1);
	val.value.integer.value[0] = v;
	val.value.integer.value[1] = v;
	return ioctl(card, SNDRV_CTL_IOCTL_ELEM_WRITE, &val);
}

// pread at offset 0, not stdio: rewind() may hand back the old buffer
// instead of seeking, and then the wheel is read once and never again.
static int read_raw(int fd, double *raw)
{
	char buf[32];
	ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);

	if (n <= 0)
		return -1;
	buf[n] = 0;
	*raw = atof(buf);
	return 0;
}

// How far round the wheel is, 0..1, from the calibration points.
static double travel(double raw)
{
	if (raw <= CAL[0])
		return 0;
	for (size_t i = 1; i < NCAL; i++)
		if (raw <= CAL[i])
			return (i - 1 + log(raw / CAL[i - 1]) /
				log(CAL[i] / CAL[i - 1])) / (NCAL - 1);
	return 1;
}

// Where the wheel is, in fractional control steps.
static double position(double raw)
{
	if (raw <= RAW_OFF)
		return 0;
	return STEP_LO + travel(raw) * (STEP_HI - STEP_LO);
}

int main(void)
{
	int adc, card;
	int delay = MIN_DELAY;
	long cur = -1;

	// The sound card and the ADC can both come up after this starts. Wait
	// rather than exit: the packaged unit's Restart=on-failure would hit
	// systemd's start limit within a second and give up for the boot.
	for (int waited = 0; (card = open_card()) < 0 || (adc = open_adc()) < 0;
	     waited++) {
		if (card >= 0)
			close(card);
		if (waited == 30)
			fprintf(stderr, "pyra_volumed: still waiting for card %s "
				"and %s %s\n", CARD_ID, ADCNAME, CHANNEL);
		sleep(1);
	}

	for (;;) {
		double raw;

		if (read_raw(adc, &raw) == 0) {
			double pos = position(raw);
			long want = lround(pos);

			if (cur < 0 || (want != cur &&
			    fabs(pos - cur) > 0.5 + HYSTERESIS)) {
				// On failure, log it once and try again on the next
				// movement rather than every 100 ms.
				if (set_volume(card, want) != 0)
					perror("pyra_volumed: " CONTROL);
				cur = want;
				delay = MIN_DELAY;
			} else {
				delay += delay / 10;
				if (delay > MAX_DELAY)
					delay = MAX_DELAY;
			}
		}
		usleep(delay);
	}
}
