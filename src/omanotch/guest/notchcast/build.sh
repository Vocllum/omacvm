#!/bin/bash
# Build notchcast inside the guest. Needs: gcc, wayland, wayland-protocols, lz4.
set -euo pipefail
cd "$(dirname "$0")"
P=/usr/share/wayland-protocols/staging
OUT=${1:-build}
mkdir -p "$OUT"
for x in ext-image-copy-capture/ext-image-copy-capture-v1 \
         ext-image-capture-source/ext-image-capture-source-v1 \
         ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1; do
  n=${x##*/}
  wayland-scanner client-header "$P/$x.xml" "$OUT/$n-client-protocol.h"
  wayland-scanner private-code "$P/$x.xml" "$OUT/$n-protocol.c"
done
gcc -O2 -Wall -Wextra -Wno-unused-parameter -I"$OUT" -o "$OUT/notchcast" notchcast.c "$OUT"/*-protocol.c \
  -lwayland-client -llz4 -lpthread -lm
echo "built $OUT/notchcast"
