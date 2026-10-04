#!/bin/bash
# fuzz-cmd-stream.sh VIRGL_SOURCE DEPS_DIR [SECONDS]: build virglrenderer with ASan and
# libFuzzer coverage from a patched source tree (a kept runtime build:
# .build/tmp/omarchy-qemu-source-build.*/source/virglrenderer-1.3.0 and .../dependencies),
# then fuzz guest command streams (fuzz-cmd-stream.c) for SECONDS (default 600).
# Needs Homebrew llvm@22. Crashes land in ./fuzz-out/crash-*.
set -euo pipefail
src=$(cd "$1" && pwd); deps=$(cd "$2" && pwd); secs=${3:-600}
here=$(cd "$(dirname "$0")" && pwd)
llvm=$(brew --prefix llvm@22)
out=$PWD/fuzz-out; mkdir -p "$out/corpus"
build=$out/virgl-asan
pc=$(ls -d "$deps"/{virglrenderer,libepoxy,angle,glib,pixman}/*/lib/pkgconfig 2>/dev/null | tr '\n' ':')
libs=$(ls -d "$deps"/{libepoxy,angle,glib,pixman,gettext,pcre2}/*/lib 2>/dev/null | tr '\n' ':')
angle_inc=$(ls -d "$deps"/angle/*/include)
meson=$(ls "$src"/../../tools/meson-*/meson.py)
ninja_dir=$(dirname "$(ls "$src"/../../tools/ninja-*.data/scripts/ninja)")
pyyaml=$(ls -d "$src"/../../tools/pyyaml-*)/lib
if [[ ! -f $build/build.ninja ]]; then
  env PATH="$ninja_dir:$PATH" PYTHONPATH="$pyyaml" PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pc" CC="$llvm/bin/clang" OBJC="$llvm/bin/clang" \
    CFLAGS="-I$angle_inc -fsanitize=fuzzer-no-link -fsanitize=address -g" \
    OBJCFLAGS="-fsanitize=fuzzer-no-link -fsanitize=address -g" LDFLAGS="-fsanitize=address" \
    python3 "$meson" setup "$build" "$src" --buildtype=debugoptimized -Db_ndebug=false \
      --wrap-mode=nodownload -Ddrm-renderers=[] -Dvenus=false -Dtests=false -Dvideo=false \
      -Dtracing=none >/dev/null
fi
env PATH="$ninja_dir:$PATH" PYTHONPATH="$pyyaml" ninja -C "$build" >/dev/null
"$llvm/bin/clang" -g -fsanitize=fuzzer,address -I"$src/src" -I"$build/src" \
  "$here/fuzz-cmd-stream.c" -L"$build/src" -lvirglrenderer -Wl,-rpath,"$build/src" \
  -framework OpenGL -Wno-deprecated-declarations -o "$out/fuzz-cmd-stream"
cd "$out"
env DYLD_LIBRARY_PATH="$libs" ASAN_OPTIONS=detect_leaks=0 VIRGL_LOG_LEVEL=silent ./fuzz-cmd-stream -max_total_time="$secs" \
  -max_len=4096 -rss_limit_mb=4096 corpus
