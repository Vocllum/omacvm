#!/bin/bash
# Get OmacVM: clone it to ~/.omacvm (or update it there), put the `omacvm`
# command on your PATH and start it, which asks what to do (no VM yet: it
# builds one). From GitHub in one line:
#   curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
# From a clone: ./install.sh (links that clone instead). --no-start: only install.
# OMACVM_REF=<branch or tag> installs that instead of main.
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
  # A fresh Mac: git (and Swift, for the build) come with Xcode's command line
  # tools; macOS's /usr/bin/git is only a stub that offers to install them.
  if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/git --version >/dev/null 2>&1; then
    say "Xcode's command line tools first (git, Swift): macOS shows its installer, click Install"
    xcode-select --install >/dev/null 2>&1 || true
    for ((i = 0; i < 720; i++)); do
      xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1 && break
      (( i % 12 == 0 )) && echo "    waiting for the command line tools to finish installing..."
      sleep 5
    done
    /usr/bin/git --version >/dev/null 2>&1 ||
      { echo "Xcode's command line tools did not finish: run xcode-select --install, then this again." >&2; exit 3; }
  fi
  # A clone that failed half-way (no .git) is OmacVM's own leftover: start over.
  [[ -d $here && ! -d $here/.git ]] && rm -rf "$here"
  if [[ -d $here/.git ]]; then say "updating $here"; git -C "$here" pull -q --ff-only
  else say "OmacVM -> $here"; git clone -q ${OMACVM_REF:+--branch "$OMACVM_REF"} "$REPO" "$here"; fi
fi

# On the PATH: Homebrew's bin (OmacVM needs Homebrew anyway), else ~/.local/bin.
if command -v brew >/dev/null && [[ -w $(brew --prefix)/bin ]]; then bin=$(brew --prefix)/bin
else bin=$HOME/.local/bin; mkdir -p "$bin"; fi
ln -sf "$here/omacvm" "$bin/omacvm"
say "omacvm $(cat "$here/src/VERSION") -> $bin/omacvm"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) # ~/.local/bin on the PATH of new terminals, and of this run.
     line='export PATH="$HOME/.local/bin:$PATH"'
     grep -qsF "$line" "$HOME/.zprofile" || printf '\n%s\n' "$line" >> "$HOME/.zprofile"
     export PATH="$bin:$PATH"
     echo "    $bin is on your PATH now (a line in ~/.zprofile)" ;;
esac

if (( START )); then
  # Piped from curl, stdin is the script: the questions read the terminal.
  if { : < /dev/tty; } 2>/dev/null; then exec "$here/omacvm" < /dev/tty
  else echo "    run: omacvm"; fi
fi
