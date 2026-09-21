#!/usr/bin/env bash
# resolved.sh -- pin DNS resolution to match the firewall tier
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "DNS resolution"

if ! unit_exists systemd-resolved.service; then
  skip "systemd-resolved is not installed; DNS is handled elsewhere"
  tally_skip
  summary
  exit 0
fi

# At the lockdown tier the firewall pins port 53 to one resolver and drops
# DNS-over-TLS on 853. Resolved has to agree with that, or every lookup goes to
# a resolver the firewall then drops, and name resolution simply stops.
#
# DNSOverTLS=no is therefore not a weakening: it is what makes the firewall's
# 853 block and the resolver pin coherent. Encrypted DNS to a resolver of your
# choosing is a valid posture, but it is the opposite of this tier's, and mixing
# the two yields a machine that cannot resolve anything.
_dns="${ROUTER_DNS:-${TKOC_DNS4:-}}"
_conf='# Managed by tkoc: resolution policy matching the lockdown firewall tier.
[Resolve]
DNSOverTLS=no
DNSSEC=allow-downgrade
MulticastDNS=no
LLMNR=no
Cache=no-negative'

if [[ -n "$_dns" ]]; then
  _conf="$_conf
DNS=$_dns
Domains=~."
  step "pinning resolved to $_dns to match the firewall"
else
  step "no resolver given; leaving DNS servers to NetworkManager"
fi
unset _dns

hc_drop_in /etc/systemd/resolved.conf.d 90-tkoc-lockdown.conf "$_conf" "resolved policy"
unset _conf

if unit_active systemd-resolved.service; then
  run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 \
    && ok "restarted systemd-resolved" \
    || wrn "could not restart systemd-resolved; the policy applies at next boot"
fi

summary
