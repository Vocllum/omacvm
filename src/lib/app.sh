# OmacVM.app's VMs, from the Mac (sourced by vm.sh; bash 3.2). The app keeps
# each VM in a folder with vm.env (NAME, SSH_PORT, ...) and disk.img; QEMU
# forwards the VM's SSH to 127.0.0.1:SSH_PORT, so its "IP" here is
# 127.0.0.1:PORT (gssh understands that).
#   app_list            NAME<TAB>app<TAB>running|stopped, one line per VM
#   app_dir NAME        the VM's folder
#   app_ip NAME         127.0.0.1:PORT while it runs
#   app_start NAME      start it in the app (its window opens)

app_vms_root() {
  local r
  r=$(defaults read org.omacvm.app vmsRoot 2>/dev/null)
  echo "${r:-$HOME/Library/Application Support/OmacVM/VMs}"
}

app_env() {   # DIR KEY: one value from vm.env (single quotes stripped)
  sed -n "s/^$2=//p" "$1/vm.env" 2>/dev/null | tail -1 | sed "s/^'\(.*\)'\$/\1/"
}

app_pid_dir() {   # DIR -> the PID of its QEMU (the disk is on its command line, commas
  # doubled); this user's processes only: another account could fake the line.
  ps -x -U "$(id -u)" -o pid=,args= 2>/dev/null | grep -F -- "file=${1//,/,,}/disk.img," |
    grep -v grep | awk '{ print $1; exit }'
}

app_running_dir() { [[ -n $(app_pid_dir "$1") ]]; }

app_list() {
  local d n
  for d in "$(app_vms_root)"/*; do
    [[ -f $d/vm.env && -f $d/disk.img ]] || continue
    n=$(app_env "$d" NAME); [[ -n $n ]] || n=$(basename "$d")
    printf '%s\tapp\t%s\n' "$n" "$(app_running_dir "$d" && echo running || echo stopped)"
  done
}

app_dir() {
  local d
  for d in "$(app_vms_root)"/*; do
    [[ -f $d/vm.env ]] || continue
    [[ $(app_env "$d" NAME) == "$1" || $(basename "$d") == "$1" ]] && { echo "$d"; return 0; }
  done
  return 1
}

app_ip() {   # NAME [seconds]: only when that QEMU itself holds the port (not
  # whatever else listens there)
  local d p i pid
  d=$(app_dir "$1") || return 1
  p=$(app_env "$d" SSH_PORT); [[ $p =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i <= ${2:-0}; i += 2)); do
    pid=$(app_pid_dir "$d")
    if [[ -n $pid ]] && lsof -nP -a -p "$pid" -iTCP@127.0.0.1:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "127.0.0.1:$p"; return 0
    fi
    sleep 2
  done
  return 1
}

app_start() {
  # -n: a new launcher passes the request on when one already runs.
  open -n -b org.omacvm.app --args --start --vm "$1" || return 1
  app_ip "$1" 60
}
