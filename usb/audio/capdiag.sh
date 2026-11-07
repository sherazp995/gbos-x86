#!/system/bin/sh
# capdiag.sh N: internal-mic capture test of boot-N, run by mixdiag.sh (60 s after boot, while nothing records). For every digital-mic
# capture PCM ("DMIC" in /proc/asound/pcm) it records with audio/captest (tools/captest) the layout Google's audio HAL
# opens (2 periods x 960 frames) for 30 s, since the mic "worked for some time and then stopped", and the driver's old one (4 x 960)
# for 10 s. Writes logs/boot-N/captest.txt (accepted layout, overruns, period timing, level per 100 ms, DC offset and AC level per
# channel) and captest-<card>-<dev>-<periods>.wav (the first 3 s). Speak during that window so the WAVs have a voice in them.
# A mic already in use is reported (EBUSY) and skipped, never waited for.
N=$1
L=/postinstall/gbos/logs/boot-$N
C=/postinstall/gbos/audio/captest
[ -x $C ] || exit 0
{
  echo "== capture PCMs"; grep ': capture' /proc/asound/pcm
  sed -n 's/^\([0-9][0-9]\)-\([0-9][0-9]\):.*[Dd][Mm][Ii][Cc].* : capture [1-9].*/\1 \2/p' /proc/asound/pcm | while read c d; do
    c=$(echo $c | sed 's/^0//'); d=$(echo $d | sed 's/^0//')
    for run in "2 30" "4 10"; do
      set -- $run
      echo "== card $c device $d, $1 periods, $2 s"
      $C /dev/snd/pcmC${c}D${d}c 960 $1 $2 $L/captest-$c-$d-$1.wav 3
    done
  done
} > $L/captest.txt 2>&1
