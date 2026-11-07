#!/bin/sh
# Test of kernel/isa_emu_patch/acp_pdm_hpf.h, the high-pass filter the AMD ACP digital-mic drivers apply in their copy callback:
# tones and a DC offset (S32 stereo, 48 kHz) fed in randomly sized chunks (state across calls), steady-state gain checked per
# frequency. With a WAV (captest's S32 stereo 48 kHz): writes the filtered copy, to listen to or measure.
# Run: sh tools/test_acp_pdm_hpf.sh                      (needs a C compiler and libm)
#      sh tools/test_acp_pdm_hpf.sh IN.wav OUT.wav
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/hpftest.XXXXXX"); trap 'rm -rf "$W"' EXIT
cat > "$W/t.c" <<'EOF'
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "acp_pdm_hpf.h"
#define RATE 48000
static int fails, n;
static void run_chunks(struct acp_pdm_hpf *f, int *s, unsigned long frames) {
	unsigned long done = 0;
	srand(1);
	while (done < frames) {   /* 1..1000 frames per call, like reads of varying size */
		unsigned long k = 1 + rand() % 1000; if (k > frames - done) k = frames - done;
		acp_pdm_hpf_run(f, s + done * 2, k * 2); done += k;
	}
}
static double tone(double hz, double dc) {   /* gain in dB of a 0.3 FS tone (both channels), after 1 s */
	unsigned long frames = 3 * RATE, i, skip = RATE;
	int *s = malloc(frames * 2 * sizeof(int));
	double in = 0, out = 0;
	struct acp_pdm_hpf f; acp_pdm_hpf_reset(&f);
	for (i = 0; i < frames; i++) {
		double v = 0.3 * sin(2 * M_PI * hz * i / RATE);
		s[2 * i] = s[2 * i + 1] = (int)((v + dc) * 2147483647.0);
		if (i >= skip) in += v * v;
	}
	run_chunks(&f, s, frames);
	for (i = skip; i < frames; i++) { double v = s[2 * i] / 2147483648.0; out += v * v; }
	free(s);
	return 10 * log10(out / in);
}
static void chk(const char *what, int ok) { n++; if (!ok) fails++; printf("%s %s\n", ok ? "ok  " : "FAIL", what); }
static int wav(const char *in, const char *out) {
	FILE *fi = fopen(in, "rb"); if (!fi) { perror(in); return 1; }
	unsigned char h[44]; if (fread(h, 1, 44, fi) != 44) return 1;
	unsigned int bytes; memcpy(&bytes, h + 40, 4);
	int *s = malloc(bytes); if (fread(s, 1, bytes, fi) != bytes) return 1; fclose(fi);
	struct acp_pdm_hpf f; acp_pdm_hpf_reset(&f);
	run_chunks(&f, s, bytes / 8);
	FILE *fo = fopen(out, "wb"); fwrite(h, 1, 44, fo); fwrite(s, 1, bytes, fo); fclose(fo);
	printf("filtered %u frames -> %s\n", bytes / 8, out); return 0;
}
int main(int argc, char **argv) {
	if (argc == 3) return wav(argv[1], argv[2]);
	double g;
	/* DC alone: the offset of the X13's right channel */
	unsigned long frames = 2 * RATE, i; int *s = malloc(frames * 2 * sizeof(int)); double m = 0;
	struct acp_pdm_hpf f; acp_pdm_hpf_reset(&f);
	for (i = 0; i < frames * 2; i++) s[i] = (int)(0.35 * 2147483647.0);
	run_chunks(&f, s, frames);
	for (i = frames; i < frames * 2; i++) m += fabs(s[i] / 2147483648.0);
	m /= frames;
	printf("DC 0.35 FS -> mean |out| %.6f over the second half\n", m); chk("DC offset removed (< 0.0001 FS)", m < 0.0001);
	g = tone(25, 0.35);   printf("  25 Hz %+6.1f dB\n", g); chk("25 Hz hum cut by >= 20 dB", g <= -20);
	g = tone(60, 0.35);   printf("  60 Hz %+6.1f dB\n", g); chk("60 Hz hum cut by >= 10 dB", g <= -10);
	g = tone(200, 0.35);  printf(" 200 Hz %+6.1f dB\n", g); chk("200 Hz (voice) within 3 dB", g >= -3);
	g = tone(1000, 0.35); printf("1000 Hz %+6.1f dB\n", g); chk("1 kHz (voice) within 0.5 dB", g >= -0.5);
	g = tone(8000, 0.35); printf("8000 Hz %+6.1f dB\n", g); chk("8 kHz within 0.5 dB", g >= -0.5 && g <= 0.5);
	/* full-scale square wave around 0 must not wrap around (clamped, no sign flip) */
	acp_pdm_hpf_reset(&f);
	for (i = 0; i < frames * 2; i++) s[i] = ((i / 2) / 240) % 2 ? 2147483647 : -2147483647 - 1;
	run_chunks(&f, s, frames);
	int wrap = 0; for (i = 2; i < frames * 2; i++) { long long d = (long long)s[i] - s[i - 2]; if (d > 3000000000LL || d < -3000000000LL) { if (((i / 2) % 240) != 0) wrap++; } }
	chk("full-scale input clamps instead of wrapping", wrap == 0);
	printf("%d checks, %d failed\n", n, fails);
	if (!fails) printf("ACP_PDM_HPF_TEST_PASS\n");
	return fails != 0;
}
EOF
cc -O2 -Wall -Wextra -I"$ROOT/kernel/isa_emu_patch" -o "$W/t" "$W/t.c" -lm
"$W/t" "$@"
