#!/bin/sh
# AMD digital mics (ACP PDM: Renoir/Cezanne rn_acp3x, Yellow Carp acp6x, Pink Sardine acp63) accept exactly 4 periods
# (CAPTURE_MIN_NUM_PERIODS = CAPTURE_MAX_NUM_PERIODS = 4). Google's audio HAL (dras) opens capture with 2 periods of 20 ms
# (ThinkPad X13 Gen 2 AMD: 2 x 960 frames S32_LE 2ch = 2 x 7680 bytes), so every open fails "cannot set hw params: Invalid argument"
# and the internal mic never works. The 4 is not a hardware limit: hw_params programs the DMA ring from the negotiated sizes
# (ACP_WOV_RX_RINGBUFSIZE = buffer bytes, ACP_WOV_RX_INTR_WATERMARK_SIZE = period bytes), and the buffer is preallocated at
# MAX_BUFFER (4 x 8192 bytes), which 2 periods also fit in. Lower the minimum to 2; the maximum and the period sizes stay. Idempotent.
set -e
cd /build/src/sound/soc/amd
for h in renoir/rn_acp3x.h yc/acp6x.h ps/acp63.h; do
  grep -q '^#define CAPTURE_MIN_NUM_PERIODS     2' $h && continue
  grep -q '^#define CAPTURE_MIN_NUM_PERIODS     4$' $h || { echo "anchor mismatch: $h" >&2; exit 1; }
  sed -i 's/^#define CAPTURE_MIN_NUM_PERIODS     4$/#define CAPTURE_MIN_NUM_PERIODS     2/' $h
done
grep -n '^#define CAPTURE_MIN_NUM_PERIODS' renoir/rn_acp3x.h yc/acp6x.h ps/acp63.h
