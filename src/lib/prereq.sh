# What the build needs on the Mac, and installing it (sourced after mac.sh,
# setup.sh and ui.sh; macOS's bash 3.2). Every install asks first and shows the
# command; with --yes (YES=1) nothing is installed and the build stops with
# the command to run instead (exit 3), so scripts and agents decide themselves.
#   prereq_screen            the welcome: this Mac and what is there
#   ensure_xcode_tools       Xcode's command line tools (Swift, clang, git)
#   ensure_homebrew          Homebrew, on the PATH of this run
#   ensure_brew_tools        zstd, e2fsprogs, and an OpenSSL with SHA-512 passwords
#   ensure_vm_app TYPE       Parallels Desktop or UTM 5

# An OpenSSL that can hash the password (macOS's own LibreSSL has no "passwd -6").
sha512_openssl() {
  local o
  for o in openssl "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"; do
    printf x | "$o" passwd -6 -stdin >/dev/null 2>&1 && { echo "$o"; return 0; }
  done
  return 1
}

have_xcode_tools() { xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null; }
have_homebrew() {
  command -v brew >/dev/null && return 0
  # Installed, but this shell's PATH does not have it yet.
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x $b ]] && { eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}
missing_brew_tools() {
  local m=""
  command -v zstd >/dev/null || m+=" zstd"
  command -v e2fsck >/dev/null || [[ -x $(brew --prefix e2fsprogs 2>/dev/null)/sbin/e2fsck ]] || m+=" e2fsprogs"
  sha512_openssl >/dev/null || m+=" openssl@3"
  echo "${m# }"
}
have_parallels() { [[ -d "/Applications/Parallels Desktop.app" && -x $PRLCTL ]]; }
have_utm5() { [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )); }

# The installs: ask (or stop with the command under --yes), run, check.
prereq_install() {   # "what" "command" -> runs the command after asking
  if (( YES )); then
    printf '\033[1;31mneeds you:\033[0m %s is missing: %s\n' "$1" "$2" >&2; exit 3
  fi
  say "    $1 is missing. OmacVM can install it now:"
  say "      $2"
  ask_yn "Install $1?" y || { say "    Install it yourself, then run omacvm again."; exit 3; }
}

ensure_xcode_tools() {
  have_xcode_tools && return 0
  prereq_install "Xcode's command line tools" "xcode-select --install"
  xcode-select --install >/dev/null 2>&1 || true
  say "    macOS shows its own installer window: click Install. Waiting for it to finish..."
  local i
  for ((i = 0; i < 360; i++)); do have_xcode_tools && { info "Xcode's command line tools installed"; return 0; }; sleep 5; done
  die "Xcode's command line tools are not there after 30 minutes: install them (xcode-select --install), then run omacvm again"
}

ensure_homebrew() {
  have_homebrew && return 0
  prereq_install "Homebrew" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  say "    Homebrew's installer asks for your Mac password and explains each step."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < "$TTY" ||
    die "Homebrew's installer did not finish: see https://brew.sh, then run omacvm again"
  have_homebrew || die "Homebrew is installed but not found: open a new terminal, then run omacvm again"
  # Homebrew on the PATH of new terminals too (its installer only prints how).
  local line="eval \"\$($(command -v brew) shellenv)\""
  if ! grep -qsF "$line" "$HOME/.zprofile" && ask_yn "Put Homebrew on the PATH of new terminals (a line in ~/.zprofile)?" y; then
    printf '\n%s\n' "$line" >> "$HOME/.zprofile"
  fi
}

ensure_brew_tools() {
  local m; m=$(missing_brew_tools)
  [[ -z $m ]] && return 0
  (( PLAN )) && return 0
  ensure_homebrew
  log "installing from Homebrew: $m"
  brew install -q $m >/dev/null || needs_person "brew install $m failed: run it yourself, then omacvm again"
}

ensure_vm_app() {
  case $1 in
    parallels)
      have_parallels && return 0
      ensure_homebrew
      prereq_install "Parallels Desktop" "brew install --cask parallels"
      brew install --cask parallels || die "brew install --cask parallels failed: install it from https://www.parallels.com/products/desktop/, then run omacvm again"
      open -a "Parallels Desktop" 2>/dev/null || true
      say "    Parallels Desktop opens: follow its first steps (it may ask for your Mac password)." ;;
    utm)
      have_utm5 && return 0
      local v; v=$(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)
      ensure_homebrew
      if [[ -n $v ]] && ! brew list --cask utm >/dev/null 2>&1; then
        # UTM 4 from the App Store or the website: not Homebrew's to replace.
        utm_install_help
        prereq_install "UTM 5" "quit UTM, move /Applications/UTM.app to the Trash (your VMs stay), then: brew install --cask utm@beta"
        die "move the old UTM to the Trash first, then run omacvm again"
      fi
      if [[ -n $v ]]; then
        prereq_install "UTM 5 (you have UTM $v)" "brew uninstall --cask utm && brew install --cask utm@beta"
        osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
        brew uninstall --cask utm || die "brew uninstall --cask utm failed"
      else
        prereq_install "UTM 5" "brew install --cask utm@beta"
      fi
      brew install --cask utm@beta || die "brew install --cask utm@beta failed: see https://github.com/utmapp/UTM/releases"
      open -a UTM 2>/dev/null || true ;;
  esac
}

# The welcome: this Mac, and what the build needs.
prereq_screen() {
  local model chip mark
  model=$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Model Name: //p' | head -1)
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  printf '\n  %s%s%s  ·  %s  ·  %s GB  ·  macOS %s%s\n' "$UB" "${model:-Mac}" "$UR" "${chip:-Apple Silicon}" "$mac_mem_gb" \
    "$(sw_vers -productVersion)" "$( [[ $NOTCH == notch ]] && echo "  ·  notch")" > "$TTY"
  for mark in "Xcode's command line tools|have_xcode_tools" "Homebrew|have_homebrew" \
              "Parallels Desktop|have_parallels" "UTM 5|have_utm5"; do
    if ${mark#*|}; then printf '  %s✓%s %s\n' "$UOK" "$UR" "${mark%%|*}" > "$TTY"
    else printf '  %s·%s %s %s(not installed)%s\n' "$UD" "$UR" "${mark%%|*}" "$UD" "$UR" > "$TTY"; fi
  done
}
