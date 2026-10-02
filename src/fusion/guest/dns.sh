#!/bin/bash
# Public DNS on VMware Fusion. Runs as root in the VM; omacvm build runs it
# before the Omarchy install, install.sh on every apply.
# Fusion's NAT answers DNS itself and drops lookups when many come at once (a Go
# build fetching its modules fails with "no such host"): public resolvers for
# every connection instead.
set -euo pipefail
install -Dm644 /dev/stdin /etc/NetworkManager/conf.d/90-omacvm-fusion.conf <<'CONF'
[global-dns-domain-*]
servers=1.1.1.1,9.9.9.9
CONF
systemctl reload NetworkManager 2>/dev/null || true
