#!/bin/sh
# AMD ACP digital mics (Renoir/Cezanne rn_acp3x, Yellow Carp acp6x, Pink Sardine acp63): high-pass the capture in the drivers' copy
# callback, the read() path Google's audio HAL (dras) uses. The PDM data has a large DC offset and hum below 100 Hz (ThinkPad X13
# Gen 2 AMD: +0.10/+0.34 of full scale, 25/60/200 Hz louder than the voice band), and the recorded voice came out shattered while the
# raw PCM sounds clean. Filter: kernel/isa_emu_patch/acp_pdm_hpf.h (two first-order stages at 100 Hz; tools/test_acp_pdm_hpf.sh),
# copied to sound/soc/amd/. The DMA ring stays raw (mmap readers are unaffected); the filter restarts at TRIGGER_START.
# Module parameter hpf (default 1): MODOPTS="snd_acp3x_pdm_dma.hpf=0" in gbos.cfg turns it off. Idempotent.
set -e
cd /build/src/sound/soc/amd
cp /host/kernel/isa_emu_patch/acp_pdm_hpf.h acp_pdm_hpf.h
grep -q 'acp_pdm_hpf_run' renoir/acp3x-pdm-dma.c && { echo already; exit 0; }
python3 - <<'PYEOF'
import re
# (header, C file, function prefix, pointer callback)
DRIVERS = [('renoir/rn_acp3x.h', 'renoir/acp3x-pdm-dma.c', 'acp_pdm', 'acp_pdm_dma_pointer'),
           ('yc/acp6x.h', 'yc/acp6x-pdm-dma.c', 'acp6x_pdm', 'acp6x_pdm_dma_pointer'),
           ('ps/acp63.h', 'ps/ps-pdm-dma.c', 'acp63_pdm', 'acp63_pdm_dma_pointer')]

def sub1(s, old, new, what):
    assert s.count(old) == 1, 'anchor mismatch (%s): %r' % (what, old)
    return s.replace(old, new)

for h, c, pfx, ptr in DRIVERS:
    s = open(h).read()
    m = re.findall(r'struct pdm_stream_instance \{\n.*?\n\};\n', s, re.S)
    assert len(m) == 1, 'anchor mismatch (%s): struct pdm_stream_instance' % h
    s = s.replace(m[0], '#include "../acp_pdm_hpf.h"\n\n' +
                  m[0][:-3] + '\tstruct acp_pdm_hpf hpf;\t/* gbOS86: capture high-pass state */\n};\n')
    open(h, 'w').write(s)

    s = open(c).read()
    # restart the filter where the stream (re)starts, right after the byte count is latched
    m = re.findall(r'(\t+rtd->bytescount = \w+_get_byte_count\(rtd,\s*substream->stream\);\n)', s)
    assert len(m) == 1, 'anchor mismatch (%s): bytescount latch' % c
    indent = re.match(r'\t+', m[0]).group(0)
    s = s.replace(m[0], m[0] + indent + 'acp_pdm_hpf_reset(&rtd->hpf);\n')
    func = '''/* gbOS86: hand the capture to read() through the high-pass filter (acp_pdm_hpf.h); the ring buffer itself stays raw. */
static bool hpf = true;
module_param(hpf, bool, 0644);
MODULE_PARM_DESC(hpf, "High-pass (DC offset and hum below 100 Hz) the digital-mic capture read through read() (default: 1)");

static int %(pfx)s_dma_copy(struct snd_soc_component *component, struct snd_pcm_substream *substream,
			   int channel, unsigned long pos, struct iov_iter *iter, unsigned long bytes)
{
	struct snd_pcm_runtime *runtime = substream->runtime;
	struct pdm_stream_instance *rtd = runtime->private_data;
	const unsigned char *src = runtime->dma_area + pos;
	int buf[256];	/* a multiple of whole S32 stereo frames */

	while (bytes) {
		size_t n = min_t(size_t, bytes, sizeof(buf));

		memcpy(buf, src, n);
		if (hpf && runtime->channels == ACP_PDM_HPF_CHANNELS &&
		    runtime->format == SNDRV_PCM_FORMAT_S32_LE)
			acp_pdm_hpf_run(&rtd->hpf, buf, n / sizeof(int));
		if (copy_to_iter(buf, n, iter) != n)
			return -EFAULT;
		src += n;
		bytes -= n;
	}
	return 0;
}

''' % {'pfx': pfx}
    m = re.search(r'static const struct snd_soc_component_driver \w+_component = \{', s)
    assert m, 'anchor mismatch (%s): component driver' % c
    s = s[:m.start()] + func + s[m.start():]
    m = re.findall(r'(\t\.pointer\s*= %s,\n)' % ptr, s)
    assert len(m) == 1, 'anchor mismatch (%s): .pointer' % c
    s = s.replace(m[0], m[0] + m[0].replace('.pointer', '.copy').replace(ptr, pfx + '_dma_copy'))
    open(c, 'w').write(s)
PYEOF
grep -n 'acp_pdm_hpf\|_dma_copy' renoir/acp3x-pdm-dma.c yc/acp6x-pdm-dma.c ps/ps-pdm-dma.c | head -20
