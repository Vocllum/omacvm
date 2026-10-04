#!/bin/bash
# Builds the libFuzzer harnesses into tests/fuzz/out. Needs Homebrew's llvm
# (Apple's clang ships no libFuzzer runtime): brew install llvm.
# Swift harnesses: Apple's swiftc adds coverage and ASan, Homebrew's
# libFuzzer runs them.
set -euo pipefail
cd "$(dirname "$0")"
llvm=$(brew --prefix llvm@22 2>/dev/null || brew --prefix llvm)
rt=$(ls -d "$llvm"/lib/clang/*/lib/darwin | head -1)
app=../../app/app/Sources/OmacVM bridge=../../src/bridge/mac
mkdir -p out
sw() {
  local name=$1; shift
  swiftc -O -g -parse-as-library -sanitize=address \
    -sanitize-coverage=edge,inline-8bit-counters,pc-table,trace-cmp \
    "$@" -Xlinker "$rt/libclang_rt.fuzzer_osx.a" -lc++ -o "out/$name"
}
sw omanotch_stream omanotch_stream.swift ../../src/omanotch/mac/Sources/Stream.swift
sw bridge_http bridge_http.swift "$bridge/http.swift"
sw camera_requests camera_requests.swift "$bridge/camera.swift"
sw battery_lines battery_lines.swift battery_stubs.swift "$app/NativeBatteryBridge.swift" \
  "$app/HostBattery.swift" "$app/NativeBridgeSocket.swift"
"$llvm/bin/clang" -g -O1 -fsanitize=fuzzer,address -Wno-deprecated-declarations \
  gestures.c ../../src/gestures/mac/scroll_ns.m -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
  -framework ApplicationServices -framework CoreFoundation -framework Carbon -framework AppKit -o out/gestures
