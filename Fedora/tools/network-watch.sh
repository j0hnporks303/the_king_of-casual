#!/usr/bin/env bash
# tools/network-watch.sh -- install/remove the automatic network-profile hook.
#
# Installs a root-owned NetworkManager dispatcher script that re-applies the
# matching profile's DNS and IPv6 every time the machine joins a network.
#
# What it deliberately never does, in the dispatcher and here: touch the
# firewall tier, the nftables ruleset, or any service state. The dispatcher runs
# unattended and is triggered by joining a network, so anything it could change
# is something an access point can make it change.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/persistence.sh
source "$REPO_ROOT/stages/lib/persistence.sh"

DISPATCHER="$TKOC_DISPATCHER_DIR/90-tkoc-network-watch"
PROFILES_DST="$TKOC_PERSISTENCE_DIR/network-profiles.json"
HELPER_DST="$TKOC_PERSISTENCE_DIR/network-profile.sh"
LOG_FILE="/var/log/tkoc-network-watch.log"

usage() {
  cat <<'HELP'
firewall watch -- automatic per-network DNS and IPv6

Usage:
  tkoc firewall watch install     Install the NetworkManager dispatcher
  tkoc firewall watch uninstall   Remove it
  tkoc firewall watch status      Show whether it is installed

The dispatcher runs as root on every network change and applies only the DNS
and IPv6 from the profile matching the new network. It never changes the
firewall tier, the nftables ruleset, or any service.

Its copies of the profile file and the helper are root-owned, under
/usr/local/libexec/tkoc, so a process running as you cannot rewrite what root
is about to execute.
HELP
}

cmd_status() {
  printf '  %-30s %s\n' "dispatcher" \
    "$([[ -f "$DISPATCHER" ]] && printf 'installed at %s' "$DISPATCHER" || printf 'not installed')"
  printf '  %-30s %s\n' "profiles" \
    "$([[ -f "$PROFILES_DST" ]] && printf '%s' "$PROFILES_DST" || printf 'not installed')"
  if command -v systemctl >/dev/null 2>&1; then
    printf '  %-30s %s\n' "NetworkManager-dispatcher" \
      "$(systemctl is-enabled NetworkManager-dispatcher.service 2>/dev/null || printf unknown)"
  fi
  [[ -f "$LOG_FILE" ]] && printf '  %-30s %s\n' "log" "$LOG_FILE"
  return 0
}

cmd_install() {
  need_supported_fedora
  command -v nmcli >/dev/null 2>&1 || die "nmcli is required (NetworkManager)"

  printf '\n'
  printf 'This installs a root-owned script that NetworkManager runs on every\n'
  printf 'network change. It sets DNS and IPv6 from config/network-profiles.json\n'
  printf 'and nothing else -- never the firewall tier, the ruleset, or a service.\n\n'
  tkoc_confirm "Install the network-watch dispatcher?" \
    || { log "Aborted. Nothing installed."; return 0; }

  tkoc_install_privileged_file "$REPO_ROOT/config/network-profiles.json" "$PROFILES_DST" 0644
  tkoc_install_privileged_file "$REPO_ROOT/tools/network-profile.sh" "$HELPER_DST" 0755

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-dispatch.XXXXXX")"
  cat > "$tmp" <<'DISPATCH'
#!/usr/bin/env bash
# Managed by tkoc. Do not edit; reinstall with: tkoc firewall watch install
#
# NetworkManager runs this as root on every connectivity change. It applies the
# DNS and IPv6 from the matching profile and nothing else.
set -Eeuo pipefail

interface="${1:-}"
action="${2:-}"
case "$action" in
  up|dhcp4-change|dhcp6-change|connectivity-change) ;;
  *) exit 0 ;;
esac

export TKOC_UPDATE_YES=enabled
export TKOC_NETWORK_PROFILES=/usr/local/libexec/tkoc/network-profiles.json
export HOME=/root

{
  printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$interface" "$action"
  /usr/bin/env bash /usr/local/libexec/tkoc/network-profile.sh 2>&1 || true
} >> /var/log/tkoc-network-watch.log 2>&1
DISPATCH
  tkoc_install_privileged_file "$tmp" "$DISPATCHER" 0755
  rm -f -- "$tmp"

  if [[ -z "${TKOC_TEST_ROOT:-}" ]] && command -v systemctl >/dev/null 2>&1; then
    run_root systemctl enable --now NetworkManager-dispatcher.service >/dev/null 2>&1 || true
  fi
  log "network-watch installed; it logs to $LOG_FILE"
}

cmd_uninstall() {
  tkoc_remove_privileged_file "$DISPATCHER"
  tkoc_remove_privileged_file "$PROFILES_DST"
  tkoc_remove_privileged_file "$HELPER_DST"
  log "network-watch removed. The DNS and IPv6 it last set are unchanged;"
  log "restore them from a snapshot, or with: tkoc firewall auto"
}

main() {
  local sub="${1:-status}"
  (( $# > 0 )) && shift
  while [[ $# -gt 0 ]]; do
    tkoc_parse_safety_flag "$1" || die "firewall watch: unknown option: $1"
    shift
  done
  case "$sub" in
    install)   cmd_install ;;
    uninstall|remove) cmd_uninstall ;;
    status)    cmd_status ;;
    help|--help|-h) usage ;;
    *) die "Usage: tkoc firewall watch [install|uninstall|status]" ;;
  esac
}

main "$@"
