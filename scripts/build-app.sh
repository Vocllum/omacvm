#!/bin/bash
# Build OmacVM.app into dist/: the launcher, QEMU (built from source on the
# first run, about 70 seconds), UEFI firmware, the VM scripts and OmacVM's VM
# side. Signed ad hoc.
#   scripts/build-app.sh [--name NAME]   (default OmacVM: the app's name and Dock title)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=OmacVM
while (( $# )); do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    *) echo "usage: build-app.sh [--name NAME]" >&2; exit 2 ;;
  esac
done
log() { printf '==> %s\n' "$*"; }

RT=$ROOT/runtime/.build
if [[ ! -x $RT/qemu-gpu-runtime/bin/qemu-system-aarch64 || ! -f $RT/firmware/edk2-aarch64-code.fd ]]; then
  log "QEMU (from source)"
  "$ROOT/runtime/build-qemu-gpu-runtime.sh"
fi

log "launcher"
cd "$ROOT/app"
mkdir -p .build/mc/swift .build/mc/clang
SWIFT_MODULECACHE_PATH=$PWD/.build/mc/swift CLANG_MODULE_CACHE_PATH=$PWD/.build/mc/clang \
  MACOSX_DEPLOYMENT_TARGET=15.0 swift build --disable-sandbox -c release -debug-info-format none 2>&1 | grep -v '^\[' || true
LAUNCHER=$ROOT/app/.build/release/OmacVM
[[ -x $LAUNCHER ]] || { echo "launcher build failed" >&2; exit 1; }

ICON=$ROOT/.build/OmacVM.icns
if [[ ! -f $ICON ]]; then
  log "icon"
  mkdir -p "$ROOT/.build"
  "$ROOT/vendor/omacvm/src/icon/make-icns.sh" "$ICON"
fi

APP=$ROOT/dist/$NAME.app
C=$APP/Contents
log "assembling $APP"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources/scripts" "$C/Resources/firmware" "$C/Resources/omacvm" "$C/Resources/licenses"
install -m755 "$LAUNCHER" "$C/MacOS/OmacVM"
install -m644 "$ICON" "$C/Resources/OmacVM.icns"
ditto "$RT/qemu-gpu-runtime" "$C/Resources/runtime"
mv "$C/Resources/runtime/bin/qemu-system-aarch64" "$C/Resources/runtime/bin/OmacVM"
install -m644 "$RT/firmware/edk2-aarch64-code.fd" "$C/Resources/firmware/"
install -m755 "$ROOT/scripts/create-vm.sh" "$ROOT/scripts/apply-vm.sh" "$ROOT/scripts/vm-common.sh" "$C/Resources/scripts/"
# OmacVM's VM side as committed in vendor/omacvm (no stray local files).
git -C "$ROOT/vendor/omacvm" archive HEAD src | tar -x -C "$C/Resources/omacvm"
install -m644 "$ROOT/LICENSE" "$C/Resources/licenses/LICENSE.omacvm-app"
install -m644 "$ROOT/THIRD_PARTY_NOTICES.md" "$C/Resources/licenses/"
install -m644 "$ROOT/runtime/LICENSE.try-omarchy" "$C/Resources/licenses/"
install -m644 "$RT/firmware/edk2-licenses.txt" "$C/Resources/licenses/"

VERSION=$(cat "$ROOT/VERSION")
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.omacvm.app</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>OmacVM</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>The VM can use your Mac's microphone.</string>
</dict>
</plist>
EOF

log "signing (ad hoc)"
for f in "$C/Resources/runtime/lib"/*.dylib "$C/Resources/runtime/bin/zstd"; do
  codesign --force --sign - "$f" 2>/dev/null
done
# The designated requirement names the identifier, not the binary's hash, so
# macOS keeps Accessibility and other grants across rebuilds (as OmacVM's helpers).
codesign --force --sign - --identifier org.omacvm.app.qemu -r='designated => identifier "org.omacvm.app.qemu"' \
  --entitlements "$ROOT/runtime/qemu-hvf.entitlements" "$C/Resources/runtime/bin/OmacVM"
codesign --force --sign - --identifier org.omacvm.app -r='designated => identifier "org.omacvm.app"' "$APP"
codesign --verify --deep --strict "$APP"
log "built $APP ($(du -sh "$APP" | cut -f1))"
