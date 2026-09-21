#!/usr/bin/env bash
# tools/uav.sh -- universal port and network analysis.
#
# Inspects what this machine already knows about its own ports: local listeners,
# container publications, the nftables policy, and NAT/forwarding state. It
# performs no external scanning of anything.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

note() { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

usage() {
  cat <<'HELP'
uav -- port status and reachability, from what this machine already knows

Usage:
  tkoc uav [IP][:PORT]              Check one port (or one host's port)
  tkoc uav show all                 Every local listener, with its owner
  tkoc uav show containers          Ports published by podman/docker
  tkoc uav show firewall            What the tkoc policy allows inbound
  tkoc uav detect forwarding        NAT and IP-forwarding state

With no arguments this prints the full report. Nothing here scans a remote
host; every answer comes from local kernel and daemon state.
HELP
}

# ── Listeners ───────────────────────────────────────────────────

show_listeners() {
  head_ "Local listeners"
  if ! command -v ss >/dev/null 2>&1; then
    note "ss is unavailable; install iproute2"
    return 0
  fi
  # Process names need privilege. Without it, ss still reports the sockets, so
  # report those rather than refusing or prompting for a password.
  local out
  out="$(ss -H -lntupn 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    note "nothing is listening"
    return 0
  fi
  printf '  %-6s %-26s %s\n' PROTO ADDRESS PROCESS
  printf '%s\n' "$out" | awk '{
    proto=$1; addr=$5; proc=""
    for (i=6; i<=NF; i++) proc = proc (proc=="" ? "" : " ") $i
    if (proc == "") proc = "(needs privilege to name)"
    printf "  %-6s %-26s %s\n", proto, addr, proc
  }'

  # A listener on 0.0.0.0 or [::] is reachable from off-host if anything in the
  # firewall lets it through; one on 127.0.0.1 is not. That distinction is the
  # single most useful thing in this report.
  local public
  public="$(printf '%s\n' "$out" | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ { print $5 }' | sort -u)"
  if [[ -n "$public" ]]; then
    printf '\n'
    note "bound to all interfaces (reachable if the firewall permits):"
    printf '%s\n' "$public" | sed 's/^/    /'
  fi
}

# ── Containers ──────────────────────────────────────────────────

show_containers() {
  head_ "Container published ports"
  local found=0 engine
  for engine in podman docker; do
    command -v "$engine" >/dev/null 2>&1 || continue
    local out
    out="$("$engine" ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)"
    [[ -n "$out" ]] || continue
    found=1
    printf '  %s:\n' "$engine"
    printf '%s\n' "$out" | while IFS=$'\t' read -r name ports; do
      [[ -n "$ports" ]] || continue
      printf '    %-24s %s\n' "$name" "$ports"
      # A published port bound to 0.0.0.0 bypasses expectations set by the host
      # firewall, because the container runtime inserts its own DNAT rules.
      case "$ports" in
        *0.0.0.0:*|*:::*)
          printf '    %-24s %s\n' "" "^ published on all interfaces" ;;
      esac
    done
  done
  (( found )) || note "no running containers, or no container engine installed"
}

# ── Firewall view ───────────────────────────────────────────────

show_firewall() {
  head_ "Inbound allowed by the tkoc policy"
  local live="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"
  if [[ ! -r "$live" ]]; then
    note "no tkoc policy is installed (run: tkoc firewall strong)"
    return 0
  fi
  # Report from the installed policy rather than the live table so this works
  # without privilege; `tkoc firewall status` shows the live one.
  local allows
  allows="$(grep -nE '^\s+(ip saddr \$SSH_SOURCE|udp dport \$WG_PORT|tcp dport [0-9]+ ct state new)' "$live" || true)"
  if [[ -n "$allows" ]]; then
    printf '%s\n' "$allows" | sed 's/^/    /'
  else
    note "no inbound service carve-outs; the input chain is default-deny"
  fi
  note "DHCP replies and rate-limited ICMP are always permitted."
}

# ── Forwarding ──────────────────────────────────────────────────

detect_forwarding() {
  head_ "Forwarding and NAT"
  local v4 v6
  v4="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf unknown)"
  v6="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || printf unknown)"
  printf '  %-30s %s\n' "net.ipv4.ip_forward" "$v4"
  printf '  %-30s %s\n' "net.ipv6.conf.all.forwarding" "$v6"
  if [[ "$v4" == 1 ]]; then
    note "IPv4 forwarding is on. That is normal with containers or VMs running,"
    note "and means this host routes for them -- check the forward chain."
  fi

  if command -v nft >/dev/null 2>&1 && sudo -n nft list ruleset >/dev/null 2>&1; then
    local nat
    nat="$(sudo -n nft list ruleset 2>/dev/null | grep -cE 'masquerade|dnat to' || true)"
    printf '  %-30s %s\n' "NAT rules in the ruleset" "${nat:-0}"
  else
    note "the live ruleset needs privilege to read (sudo tkoc uav detect forwarding)"
  fi

  head_ "Bridges"
  if command -v ip >/dev/null 2>&1; then
    ip -brief link show type bridge 2>/dev/null | sed 's/^/    /' \
      || note "no bridge interfaces"
  fi
}

# ── Single port ─────────────────────────────────────────────────

check_port() {
  local target="$1" host="" port=""
  if [[ "$target" == *:* ]]; then
    host="${target%%:*}"; port="${target##*:}"
  else
    port="$target"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || die "not a port number: $target"
  (( port >= 1 && port <= 65535 )) || die "port out of range: $port"
  [[ -z "$host" ]] || tkoc_valid_ipv4 "$host" || die "not an IPv4 address: $host"

  head_ "Port $port${host:+ on $host}"

  if [[ -z "$host" ]]; then
    if command -v ss >/dev/null 2>&1; then
      local found
      found="$(ss -H -lntupn "sport = :$port" 2>/dev/null || true)"
      if [[ -n "$found" ]]; then
        note "LISTENING locally:"
        printf '%s\n' "$found" | sed 's/^/    /'
      else
        note "nothing is listening on $port locally"
      fi
    fi
    local live="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"
    if [[ ! -r "$live" ]]; then
      note "no tkoc policy is installed, so nothing here governs $port"
    elif grep -qE "^[[:space:]]+.*dport.*[^0-9]${port}([^0-9]|$).*accept" "$live"; then
      note "the tkoc policy has an explicit inbound accept for $port"
    else
      note "the tkoc policy has no inbound accept for $port (default-deny applies)"
    fi
  else
    # Connecting out to a host:port is the only network action here, and it is
    # exactly what the user asked for by naming a host.
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 3 "$host" "$port" 2>/dev/null; then
        note "$host:$port accepted a connection"
      else
        note "$host:$port did not accept a connection"
      fi
    else
      note "nc is unavailable; install nmap-ncat to probe a remote port"
    fi
  fi
}

# ── Main ────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    help|--help|-h) usage; exit 0 ;;
    show)
      case "${2:-all}" in
        all)        show_listeners; show_containers ;;
        containers) show_containers ;;
        firewall)   show_firewall ;;
        *) die "uav show: unknown target '${2:-}'. Try: all, containers, firewall" ;;
      esac
      ;;
    detect)
      case "${2:-forwarding}" in
        forwarding|nat) detect_forwarding ;;
        *) die "uav detect: unknown target '${2:-}'. Try: forwarding" ;;
      esac
      ;;
    "")
      show_listeners; show_containers; show_firewall; detect_forwarding ;;
    *) check_port "$1" ;;
  esac
  printf '\n'
}

main "$@"
