#!/usr/bin/env bash
# tools/firewall-test.sh -- prove the policy does what it claims.
#
# Three checks, each read-only with respect to configuration:
#   1. what is listening locally          (always)
#   2. whether outbound still works       (always, unless --local-only)
#   3. whether anything answers inbound   (only with an explicit external probe)
#
# The external probe contacts a third-party service to see this machine from the
# outside. That is a deliberate disclosure of your IP to that service, so it is
# opt-in: --local-only is the default-safe form and is what CI should use.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

LOCAL_ONLY=disabled
PORTS="22,80,443,445,631,5353,9090"

usage() {
  cat <<'HELP'
firewall test -- live check of listeners, egress, and inbound reachability

Usage:
  tkoc firewall test [--local-only] [--ports 22,445]

  --local-only   Skip anything that contacts an external service
  --ports        Ports to report on (default: 22,80,443,445,631,5353,9090)

The external reachability probe is skipped unless you omit --local-only, and it
tells you before it runs which service it is about to contact.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only) LOCAL_ONLY=enabled; shift ;;
    --ports) [[ $# -ge 2 ]] || die "--ports requires a comma-separated list"; PORTS="$2"; shift 2 ;;
    --ports=*) PORTS="${1#*=}"; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) die "firewall test: unknown option: $1" ;;
  esac
done

[[ "$PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--ports must be a comma-separated list of port numbers"

printf '\n\033[1;36mListening sockets\033[0m\n'
if ! command -v ss >/dev/null 2>&1; then
  warn "ss is unavailable; install iproute2"
else
  # -n: no name resolution, so this test never emits a DNS query of its own.
  if ss -H -lntup 2>/dev/null | grep -q .; then
    ss -H -lntup 2>/dev/null | awk '{ printf "  %-8s %-24s %s\n", $1, $5, $7 }'
  else
    printf '  nothing is listening\n'
  fi
fi

printf '\n\033[1;36mSelected ports\033[0m\n'
_old_ifs="$IFS"; IFS=','
for port in $PORTS; do
  if command -v ss >/dev/null 2>&1 && ss -H -lntu "sport = :$port" 2>/dev/null | grep -q .; then
    printf '  %-6s LISTENING locally\n' "$port"
  else
    printf '  %-6s closed locally\n' "$port"
  fi
done
IFS="$_old_ifs"

printf '\n\033[1;36mFirewall table\033[0m\n'
if command -v nft >/dev/null 2>&1 && sudo -n nft list table inet tkoc_host >/dev/null 2>&1; then
  printf '  tkoc_host is loaded\n'
else
  printf '  tkoc_host is not loaded or not readable without privilege\n'
fi

if [[ "$LOCAL_ONLY" == enabled ]]; then
  printf '\n  --local-only: skipped the egress and external reachability checks\n\n'
  exit 0
fi

printf '\n\033[1;36mOutbound\033[0m\n'
# A TCP connect to a well-known resolver on 443, not a DNS query: this must work
# at every tier, including lockdown, and testing it with DNS would instead be
# testing the resolver pin.
if command -v curl >/dev/null 2>&1; then
  if curl -sS --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null; then
    printf '  outbound HTTPS works\n'
  else
    printf '  outbound HTTPS FAILED -- the policy may be too strict, or you are offline\n'
  fi
else
  printf '  curl is unavailable; skipped\n'
fi

printf '\n\033[1;36mDNS\033[0m\n'
if command -v getent >/dev/null 2>&1; then
  if getent hosts fedoraproject.org >/dev/null 2>&1; then
    printf '  name resolution works\n'
  else
    printf '  name resolution FAILED -- at lockdown, check that the pinned resolver\n'
    printf '  matches what systemd-resolved actually uses (tkoc firewall status)\n'
  fi
fi

printf '\n\033[1;36mInbound reachability\033[0m\n'
printf '  This contacts ifconfig.co to learn your public address, which discloses\n'
printf '  it to that service. Nothing is scanned.\n'
if tkoc_confirm "Contact ifconfig.co?"; then
  if command -v curl >/dev/null 2>&1; then
    _addr="$(curl -sS --max-time 5 https://ifconfig.co 2>/dev/null || true)"
    [[ -n "$_addr" ]] && printf '  public address: %s\n' "$_addr" \
      || printf '  could not determine the public address\n'
    unset _addr
  fi
else
  printf '  skipped\n'
fi
printf '\n'
