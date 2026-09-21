#!/usr/bin/env bash
# tools/network-learn.sh -- record the network you are on now as a profile.
#
# Captures the SSID, BSSID and gateway of the current Wi-Fi connection into
# config/network-profiles.json. It shows what it found and asks before saving;
# nothing is written to the system.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

PROFILES="$REPO_ROOT/config/network-profiles.json"

usage() {
  cat <<'HELP'
firewall learn -- capture the current network as a named profile

Usage:
  tkoc firewall learn [--name home]

Reads the active Wi-Fi SSID, BSSID and gateway from NetworkManager and writes
them into config/network-profiles.json under the given name (default: home).
It prints what it found and asks before saving. Nothing outside the checkout
is touched.
HELP
}

NAME=home
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) [[ $# -ge 2 ]] || die "--name requires a profile name"; NAME="$2"; shift 2 ;;
    --name=*) NAME="${1#*=}"; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) tkoc_parse_safety_flag "$1" || die "firewall learn: unknown option: $1"; shift ;;
  esac
done
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "profile name must be alphanumeric: $NAME"

command -v nmcli >/dev/null 2>&1 || die "nmcli is required (NetworkManager)"

ssid="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || true)"
bssid="$(nmcli -t -f active,bssid dev wifi 2>/dev/null | awk -F'active:' '/^yes:/{print substr($0,5); exit}' || true)"
bssid="${bssid#yes:}"
gateway="$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}' || true)"
dns="$(resolvectl dns 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1 || true)"

printf '\nCurrent network\n'
printf '  %-10s %s\n' "profile" "$NAME"
printf '  %-10s %s\n' "ssid" "${ssid:-(not on Wi-Fi)}"
printf '  %-10s %s\n' "bssid" "${bssid:-unknown}"
printf '  %-10s %s\n' "gateway" "${gateway:-unknown}"
printf '  %-10s %s\n' "dns" "${dns:-(none detected upstream)}"
printf '\n'

[[ -n "$ssid" ]] || die "no active Wi-Fi connection to learn"

if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  log "dry run: $PROFILES was not modified"
  exit 0
fi

tkoc_confirm "Save this as profile '$NAME' in config/network-profiles.json?" \
  || { log "Aborted. Nothing saved."; exit 0; }

python3 - "$PROFILES" "$NAME" "$ssid" "$bssid" "$gateway" "$dns" <<'PY'
import json, sys
path, name, ssid, bssid, gateway, dns = sys.argv[1:7]
with open(path) as fh:
    data = json.load(fh)
profiles = data.setdefault("profiles", [])
entry = next((p for p in profiles if p.get("name") == name), None)
if entry is None:
    entry = {"name": name}
    profiles.append(entry)
entry.update({"ssid": ssid, "bssid": bssid, "gateway": gateway,
              "dns": dns, "ipv6": entry.get("ipv6", "disabled")})
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("saved profile %r" % name)
PY
log "edit $PROFILES to set the DNS and IPv6 you want for this network"
