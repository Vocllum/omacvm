#!/bin/bash
# check-boot-splash.sh: the boot splash's offline checks without QEMU's source
# (CI runs it): the logo's cells, the start animation's table and its core are
# in ui/omacvm-splash.h, a new file of omacvm-cocoa-boot-splash.patch, so they
# are taken from the patch. build-qemu-gpu-runtime.sh runs the same checks on
# the patched source.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
runtime=$(cd "$here/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ui/omacvm-splash.h is a new file in the patch: its lines without the +.
awk '/^\+\+\+ b\/ui\/omacvm-splash.h$/ { on = 1; next } on && /^(diff|--- )/ { exit }
     on && /^\+/ { print substr($0, 2) }' \
  "$runtime/patches/omacvm-cocoa-boot-splash.patch" > "$tmp/omacvm-splash.h"
python3 "$here/test-boot-splash-cells.py" "$tmp/omacvm-splash.h"
python3 "$runtime/boot-logo/make-splash-morph.py" --check "$tmp/omacvm-splash.h"
cc -Wall -Wextra -Werror -I"$tmp" "$here/test-boot-splash-morph.c" -o "$tmp/test-boot-splash-morph"
"$tmp/test-boot-splash-morph"
