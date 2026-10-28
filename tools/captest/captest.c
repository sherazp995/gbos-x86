/* captest: record from one ALSA capture device with a chosen period layout and report how the stream behaves.
 * Used by usb/audio/capdiag.sh to find out why the internal mic stutters and goes silent under Google's audio HAL (dras):
 * dras opens AMD's ACP digital mic with 2 periods of 20 ms; the driver used to demand 4. This records with a given
 * layout through the kernel's ALSA interface only (no alsa-lib, no tinyalsa) and prints, per run:
 *   - the hw params the driver accepted, overruns (read() == -EPIPE), the longest wait for a period, read errors;
 *   - the signal level (peak and RMS, in dBFS) of every 100 ms, so dropouts and silence show up, and per channel the DC offset
 *     and the AC level of the whole run (a large offset with gain applied clips);
 *   - optionally the first seconds as a WAV file.
 * Usage: captest /dev/snd/pcmC<card>D<dev>c PERIOD_FRAMES PERIODS SECONDS [OUT.wav [WAV_SECONDS]]
 * Fixed format: S32_LE, 2 channels, 48000 Hz (what dras uses for a DMIC). Build: tools/captest/build.sh (static). */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

#define RATE 48000
#define CHANNELS 2

static struct snd_mask *mask(struct snd_pcm_hw_params *p, int n) { return &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK]; }
static struct snd_interval *ival(struct snd_pcm_hw_params *p, int n) { return &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL]; }
static void mask_set(struct snd_pcm_hw_params *p, int n, unsigned bit) {
	struct snd_mask *m = mask(p, n);
	memset(m, 0, sizeof(*m));
	m->bits[bit >> 5] |= 1u << (bit & 31);
}
static void ival_set(struct snd_pcm_hw_params *p, int n, unsigned v) {
	struct snd_interval *i = ival(p, n);
	i->min = i->max = v;
	i->integer = 1;
	i->openmin = i->openmax = i->empty = 0;
}
static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}
static double db(double v) { return v > 0 ? 20 * log10(v) : -999; }

static void wav_header(FILE *f, uint32_t frames) {
	uint32_t data = frames * CHANNELS * 4, u32;
	uint16_t u16;
	fwrite("RIFF", 1, 4, f); u32 = 36 + data; fwrite(&u32, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
	u32 = 16; fwrite(&u32, 4, 1, f); u16 = 1; fwrite(&u16, 2, 1, f); u16 = CHANNELS; fwrite(&u16, 2, 1, f);
	u32 = RATE; fwrite(&u32, 4, 1, f); u32 = RATE * CHANNELS * 4; fwrite(&u32, 4, 1, f);
	u16 = CHANNELS * 4; fwrite(&u16, 2, 1, f); u16 = 32; fwrite(&u16, 2, 1, f);
	fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
}

int main(int argc, char **argv) {
	if (argc < 5) {
		fprintf(stderr, "usage: %s /dev/snd/pcmCxDyc PERIOD_FRAMES PERIODS SECONDS [OUT.wav [WAV_SECONDS]]\n", argv[0]);
		return 2;
	}
	unsigned period = atoi(argv[2]), periods = atoi(argv[3]), secs = atoi(argv[4]);
	const char *wav = argc > 5 ? argv[5] : NULL;
	unsigned wav_secs = argc > 6 ? atoi(argv[6]) : 2;
	printf("captest %s: %u periods x %u frames (%.1f ms each), S32_LE %u ch %u Hz, %u s\n", argv[1], periods, period,
	       period * 1000.0 / RATE, CHANNELS, RATE, secs);

	/* O_NONBLOCK: a blocking open sleeps until the substream is free, so a mic held by the HAL or an app would hang this (and the
	 * diagnostic service) for good; fail with EBUSY instead, then read in blocking mode. */
	int fd = open(argv[1], O_RDONLY | O_NONBLOCK);
	if (fd < 0) { printf("open: %s%s\n", strerror(errno), errno == EBUSY ? " (the mic is in use)" : ""); return 1; }
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);

	struct snd_pcm_hw_params hw;
	memset(&hw, 0, sizeof(hw));
	for (int n = SNDRV_PCM_HW_PARAM_FIRST_MASK; n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++) memset(mask(&hw, n), 0xff, sizeof(struct snd_mask));
	for (int n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++) { ival(&hw, n)->min = 0; ival(&hw, n)->max = UINT_MAX; }
	hw.rmask = ~0u;
	mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S32_LE);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	ival_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, CHANNELS);
	ival_set(&hw, SNDRV_PCM_HW_PARAM_RATE, RATE);
	ival_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period);
	ival_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, periods);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw) < 0) { printf("hw_params: %s (layout refused by the driver)\n", strerror(errno)); return 1; }
	unsigned buffer = ival(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE)->min;
	printf("accepted: period %u frames, %u periods, buffer %u frames (%u bytes)\n", ival(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->min,
	       ival(&hw, SNDRV_PCM_HW_PARAM_PERIODS)->min, buffer, buffer * CHANNELS * 4);

	struct snd_pcm_sw_params sw;
	memset(&sw, 0, sizeof(sw));
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_ENABLE;
	sw.period_step = 1;
	sw.avail_min = period;
	sw.start_threshold = 1;
	sw.stop_threshold = buffer;   /* an overrun stops the stream, so read() reports it (-EPIPE) */
	sw.silence_size = 0;
	if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw) < 0) { printf("sw_params: %s\n", strerror(errno)); return 1; }
	if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) { printf("prepare: %s\n", strerror(errno)); return 1; }

	int32_t *buf = malloc((size_t)period * CHANNELS * 4);
	if (!buf) { printf("out of memory\n"); return 1; }
	FILE *wf = wav ? fopen(wav, "wb") : NULL;
	uint32_t wav_frames = 0, wav_max = wav_secs * RATE;
	if (wf) wav_header(wf, 0);

	unsigned long long total = 0, slot_n = 0, ch_n = 0;
	unsigned xruns = 0, errors = 0, zero_reads = 0, reads = 0;
	double slot_sq = 0, slot_peak = 0, max_wait = 0, t0 = now(), last = t0, slot_start = t0;
	double ch_sum[CHANNELS] = {0}, ch_sq[CHANNELS] = {0};   /* per channel, whole run: DC offset (mean) and AC level */
	printf("t(s)    peak(dBFS) rms(dBFS)   [per 100 ms]\n");
	while (now() - t0 < secs) {
		struct snd_xferi x = { .buf = buf, .frames = period };
		int r = ioctl(fd, SNDRV_PCM_IOCTL_READI_FRAMES, &x);
		double t = now();
		if (reads++ && t - last > max_wait) max_wait = t - last;   /* the first read includes the stream start */
		last = t;
		if (r < 0) {
			if (errno == EPIPE || errno == ESTRPIPE) {
				xruns++;
				printf("%7.3f  %s (%u so far)\n", t - t0, errno == EPIPE ? "OVERRUN" : "SUSPENDED", xruns);
				ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
				continue;
			}
			if (++errors > 20) { printf("read: %s, giving up\n", strerror(errno)); break; }
			continue;
		}
		total += x.result;
		int all_zero = 1;
		for (long i = 0; i < x.result * CHANNELS; i++) {
			double v = fabs(buf[i] / 2147483648.0);
			if (buf[i]) all_zero = 0;
			slot_sq += v * v; if (v > slot_peak) slot_peak = v;
			ch_sum[i % CHANNELS] += buf[i] / 2147483648.0; ch_sq[i % CHANNELS] += v * v;
		}
		ch_n += x.result;
		slot_n += x.result * CHANNELS;
		if (all_zero) zero_reads++;
		if (wf && wav_frames < wav_max) {
			uint32_t n = x.result; if (wav_frames + n > wav_max) n = wav_max - wav_frames;
			fwrite(buf, CHANNELS * 4, n, wf); wav_frames += n;
		}
		if (t - slot_start >= 0.1) {
			printf("%7.3f  %8.1f %9.1f\n", t - t0, db(slot_peak), db(slot_n ? sqrt(slot_sq / slot_n) : 0));
			slot_sq = slot_peak = 0; slot_n = 0; slot_start = t;
		}
	}
	double el = now() - t0;
	printf("summary: %llu frames in %.2f s = %.0f frames/s (expected %u), %u overruns, %u read errors, %u all-zero reads, "
	       "longest wait for a period %.1f ms (period %.1f ms)\n", total, el, total / el, RATE, xruns, errors, zero_reads,
	       max_wait * 1000, period * 1000.0 / RATE);
	for (int c = 0; c < CHANNELS && ch_n; c++) {
		double m = ch_sum[c] / ch_n, ac = ch_sq[c] / ch_n - m * m;
		printf("channel %d: DC offset %+.4f of full scale (%.1f dBFS), AC level %.1f dBFS\n", c, m, db(fabs(m)), db(ac > 0 ? sqrt(ac) : 0));
	}
	if (wf) { fseek(wf, 0, SEEK_SET); wav_header(wf, wav_frames); fclose(wf); }
	ioctl(fd, SNDRV_PCM_IOCTL_DROP);
	close(fd);
	return 0;
}
