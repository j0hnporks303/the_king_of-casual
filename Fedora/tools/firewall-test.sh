#!/usr/bin/env bash
# tools/firewall-test.sh -- prove the policy does what it claims.
#
# Checks are read-only with respect to configuration:
#   1. what is listening locally          (always)
#   2. whether outbound still works       (always, unless --local-only)
#   3. whether inbound packets hit the default drop (explicit LAN probe)
#
# The optional public IP lookup contacts a third-party service. --local-only
# avoids that disclosure; --inbound-check uses a second LAN device instead.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

LOCAL_ONLY=disabled
INBOUND_CHECK=disabled
INBOUND_PORT=65000
PORTS="22,80,443,445,631,5353,9090"

usage() {
  cat <<'HELP'
firewall test -- live check of listeners, egress, and inbound drops

Usage:
  tkoc firewall test [--local-only] [--ports 22,445]
  tkoc firewall test --inbound-check [port]

  --local-only   Skip anything that contacts an external service
  --ports        Ports to report on (default: 22,80,443,445,631,5353,9090)
  --inbound-check [port]
                Compare the input drop counter around a probe from another LAN
                device (default TCP port: 65000). Requires sudo to read nftables.

The normal test offers a public IP lookup through ifconfig.co unless --local-only
is given. The inbound check contacts no external service from this machine.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only) LOCAL_ONLY=enabled; shift ;;
    --inbound-check)
      INBOUND_CHECK=enabled; shift
      if [[ $# -gt 0 && "$1" != --* ]]; then INBOUND_PORT="$1"; shift; fi
      ;;
    --ports) [[ $# -ge 2 ]] || die "--ports requires a comma-separated list"; PORTS="$2"; shift 2 ;;
    --ports=*) PORTS="${1#*=}"; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) die "firewall test: unknown option: $1" ;;
  esac
done

[[ "$PORTS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--ports must be a comma-separated list of port numbers"
[[ "$INBOUND_PORT" =~ ^[0-9]+$ ]] && (( 10#$INBOUND_PORT >= 1 && 10#$INBOUND_PORT <= 65535 )) \
  || die "--inbound-check port must be between 1 and 65535"

read_input_drops() {
  local result
  command -v nft >/dev/null 2>&1 || die "nft is unavailable"
  if (( EUID == 0 )); then
    result="$(nft list counter inet tkoc_host input_dropped)" \
      || die "cannot read the tkoc input drop counter"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is unavailable"
    result="$(sudo nft list counter inet tkoc_host input_dropped)" \
      || die "cannot read the tkoc input drop counter"
  fi
  printf '%s\n' "$result" | awk '
    $1 == "packets" { print $2; found = 1; exit }
    END { if (!found) exit 1 }
  ' || die "nft returned no input drop packet count"
}

if [[ "$INBOUND_CHECK" == enabled ]]; then
  before="$(read_input_drops)"
  printf '\nInbound drop check (TCP/%s)\n' "$INBOUND_PORT"
  printf '  input_dropped before: %s packets\n' "$before"
  printf '  LAN addresses to try:\n'
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{ printf "    %s  %s\n", $2, $4 }' || true
  printf '\n  From a DIFFERENT device on the same LAN, run:\n'
  printf '    nc -vz -w 2 <this-machine-LAN-IP> %s\n' "$INBOUND_PORT"
  printf '  A timeout is expected. Press Enter here after the probe.\n'
  IFS= read -r _confirmation || die "inbound check needs a terminal after the LAN probe"
  after="$(read_input_drops)"
  printf '  input_dropped after:  %s packets\n' "$after"
  if (( after > before )); then
    printf '  %s new drop(s): consistent with the LAN probe reaching this firewall.\n' "$((after - before))"
    printf '  Other inbound traffic may also have contributed to this count.\n'
  else
    printf '  No new drops: the probe did not reach this rule, or was accepted earlier.\n'
    printf '  Check the address, port, LAN path, and whether another rule accepts it.\n'
  fi
  exit 0
fi

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
