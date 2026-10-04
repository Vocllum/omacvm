#!/bin/bash
# Guest side: build dEQP GLES2/GLES3 and deqp-vk from Khronos VK-GL-CTS (no Arch ARM package).
# Usage: build-cts.sh [REF]   (default: CTS_REF below). Output: /opt/vk-gl-cts/build, log in /opt/vk-gl-cts/build.log
set -euo pipefail
REF=${1:-${CTS_REF:-main}}
D=/opt/vk-gl-cts
pacman -S --needed --noconfirm cmake ninja python git libpng wayland libxkbcommon mesa >/dev/null
if [ ! -d $D/src/.git ]; then
  git clone --filter=blob:none https://github.com/KhronosGroup/VK-GL-CTS $D/src
fi
git -C $D/src fetch --depth 1 origin "$REF" && git -C $D/src checkout -q FETCH_HEAD
git -C $D/src rev-parse HEAD > $D/commit
python3 $D/src/external/fetch_sources.py >/dev/null
cmake -S $D/src -B $D/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DDEQP_TARGET=surfaceless
ninja -C $D/build deqp-gles2 deqp-gles3   # quick ones first
ninja -C $D/build deqp-vk
echo BUILD-OK
