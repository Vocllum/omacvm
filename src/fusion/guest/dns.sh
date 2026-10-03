#!/bin/bash
# Public DNS on VMware Fusion, only while OmacVM installs. Runs as root in the VM:
#   dns.sh on|off
# Fusion's NAT answers DNS itself and drops lookups when many come at once (a Go
# build fetching its modules fails with "no such host"). Afterwards the VM uses
# Fusion's DNS again, which follows the Mac's (VPN, Pi-hole, company DNS).
set -euo pipefail
C=/etc/NetworkManager/conf.d/90-omacvm-fusion.conf
case ${1:-on} in
  on) install -Dm644 /dev/stdin "$C" <<'CONF'
[global-dns-domain-*]
servers=1.1.1.1,9.9.9.9
CONF
  ;;
  off) [[ -f $C ]] || exit 0; rm -f "$C" ;;
  *) echo "dns.sh on|off" >&2; exit 2 ;;
esac
systemctl reload NetworkManager 2>/dev/null || true
