#!/bin/bash
# Make UTM-video.app: a copy of /Applications/UTM.app with the VideoToolbox
# virglrenderer swapped in, re-signed ad hoc. The installed UTM is not touched.
#   src/utm/make-utm-video.sh VIRGL_DYLIB [OUT_DIR]
# VIRGL_DYLIB: utmapp/virglrenderer 5d26f605 (UTM 5.0.6) with
# virgl-videotoolbox-decode.patch (drop "vrend_state.video_available =" and
# "== 0": UTM's tree has no such field), built with -Dvideo=true -Dvenus=true
# -Dvulkan-dload=false -Dneptune=true like UTM's own. For testing only.
# The bundle is edited under a name without .app and renamed at the end:
# macOS App Management blocks writes into an existing (copied) app bundle.
set -euo pipefail
dylib=$1; out=${2:-$(dirname "$0")}
cd "$out"
rm -rf UTM-video.build UTM-video.app
ditto /Applications/UTM.app UTM-video.build
B=UTM-video.build/Contents
cp "$dylib" $B/Frameworks/virglrenderer.1.framework/Versions/A/virglrenderer.1
install_name_tool -id @rpath/virglrenderer.1.framework/virglrenderer.1 \
  -change @@HOMEBREW_PREFIX@@/opt/libepoxy/lib/libepoxy.0.dylib @rpath/epoxy.0.framework/Versions/A/epoxy.0 \
  -change @rpath/vulkan.1.framework/vulkan.1 @rpath/vulkan.1.framework/Versions/A/vulkan.1 \
  $B/Frameworks/virglrenderer.1.framework/Versions/A/virglrenderer.1 2>/dev/null
find UTM-video.build -name embedded.provisionprofile -delete
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.omacvm.UTM-video" -c "Set :CFBundleName UTM-video" $B/Info.plist
xattr -cr UTM-video.build
# Entitlements without the sandbox, app groups and the ones that need UTM's
# provisioning profile (team id, vm.networking, USB); hypervisor and JIT stay.
ent() { python3 - "$1" "$2" <<'PY'
import plistlib, subprocess, sys
x = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", sys.argv[1]], capture_output=True).stdout
e = plistlib.loads(x) if x.strip() else {}
for k in ("com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.vm.networking",
          "com.apple.developer.accessory-access.usb", "com.apple.vm.device-access", "com.apple.security.app-sandbox",
          "com.apple.security.application-groups", "com.apple.security.inherit",
          "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope",
          "com.apple.security.device.usb"):
    e.pop(k, None)
plistlib.dump(e, open(sys.argv[2], "wb"))
PY
}
U=/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc
H=$B/XPCServices/QEMUHelper.xpc
mkdir -p ent
ent /Applications/UTM.app ent/main.plist; ent $U ent/helper.plist
ent $U/Contents/MacOS/QEMULauncher.app ent/launcher.plist; ent $U/Contents/MacOS/QEMURenderServer.app ent/render.plist
for f in $B/Frameworks/*.framework; do codesign -f -s - "$f" 2>/dev/null; done
codesign -f -s - $B/MacOS/utmctl
codesign -f -s - --entitlements ent/launcher.plist $H/Contents/MacOS/QEMULauncher.app
codesign -f -s - --entitlements ent/render.plist $H/Contents/MacOS/QEMURenderServer.app
codesign -f -s - --entitlements ent/helper.plist $H
codesign -f -s - --entitlements ent/main.plist UTM-video.build
codesign --verify --deep --strict UTM-video.build
mv UTM-video.build UTM-video.app
echo "made $PWD/UTM-video.app"
