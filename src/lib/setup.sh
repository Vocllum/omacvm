# build.sh's setup questions (sourced; macOS's bash 3.2). Every question reads
# the terminal directly, so build.sh's own output can be piped or logged.

TTY=/dev/tty
README_ROUTES="https://github.com/gillesgoetsch/omacvm#two-routes-parallels-or-utm"

say() { printf '%s\n' "$*"; }
hd() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ask_yn "question" y|n -> status 0 for yes
ask_yn() {
  local a hint="[y/N]"; [[ $2 == y ]] && hint="[Y/n]"
  while :; do
    read -r -p "  $1 $hint " a < "$TTY" || die "no answer (no terminal?)"
    a=${a:-$2}
    case $a in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

# ask_value "label" default regex -> the answer (re-asks until it matches)
ask_value() {
  local a
  while :; do
    read -r -p "    $1 [$2]: " a < "$TTY" || die "no answer (no terminal?)"
    a=${a:-$2}
    [[ $a =~ $3 ]] && { printf '%s\n' "$a"; return; }
    printf '    "%s" does not fit, try again\n' "$a" > "$TTY"
  done
}

# pick DEFAULT_INDEX INFO_FUNCTION OPTION... -> the chosen index (0-based).
# ←/→ (or h/l) move, 1-9 jump, Return confirms; INFO_FUNCTION <index> prints
# a short description shown beside the options.
pick() {
  local i=$1 info=$2; shift 2
  local n=$# k line j o
  local opts=("$@")
  while :; do
    line=""
    for ((j = 0; j < n; j++)); do
      o=${opts[$j]}
      if (( j == i )); then line+=$'\033[1;7m'" $o "$'\033[0m '; else line+=" $o  "; fi
    done
    printf '\r\033[K  ◀ %s▶   %s' "$line" "$($info "$i")" > "$TTY"
    IFS= read -rsn1 k < "$TTY" || die "no answer (no terminal?)"
    case $k in
      $'\033') IFS= read -rsn2 -t 1 k < "$TTY" || k=""
               case $k in '[D') (( i > 0 )) && i=$((i - 1)) ;; '[C') (( i < n - 1 )) && i=$((i + 1)) ;; esac ;;
      h) (( i > 0 )) && i=$((i - 1)) ;;
      l) (( i < n - 1 )) && i=$((i + 1)) ;;
      [1-9]) (( k <= n )) && i=$((k - 1)) ;;
      "") break ;;
    esac
  done
  printf '\n' > "$TTY"
  printf '%s\n' "$i"
}

# ---------- resources ----------
TIERS=(Low Balanced High Best)

# tier_values INDEX -> sets T_CPUS and T_MEM (GB), within CAP_CPUS / CAP_MEM_GB.
# Memory "Best" leaves macOS and the GPU (unified memory) max(8 GB, a quarter).
tier_values() {
  local m=$mac_mem_gb best_mem reserve
  reserve=$(( m / 4 > 8 ? m / 4 : 8 ))
  best_mem=$(( m - reserve > 4 ? m - reserve : 4 ))
  case $1 in
    0) T_CPUS=$(( mac_perf / 2 > 2 ? mac_perf / 2 : 2 )); T_MEM=$(( m / 4 > 4 ? m / 4 : 4 )) ;;
    1) T_CPUS=$mac_perf; T_MEM=$(( m / 2 )) ;;
    2) T_CPUS=$(( mac_perf + mac_eff / 2 )); T_MEM=$(( (m / 2 + best_mem) / 2 )) ;;
    3) T_CPUS=$mac_cores; T_MEM=$best_mem ;;
  esac
  (( T_MEM > best_mem )) && T_MEM=$best_mem
  (( T_MEM < 4 )) && T_MEM=4
  (( T_CPUS > CAP_CPUS )) && T_CPUS=$CAP_CPUS
  (( T_MEM > CAP_MEM_GB )) && T_MEM=$CAP_MEM_GB
  return 0
}

tier_info() { tier_values "$1"; printf '%s CPUs, %s GB memory' "$T_CPUS" "$T_MEM"; }

# ---------- the apps ----------
# Parallels' own licence limits per VM: sets P_EDITION, P_TRIAL, CAP_CPUS, CAP_MEM_GB.
parallels_limits() {
  local info
  info=$(prlsrvctl info --license 2>/dev/null) || return 1
  P_EDITION=$(sed -n 's/.*edition="\([^"]*\)".*/\1/p' <<<"$info")
  P_TRIAL=$(sed -n 's/.*is_trial="\([^"]*\)".*/\1/p' <<<"$info")
  local c m
  c=$(sed -n 's/.*cpu_total=\([0-9]*\).*/\1/p' <<<"$info")
  m=$(sed -n 's/.*max_memory=\([0-9]*\).*/\1/p' <<<"$info")
  [[ -n $P_EDITION && -n $c && -n $m ]] || return 1
  CAP_CPUS=$c; CAP_MEM_GB=$(( m / 1024 ))
}

utm_major() { defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null | cut -d. -f1; }

# wait_for_app parallels|utm: until the app is there (and usable), or the user quits.
wait_for_app() {
  local a
  while :; do
    case $1 in
      parallels)
        if [[ -x $PRLCTL ]] && parallels_limits; then return 0; fi
        if [[ -x $PRLCTL ]]; then
          hd "Parallels Desktop is installed but not set up yet"
          say "    Open Parallels Desktop once and sign in or start the trial."
        else
          hd "Parallels Desktop is not installed"
          say "    Download: https://www.parallels.com/products/desktop/"
          say "    or:       brew install --cask parallels"
          say "    Install it, open it once and sign in or start the trial."
        fi ;;
      utm)
        if [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )); then return 0; fi
        if [[ -x $UTMCTL ]]; then hd "UTM $(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null) is too old: OmacVM needs UTM 5"
        else hd "UTM is not installed"; fi
        say "    OmacVM needs UTM 5, for now a beta (tested with 5.0.6):"
        say "    https://github.com/utmapp/UTM/releases (the newest v5 release, UTM.dmg)"
        say "    Install it into /Applications and open it once." ;;
    esac
    read -r -p "  Press Return to check again, or q to quit: " a < "$TTY" || die "no answer (no terminal?)"
    [[ $a == q ]] && exit 1
  done
}

# omarchy-mac's published package lane: stable once it exists, else rc.
omarchy_channel() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
    https://api.github.com/repos/omarchy-mac/omarchy-pkgs-aarch64/releases/tags/stable) || code=0
  [[ $code == 200 ]] && echo stable || echo rc
}
