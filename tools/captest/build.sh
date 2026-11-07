#!/bin/sh
# Build usb/audio/captest (static x86_64, runs on Android and Linux) from tools/captest/captest.c in the gbos-erofs container
# (clang + a static libc; docker build -t gbos-erofs tools/erofs-docker).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm --platform linux/amd64 -v "$ROOT":/host gbos-erofs sh -ec '
  clang -O2 -Wall -Wextra -static -o /host/usb/audio/captest /host/tools/captest/captest.c -lm
  strip /host/usb/audio/captest
  chown '"$(id -u):$(id -g)"' /host/usb/audio/captest'
echo "built usb/audio/captest ($(wc -c < "$ROOT/usb/audio/captest" | tr -d ' ') bytes)"
