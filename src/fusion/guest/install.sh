#!/bin/bash
# VMware Fusion guest specifics. Runs as root in the VM: install.sh <desktop-user>
set -euo pipefail
U=${1:?usage: install.sh <desktop-user>}

# Fusion's NAT answers DNS itself and drops lookups when many come at once (a Go
# build fetching its modules fails with "no such host"): public resolvers for
# every connection instead.
install -Dm644 /dev/stdin /etc/NetworkManager/conf.d/90-omacvm-fusion.conf <<'CONF'
[global-dns-domain-*]
servers=1.1.1.1,9.9.9.9
CONF
systemctl reload NetworkManager 2>/dev/null || true
