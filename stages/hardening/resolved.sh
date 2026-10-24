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

_root="${TKOC_TEST_ROOT:-}"

# At the lockdown tier the firewall pins port 53 to the resolvers given with
# --dns, and drops DNS-over-TLS on 853 unless --dns-over-tls opened it to those
# same resolvers. Resolved has to agree with both, or every lookup goes to a
# resolver or a port the firewall then drops, and name resolution simply stops.
# `tkoc harden` hands both stages the same values; that is the dependable way
# to keep them in step.
#
# Every setting below is the operator's to choose. The defaults -- plain DNS,
# DNSSEC when the resolver supports it -- are the ones that work behind any
# resolver; stricter choices are offered, never assumed.
_dot="${TKOC_DNS_OVER_TLS:-no}"
_dnssec="${TKOC_DNSSEC:-allow-downgrade}"
tkoc_valid_dns_over_tls "$_dot" \
  || die "TKOC_DNS_OVER_TLS must be yes, opportunistic, or no, got: $_dot"
tkoc_valid_dnssec "$_dnssec" \
  || die "TKOC_DNSSEC must be yes, allow-downgrade, or no, got: $_dnssec"

_conf="# Managed by tkoc: resolution policy matching the lockdown firewall tier.
[Resolve]
DNSOverTLS=$_dot
DNSSEC=$_dnssec
MulticastDNS=no
LLMNR=no
Cache=no-negative"

_dns="${ROUTER_DNS:-${TKOC_DNS4:-}}"
if [[ -n "$_dns" ]]; then
  tkoc_parse_dns_list "$_dns"
  _conf="$_conf
DNS=${TKOC_DNS_SERVERS[*]}
Domains=~."
  step "pinning resolved to ${TKOC_DNS_SERVERS[*]} to match the firewall"
else
  step "no resolver given; leaving DNS servers to NetworkManager"
fi

# Strict modes fail closed, which is the point of them, and also the way they
# surprise people: a resolver that cannot do it resolves nothing at all.
if [[ "$_dot" == yes ]]; then
  wrn "DNS-over-TLS is strict: no fallback to plain DNS, so every resolver must answer on TCP/853"
fi
if [[ "$_dnssec" == yes ]]; then
  wrn "DNSSEC is strict: badly signed zones, and anything behind a resolver that strips DNSSEC records, fail to resolve"
fi
unset _dns _dot _dnssec

hc_drop_in "$_root"/etc/systemd/resolved.conf.d 90-tkoc-lockdown.conf "$_conf" "resolved policy"
unset _conf _root

if unit_active systemd-resolved.service && tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  # The run_root preview line is swallowed by the redirect below, so say it here
  # rather than reporting a restart that never happened.
  step "[dry-run] would restart systemd-resolved"
elif unit_active systemd-resolved.service; then
  run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 \
    && ok "restarted systemd-resolved" \
    || wrn "could not restart systemd-resolved; the policy applies at next boot"
fi

summary
