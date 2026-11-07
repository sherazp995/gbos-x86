/* SPDX-License-Identifier: GPL-2.0 */
/* gbOS86: high-pass filter for the AMD ACP digital-mic capture (Renoir/Cezanne, Yellow Carp, Pink Sardine PDM drivers).
 *
 * The PDM decimator hands over a large DC offset (ThinkPad X13 Gen 2 AMD: +0.10 and +0.34 of full scale on the two channels, at
 * -20 and -9 dBFS) and strong hum below 100 Hz (24-25, 60, 200 Hz, as loud as the voice band). Google's audio HAL and apps get it
 * unfiltered and the voice comes out shattered; on other platforms the DSP removes it before userspace. This applies two cascaded
 * first-order high-pass stages at 100 Hz per channel (y = x - x[n-1] + R * y[n-1]), the usual voice-band cut: DC gone, 25 Hz about
 * -24 dB, 60 Hz about -12 dB, 200 Hz about -2 dB. S32_LE interleaved samples, filtered in place, state kept across calls.
 * Shared by the drivers' copy callbacks (read()/readi path); mmap readers get the raw buffer. Plain C: also built by
 * tools/test_acp_pdm_hpf.sh against a recorded WAV.
 */
#ifndef ACP_PDM_HPF_H
#define ACP_PDM_HPF_H

#define ACP_PDM_HPF_CHANNELS	2
/* R = 1 - 2*pi*100/48000 in Q30 */
#define ACP_PDM_HPF_R		1059686576LL

struct acp_pdm_hpf {
	long long x1[2][ACP_PDM_HPF_CHANNELS];	/* previous input of stage 0 and 1 */
	long long y1[2][ACP_PDM_HPF_CHANNELS];	/* previous output of stage 0 and 1 */
	int primed;
};

static inline void acp_pdm_hpf_reset(struct acp_pdm_hpf *f)
{
	int s, c;

	for (s = 0; s < 2; s++)
		for (c = 0; c < ACP_PDM_HPF_CHANNELS; c++)
			f->x1[s][c] = f->y1[s][c] = 0;
	f->primed = 0;
}

/* samples: interleaved S32 frames of ACP_PDM_HPF_CHANNELS channels; n = number of samples (not frames) */
static inline void acp_pdm_hpf_run(struct acp_pdm_hpf *f, int *samples, unsigned long n)
{
	unsigned long i;
	int s, c;

	/* start from the first frame's level, so the offset does not ring in as a step */
	if (!f->primed && n >= ACP_PDM_HPF_CHANNELS) {
		for (c = 0; c < ACP_PDM_HPF_CHANNELS; c++)
			f->x1[0][c] = samples[c];
		f->primed = 1;
	}
	for (i = 0; i < n; i++) {
		long long v;

		c = i % ACP_PDM_HPF_CHANNELS;
		v = samples[i];
		for (s = 0; s < 2; s++) {
			long long y = v - f->x1[s][c] + ((ACP_PDM_HPF_R * f->y1[s][c]) >> 30);

			/* clamped per stage: the state stays within S32, so R * y1 stays below 2^61 */
			if (y > 2147483647LL)
				y = 2147483647LL;
			else if (y < -2147483648LL)
				y = -2147483648LL;
			f->x1[s][c] = v;
			f->y1[s][c] = y;
			v = y;
		}
		samples[i] = (int)v;
	}
}

#endif
