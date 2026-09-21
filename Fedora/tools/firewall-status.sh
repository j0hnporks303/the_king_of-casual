#!/usr/bin/env bash
# tools/firewall-status.sh -- what the firewall actually looks like right now.
# Read-only. Uses sudo -n only where the kernel requires it, and says so rather
# than prompting when it cannot read the live ruleset.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

LIVE_NFT="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"

usage() {
  cat <<'HELP'
firewall status -- show the live nftables posture

Usage:
  tkoc firewall status

Reports whether the tkoc_host table is loaded, which tier markers the installed
policy has active, whether nftables.service will restore it at boot, whether
firewalld is competing for the ruleset, and the current drop counters.
Read-only.
HELP
}

[[ "${1:-}" == help || "${1:-}" == --help || "${1:-}" == -h ]] && { usage; exit 0; }

line() { printf '  %-34s %s\n' "$1" "$2"; }

printf '\nInstalled policy\n'
# "cannot read it" and "it is not there" are different answers, and reporting
# the first as the second told people their firewall was not installed when it
# was.
if [[ -e "$LIVE_NFT" && ! -r "$LIVE_NFT" ]]; then
  line "policy file" "$LIVE_NFT (not readable by you; try: sudo tkoc firewall status)"
elif [[ -r "$LIVE_NFT" ]]; then
  line "policy file" "$LIVE_NFT"
  # Which tier a machine is on is readable from the policy itself: each tier
  # leaves its markers commented or live, so this needs no recorded state.
  lan=$(grep -cE '^\s+udp dport \{ 137, 138' "$LIVE_NFT" || true)
  ipv6=$(grep -cE '^\s+meta nfproto ipv6' "$LIVE_NFT" || true)
  dns=$(grep -cE '^\s+ip daddr \$ALLOWED_DNS4' "$LIVE_NFT" || true)
  ssh=$(grep -cE '^\s+ip saddr \$SSH_SOURCE' "$LIVE_NFT" || true)
  line "LAN discovery blocked" "$([ "${lan:-0}" -gt 0 ] && echo yes || echo no)"
  line "off-host IPv6 blocked" "$([ "${ipv6:-0}" -gt 0 ] && echo yes || echo no)"
  line "DNS pinned to a resolver" "$([ "${dns:-0}" -gt 0 ] && echo yes || echo no)"
  line "inbound SSH carve-out" "$([ "${ssh:-0}" -gt 0 ] && echo yes || echo no)"
  if [ "${dns:-0}" -gt 0 ]; then
    line "allowed resolver" "$(awk -F'[{}]' '/^define ALLOWED_DNS4/ { gsub(/ /, "", $2); print $2; exit }' "$LIVE_NFT")"
  fi
  if [ "${ssh:-0}" -gt 0 ]; then
    line "ssh source" "$(awk -F'[{}]' '/^define SSH_SOURCE/ { gsub(/ /, "", $2); print $2; exit }' "$LIVE_NFT")"
  fi
  # Inferred tier, in the same order the stage decides it.
  if [ "${dns:-0}" -gt 0 ]; then tier=lockdown
  elif [ "${lan:-0}" -gt 0 ]; then tier=strong
  else tier=vanilla; fi
  line "inferred tier" "$tier"
elif [[ -d "$(dirname -- "$LIVE_NFT")" ]]; then
  line "policy file" "absent from $(dirname -- "$LIVE_NFT") (run: tkoc firewall strong)"
else
  line "policy file" "not installed; $(dirname -- "$LIVE_NFT") does not exist (run: tkoc firewall strong)"
fi

printf '\nBoot persistence\n'
if command -v systemctl >/dev/null 2>&1; then
  line "nftables.service enabled" "$(systemctl is-enabled nftables.service 2>/dev/null || echo 'not installed')"
  line "nftables.service active" "$(systemctl is-active nftables.service 2>/dev/null || echo inactive)"
  line "firewalld" "$(systemctl is-active firewalld.service 2>/dev/null || echo 'inactive (good)')"
else
  line "systemd" "unavailable"
fi
_sysconfig="${TKOC_TEST_ROOT:-}/etc/sysconfig/nftables.conf"
if [[ -e "$_sysconfig" ]]; then
  # This file is 0600 root:root on Fedora, so an ordinary user cannot grep it.
  if _contents="$(read_root_file "$_sysconfig")"; then
    if grep -Fq 'include "/etc/nftables/tkoc.nft"' <<<"$_contents"; then
      line "include wired up" "yes"
    else
      line "include wired up" "NO -- policy will not load at boot"
    fi
  else
    line "include wired up" "unknown (needs privilege to read $_sysconfig)"
  fi
fi
unset _sysconfig _contents

printf '\nLive ruleset\n'
if ! command -v nft >/dev/null 2>&1; then
  line "nft" "not installed"
elif sudo -n nft list table inet tkoc_host >/dev/null 2>&1; then
  line "tkoc_host table" "loaded"
  printf '\n  counters:\n'
  sudo -n nft -a list table inet tkoc_host 2>/dev/null \
    | awk '/^\t*counter [a-z_]+ \{/ { name=$2 } /packets [0-9]+ bytes [0-9]+/ {
        for (i=1;i<=NF;i++) if ($i=="packets") p=$(i+1)
        for (i=1;i<=NF;i++) if ($i=="bytes") b=$(i+1)
        if (name != "" && p+0 > 0) printf "    %-28s %s packets\n", name, p
        name=""
      }'
else
  line "tkoc_host table" "not readable without privilege (try: sudo tkoc firewall status)"
fi
printf '\n'
