#!/system/bin/sh
# touchdiag.sh N: touchscreen responsiveness diagnostics. Run by the gbos_touchdiag service from gbos.rc after boot_completed.
# Writes logs/boot-N/touch.txt: the direct-touch input devices (INPUT_PROP_DIRECT, so never a keyboard or touchpad), their
# interrupt counts before and after, 60 s of their raw events with kernel timestamps (getevent -lt), and InputFlinger's state.
# From it: the controller's report rate while a finger moves (SYN_REPORT lines per second), gaps or batching in the timestamps
# (reports arriving in bursts = a late or missed interrupt), and the interrupt count per report; then how long apps took to draw
# (dumpsys gfxinfo percentiles) and the display refresh, for input-to-screen lag.
# Taps on the on-screen keyboard are recorded as coordinates too, so nothing should be typed on the screen during that minute.
N=$1
O=/postinstall/gbos/logs/boot-$N/touch.txt
SECS=60

# event nodes of devices whose PROP bitmap has INPUT_PROP_DIRECT (bit 1)
devs=$(awk '/^I:/ { d = 0; ev = "" } /^B: PROP=/ { p = substr($2, 6); d = (index("2367abefABEF", substr(p, length(p))) > 0) }
  /^H: Handlers=/ { h = $0; sub(/^H: Handlers=/, "", h); n = split(h, f, " "); for (i = 1; i <= n; i++) if (f[i] ~ /^event[0-9]+$/) ev = f[i] }
  /^$/ { if (d && ev != "") print "/dev/input/" ev; d = 0; ev = "" }
  END { if (d && ev != "") print "/dev/input/" ev }' /proc/bus/input/devices)

{
  echo "== direct-touch devices: ${devs:-none}"
  awk -v RS= '/B: PROP=[0-9a-fA-F]*[2367abefABEF]\n/' /proc/bus/input/devices
  echo "== interrupts before (i2c / hid lines)"
  grep -iE 'i2c|hid|elan|goodix|wacom|synps|gpio' /proc/interrupts
  echo "== start $(cat /proc/uptime)"
} > $O 2>&1
[ -n "$devs" ] || exit 0
for d in $devs; do
  timeout $SECS getevent -lt $d > $O.$(basename $d) 2>&1 &
done
wait
{
  echo "== end $(cat /proc/uptime)"
  echo "== interrupts after"
  grep -iE 'i2c|hid|elan|goodix|wacom|synps|gpio' /proc/interrupts
  for d in $devs; do
    f=$O.$(basename $d)
    echo "== $d: $(grep -c SYN_REPORT $f) reports, $(grep -c ABS_MT_POSITION_X $f) X updates in ${SECS} s"
    cat $f; rm -f $f
  done
  # only the reader part (devices, axes, touch calibration): the dispatcher part lists recently dispatched events, keys included
  echo "== dumpsys input (Input Reader State)"
  dumpsys input | sed -n '/^Input Reader State/,/^Input Dispatcher State/p'
  # how long apps took to draw while the finger moved: per process, frame count, janky frames and frame-time percentiles (HWUI)
  echo "== dumpsys gfxinfo (frame times per process)"
  dumpsys gfxinfo | grep -E '^\*\* Graphics info for pid|Total frames rendered|Janky frames|percentile|Number (Missed Vsync|High input latency|Slow UI thread|Slow bitmap uploads|Slow issue draw commands|Frame deadline missed)'
  echo "== dumpsys SurfaceFlinger (display refresh)"
  dumpsys SurfaceFlinger | grep -iE 'refresh-rate|vsync|present offset|renderFrameRate|activeMode' | head -20
} >> $O 2>&1
