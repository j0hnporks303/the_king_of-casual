#!/usr/bin/env bash
# tools/network-profile.sh -- apply the profile matching the current network.
#
# Sets DNS and IPv6 only. It never changes the firewall tier, the nftables
# ruleset, or any service: a posture that relaxed itself because you joined a
# particular Wi-Fi network would be a posture an attacker can select for you by
# naming an access point.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

PROFILES="${TKOC_NETWORK_PROFILES:-$REPO_ROOT/config/network-profiles.json}"

usage() {
  cat <<'HELP'
firewall auto -- apply the DNS/IPv6 profile matching the current network

Usage:
  tkoc firewall auto [--dry-run] [--yes]

Matches the active Wi-Fi SSID against config/network-profiles.json and applies
that profile's DNS and IPv6 settings to the active NetworkManager connection.
Falls back to the "default" block when no profile matches.

It changes DNS and IPv6 and nothing else. The firewall tier, the nftables
ruleset and every service are left exactly as they are.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    help|--help|-h) usage; exit 0 ;;
    *) tkoc_parse_safety_flag "$1" || die "firewall auto: unknown option: $1"; shift ;;
  esac
done

command -v nmcli >/dev/null 2>&1 || die "nmcli is required (NetworkManager)"
command -v python3 >/dev/null 2>&1 || die "python3 is required to read the profile file"
[[ -r "$PROFILES" ]] || die "profile file not found: $PROFILES"

interface="${TKOC_NETWORK_INTERFACE:-}"
[[ -z "$interface" ]] || tkoc_valid_interface "$interface" || die "invalid network interface: $interface"
wifi_args=(--rescan no)
[[ -z "$interface" ]] || wifi_args+=(ifname "$interface")
ssid="$(nmcli -t -e no -f active,ssid dev wifi list "${wifi_args[@]}" 2>/dev/null \
  | sed -n 's/^yes://p' | sed -n '1p' || true)"
# UUIDs avoid escaped colons and backslashes in connection names. A dispatcher
# event must only configure the interface that triggered it.
connection="$(nmcli -t -f UUID,TYPE,DEVICE connection show --active 2>/dev/null \
  | awk -F: -v iface="$interface" '$2 ~ /wireless|ethernet/ && (iface == "" || $3 == iface) { print $1; exit }' || true)"
[[ -n "$connection" ]] || die "no active NetworkManager connection to configure"

# The profile lookup is a read of a local JSON file; the values it yields are
# validated below before any of them reaches nmcli.
matched="$(python3 - "$PROFILES" "$ssid" <<'PY'
import json, sys
path, ssid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
chosen = None
for p in data.get("profiles", []):
    if p.get("ssid") and p["ssid"] == ssid:
        chosen = p
        break
if chosen is None:
    d = data.get("default", {})
    chosen = {"name": "default", "dns": d.get("dns", ""), "ipv6": d.get("ipv6", "disabled")}
for value in (chosen.get("name", "default"), chosen.get("dns", ""), chosen.get("ipv6", "disabled")):
    if not isinstance(value, str) or "\n" in value or "\r" in value:
        sys.exit("profile values must be single-line strings")
    print(value)
PY
)"

# Tabs are IFS whitespace: read collapses an empty DNS field into the next
# column. Read separate lines so the shipped DHCP/default profile stays valid.
{
  IFS= read -r profile_name
  IFS= read -r profile_dns
  IFS= read -r profile_ipv6
} <<<"$matched"

# Everything read from the profile file is treated as untrusted input.
[[ -z "$profile_dns" ]] || tkoc_valid_ipv4 "$profile_dns" \
  || die "profile '$profile_name' has an invalid DNS address: $profile_dns"
case "$profile_ipv6" in
  enabled|disabled) ;;
  *) die "profile '$profile_name' has an invalid ipv6 value: $profile_ipv6" ;;
esac

printf '\n'
log "network:    ${ssid:-(wired or unknown)}"
log "connection: $connection"
log "profile:    $profile_name"
log "dns:        ${profile_dns:-(leave as DHCP provides)}"
log "ipv6:       $profile_ipv6"
printf '\n'

if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  log "dry run: nothing was changed"
  exit 0
fi

tkoc_confirm "Apply this profile's DNS and IPv6 to '$connection'?" \
  || { log "Aborted. Nothing changed."; exit 0; }

desired_ignore=no
[[ -z "$profile_dns" ]] || desired_ignore=yes
desired_ipv6=auto
[[ "$profile_ipv6" != disabled ]] || desired_ipv6=disabled
current_dns="$(nmcli -g ipv4.dns connection show -- "$connection")"
current_ignore="$(nmcli -g ipv4.ignore-auto-dns connection show -- "$connection")"
current_ipv6="$(nmcli -g ipv6.method connection show -- "$connection")"
if [[ "$current_dns" == "$profile_dns" && "$current_ignore" == "$desired_ignore" && "$current_ipv6" == "$desired_ipv6" ]]; then
  log "profile '$profile_name' is already applied"
  exit 0
fi

owns_snapshot=disabled
if [[ -z "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
  tkoc_state_begin "tkoc firewall auto" >/dev/null
  owns_snapshot=enabled
  log "Recovery snapshot: $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT")"
fi

tkoc_state_capture_nm_dns "$connection"
tkoc_state_capture_nm_ipv6 "$connection"

if [[ -n "$profile_dns" ]]; then
  run_root nmcli connection modify -- "$connection" ipv4.dns "$profile_dns"
  run_root nmcli connection modify -- "$connection" ipv4.ignore-auto-dns yes
else
  run_root nmcli connection modify -- "$connection" ipv4.dns ""
  run_root nmcli connection modify -- "$connection" ipv4.ignore-auto-dns no
fi

if [[ "$profile_ipv6" == disabled ]]; then
  run_root nmcli connection modify -- "$connection" ipv6.method disabled
else
  run_root nmcli connection modify -- "$connection" ipv6.method auto
fi

if [[ -n "$interface" ]]; then
  # Reapply in place in a dispatcher. Reactivating the connection here queues
  # another up event and can interrupt the network on every DHCP renewal.
  run_root nmcli device reapply "$interface" >/dev/null
else
  run_root nmcli connection up -- "$connection" >/dev/null
fi
[[ "$owns_snapshot" == enabled ]] && tkoc_state_finish
log "profile '$profile_name' applied"
