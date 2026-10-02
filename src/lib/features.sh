# OmacVM's feature list (src/features.tsv) on the Mac side (sourced; macOS's
# bash 3.2, so parallel arrays instead of associative ones).
#   features_load                 FN FDEF FSIDES FTAGS FNEEDS FTITLE FSUM
#   feature_index NAME            -> index, or status 1
#   feature_has_tag INDEX TAG
#   features_read_env ENV_TEXT    FV (on|off per index) from a VM's /etc/omacvm/env;
#                                 defaults for what it does not name
#   features_fix                  a feature needing another one is off without it
FEATURES_TSV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/features.tsv"

features_load() {
  FN=(); FDEF=(); FSIDES=(); FTAGS=(); FNEEDS=(); FTITLE=(); FSUM=()
  local name def sides tags needs title sum
  while IFS=$'\t' read -r name def sides tags needs title sum; do
    [[ -z $name || $name == \#* ]] && continue
    FN+=("$name"); FDEF+=("$def"); FSIDES+=("$sides"); FTAGS+=("$tags")
    FNEEDS+=("$needs"); FTITLE+=("$title"); FSUM+=("$sum")
  done < "$FEATURES_TSV"
}

feature_index() {
  local i
  for ((i = 0; i < ${#FN[@]}; i++)); do [[ ${FN[$i]} == "$1" ]] && { echo "$i"; return 0; }; done
  return 1
}

feature_has_tag() { [[ ",${FTAGS[$1]}," == *",$2,"* ]]; }

# The default of feature INDEX on this Mac (NOTCH = notch|none).
feature_default() {
  case ${FDEF[$1]} in
    on) echo on ;;
    notch) [[ ${NOTCH:-none} == notch ]] && echo on || echo off ;;
    *) echo off ;;
  esac
}

features_read_env() {
  local i v
  FV=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    v=$(sed -n "s/^OMACVM_FEATURE_$(tr - _ <<<"${FN[$i]}")=//p" <<<"$1" | tail -1)
    if [[ -z $v ]]; then
      # VMs from before a feature existed: what they were built with.
      # (scroll-momentum was called glide in the experiment)
      [[ ${FN[$i]} == scroll-momentum ]] && v=$(sed -n 's/^OMACVM_FEATURE_glide=//p' <<<"$1" | tail -1)
      [[ -n $v ]] || case ${FN[$i]} in omanotch|scroll-momentum|autologin|thp-kernel) v=off ;; *) v=$(feature_default "$i") ;; esac
    fi
    FV[$i]=$v
  done
}

features_fix() {
  local i j changed=1
  while (( changed )); do
    changed=0
    for ((i = 0; i < ${#FN[@]}; i++)); do
      [[ ${FV[$i]} == on && ${FNEEDS[$i]} != - ]] || continue
      j=$(feature_index "${FNEEDS[$i]}") || continue
      [[ ${FV[$j]} == on ]] || { FV[$i]=off; changed=1; }
    done
  done
}

# JSON string (for the --json outputs).
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}
