#!/bin/bash
# Get OmacVM: clone it to ~/.omacvm (or update it there), put the `omacvm`
# command on your PATH and start it, which asks what to do (no VM yet: it
# builds one). From GitHub in one line:
#   curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
# From a clone: ./install.sh (links that clone instead). --no-start: only install.
set -euo pipefail
REPO=https://github.com/gillesgoetsch/omacvm.git
START=1
for a in "$@"; do
  case $a in
    --no-start) START=0 ;;
    *) echo "install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
say() { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo "OmacVM needs an Apple Silicon Mac." >&2; exit 1; }

# This checkout, when run from one; else ~/.omacvm.
here=""
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -x $here/omacvm && -f $here/src/VERSION ]] || here=""
fi
if [[ -z $here ]]; then
  here=$HOME/.omacvm
  command -v git >/dev/null || { echo "OmacVM needs git: xcode-select --install" >&2; exit 3; }
  if [[ -d $here/.git ]]; then say "updating $here"; git -C "$here" pull -q --ff-only
  else say "OmacVM -> $here"; git clone -q "$REPO" "$here"; fi
fi

# On the PATH: Homebrew's bin (OmacVM needs Homebrew anyway), else ~/.local/bin.
if command -v brew >/dev/null && [[ -w $(brew --prefix)/bin ]]; then bin=$(brew --prefix)/bin
else bin=$HOME/.local/bin; mkdir -p "$bin"; fi
ln -sf "$here/omacvm" "$bin/omacvm"
say "omacvm $(cat "$here/src/VERSION") -> $bin/omacvm"
case ":$PATH:" in *":$bin:"*) ;; *) echo "    add $bin to your PATH (e.g. in ~/.zshrc: export PATH=\"$bin:\$PATH\")" ;; esac
command -v brew >/dev/null || echo "    OmacVM's build needs Homebrew (https://brew.sh): brew install zstd e2fsprogs"

if (( START )); then
  # Piped from curl, stdin is the script: the questions read the terminal.
  if { : < /dev/tty; } 2>/dev/null; then exec "$here/omacvm" < /dev/tty
  else echo "    run: omacvm"; fi
fi
