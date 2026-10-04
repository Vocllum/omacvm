#!/bin/bash
# Build KosmicKrisp, Mesa's Vulkan driver on Metal, from a pinned Mesa commit:
#   app/runtime/build-kosmickrisp.sh [--archive-dir DIR]
# Output: app/runtime/.build/kosmickrisp/libvulkan_kosmickrisp.dylib (+ stamp).
# Venus uses it instead of MoltenVK on macOS 26 and newer (it needs Metal 4);
# the runtime keeps MoltenVK for older macOS.
#
# Two Mesa builds: the first makes Mesa's OpenCL-C compiler (mesa_clc, with
# LLVM) for the driver's built-in kernels; the second builds the driver with
# that tool and without LLVM, SPIRV-Tools or zstd, so the dylib links only
# system libraries. Build-time needs (Homebrew): llvm spirv-llvm-translator
# spirv-tools bison pkgconf. Needs an SDK with Metal 4 (Xcode 26 or newer).
# Skips the build when the output already matches this script and commit.
set -euo pipefail

mesa_commit=e5f0687867f5c5e88619175d9b0442f8560e8d53
mesa_root="mesa-$mesa_commit"
mesa_archive_name="$mesa_root.tar.gz"
mesa_url="https://gitlab.freedesktop.org/mesa/mesa/-/archive/$mesa_commit/$mesa_archive_name"
mesa_sha256=3a6ea0ac2dd769e0e34867479fa094faa7b7f76f4c7f320318ddeb9089a1c55e

meson_root=meson-1.9.0
meson_archive_name="$meson_root.tar.gz"
meson_url="https://github.com/mesonbuild/meson/releases/download/1.9.0/$meson_archive_name"
meson_sha256=cd27277649b5ed50d19875031de516e270b22e890d9db65ed9af57d18ebc498d
ninja_archive_name=ninja-1.13.0-py3-none-macosx_10_9_universal2.whl
ninja_url="https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/$ninja_archive_name"
ninja_sha256=fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1

# Mesa's code generators: Mako (with MarkupSafe), PyYAML, packaging.
python_requirements() {
  cat <<'EOF'
setuptools==84.0.0 --hash=sha256:51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670
wheel==0.48.0 --hash=sha256:3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab
packaging==26.3 --hash=sha256:d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c
EOF
}
python_generator_requirements() {
  cat <<'EOF'
mako==1.4.3 --hash=sha256:723296007c870bfd6b3f0c3230dba7198096e5269297ebf5e4eff9e7ffa39d4f
markupsafe==3.0.4 --hash=sha256:2e9ad7dd851bf45fab9f75cbff4cb493fee9979e8d8c7c9c3ee119022518edd6
pyyaml==6.0.3 --hash=sha256:d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f
EOF
}

die() { echo "kosmickrisp-build: $*" >&2; exit 1; }
log() { echo "[kosmickrisp-build] $*"; }

archive_cache=
while (($#)); do
  case $1 in
    --archive-dir) (($# >= 2)) || die "--archive-dir needs a directory"; archive_cache=$2; shift 2 ;;
    *) echo "usage: build-kosmickrisp.sh [--archive-dir DIR]" >&2; exit 64 ;;
  esac
done

native_dir=$(cd "$(dirname "$0")" && pwd -P)
out_dir="$native_dir/.build/kosmickrisp"
stamp="$out_dir/stamp"
want_stamp="$mesa_commit $(shasum -a 256 "$0" | cut -d' ' -f1)"
if [[ -f $out_dir/libvulkan_kosmickrisp.dylib && $(cat "$stamp" 2>/dev/null) == "$want_stamp" ]]; then
  log "up to date ($out_dir)"
  exit 0
fi

[[ $(uname -m) == arm64 ]] || die "needs Apple Silicon"
case $native_dir in *' '*) die "the path has a space; meson splits it: $native_dir" ;; esac
brew_prefix=$(brew --prefix 2>/dev/null) || die "Homebrew is needed for the build-time LLVM"
llvm_bin="$brew_prefix/opt/llvm/bin"
bison_bin="$brew_prefix/opt/bison/bin"
[[ -x $llvm_bin/llvm-config ]] || die "missing LLVM: brew install llvm spirv-llvm-translator spirv-tools"
[[ -x $bison_bin/bison ]] || die "missing bison > 2.3: brew install bison"
for tool in curl pkg-config python3 shasum tar xcrun; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done
pkg-config --exists LLVMSPIRVLib SPIRV-Tools || \
  die "missing build-time SPIR-V libraries: brew install spirv-llvm-translator spirv-tools"
sdk_major=$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)
((sdk_major >= 26)) || die "needs the macOS 26 SDK or newer (Metal 4); have $sdk_major"

mkdir -p "$native_dir/.build/tmp"
work=$(mktemp -d "$native_dir/.build/tmp/kosmickrisp.XXXXXX")
cleanup() {
  if [[ -n ${OMACVM_RUNTIME_KEEP_SCRATCH:-} ]]; then
    log "kept scratch tree: $work"
  else
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

obtain() {
  local name=$1 url=$2 sha=$3 dest="$work/$1"
  if [[ -n $archive_cache && -f $archive_cache/$name ]]; then
    install -m 0644 "$archive_cache/$name" "$dest"
  else
    log "downloading $name"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      --retry 3 --connect-timeout 20 --output "$dest" "$url"
  fi
  [[ $(shasum -a 256 "$dest" | cut -d' ' -f1) == "$sha" ]] || die "checksum mismatch: $name"
}
obtain "$mesa_archive_name" "$mesa_url" "$mesa_sha256"
obtain "$meson_archive_name" "$meson_url" "$meson_sha256"
obtain "$ninja_archive_name" "$ninja_url" "$ninja_sha256"

tar -xzf "$work/$mesa_archive_name" -C "$work"
tar -xzf "$work/$meson_archive_name" -C "$work"
mkdir -p "$work/ninja" && ditto -x -k "$work/$ninja_archive_name" "$work/ninja"
ninja_dir=$(dirname "$(find "$work/ninja" -path '*scripts/ninja' -type f | head -1)")
chmod 0755 "$ninja_dir/ninja"

log "python tools (pinned)"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" -q install --disable-pip-version-check --require-hashes \
  -r <(python_requirements)
"$work/venv/bin/pip" -q install --disable-pip-version-check --require-hashes \
  --no-build-isolation --no-binary markupsafe,pyyaml -r <(python_generator_requirements)

src="$work/$mesa_root"
meson=("$work/venv/bin/python3" "$work/$meson_root/meson.py")
export PATH="$work/venv/bin:$ninja_dir:$llvm_bin:$bison_bin:$PATH"
common=(--wrap-mode=nodownload -Dplatforms= -Dgallium-drivers= -Dopengl=false
  -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled
  -Dvideo-codecs= -Dtools= -Dvulkan-layers= -Dbuild-tests=false)

log "Mesa $mesa_commit: mesa_clc (build-time tool)"
"${meson[@]}" setup "$work/build-clc" "$src" --prefix="$work/clc" --buildtype=release \
  "${common[@]}" -Dvulkan-drivers= -Dllvm=enabled -Dmesa-clc=enabled \
  -Dinstall-mesa-clc=true -Dmesa-clc-bundle-headers=enabled
ninja -C "$work/build-clc"
"${meson[@]}" install -C "$work/build-clc" --no-rebuild >/dev/null
[[ -x $work/clc/bin/mesa_clc && -x $work/clc/bin/vtn_bindgen2 ]] || die "mesa_clc was not built"

log "Mesa $mesa_commit: KosmicKrisp"
env PATH="$work/clc/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 \
  "${meson[@]}" setup "$work/build-kk" "$src" --prefix="$work/kk" --libdir=lib \
  --buildtype=release -Db_ndebug=true "${common[@]}" -Dvulkan-drivers=kosmickrisp \
  -Dllvm=disabled -Dmesa-clc=system -Dspirv-tools=disabled -Dzstd=disabled
env PATH="$work/clc/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 ninja -C "$work/build-kk"

dylib="$work/build-kk/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
[[ -f $dylib ]] || die "the driver was not built"
# Only system libraries: nothing from the build machine's Homebrew.
otool -L "$dylib" | sed -n '2,$p' | awk '{print $1}' | while read -r dep; do
  case $dep in
    @rpath/libvulkan_kosmickrisp.dylib|/usr/lib/*|/System/Library/*) ;;
    *) die "the driver links a non-system library: $dep" ;;
  esac
done
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$dylib"

rm -rf "$out_dir"; mkdir -p "$out_dir"
install -m 0755 "$dylib" "$out_dir/libvulkan_kosmickrisp.dylib"
install -m 0644 "$src/docs/license.rst" "$out_dir/mesa-license.rst"
echo "$want_stamp" > "$stamp"
log "built $out_dir/libvulkan_kosmickrisp.dylib (Mesa $mesa_commit)"
