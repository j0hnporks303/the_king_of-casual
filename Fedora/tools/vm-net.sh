#!/usr/bin/env bash
# tools/vm-net.sh -- let VM and container guests reach the internet, or not.
#
# The forward chain in config/firewall/tkoc.nft carries a marked block that
# accepts guest-originated traffic on libvirt, docker, podman, incus and generic
# bridges. This toggles that block in the INSTALLED policy and reloads, so the
# choice survives a reboot. Re-applying a firewall tier resets it to on, because
# the tier's template is the source of truth.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

LIVE_NFT="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"
BEGIN_MARKER='# TKOC_VM_NET_BEGIN'
END_MARKER='# TKOC_VM_NET_END'

usage() {
  cat <<'HELP'
vm net -- toggle guest network passthrough in the installed firewall policy

Usage:
  tkoc vm net on       Let VM/container guests reach the internet
  tkoc vm net off      Block guest-originated forwarding
  tkoc vm net status   Show the current state

Covers virbr* (libvirt), docker*, podman*, cni-podman*, incusbr*, vboxnet* and
br-* interfaces. The toggle edits the marked block in /etc/nftables/tkoc.nft and
reloads, so it survives a reboot. Re-applying a firewall tier resets it to on.
HELP
}

# POLICY_BODY is filled here and reused, so the file is read once and through
# the privileged reader -- /etc/nftables is root-only on Fedora.
POLICY_BODY=""
require_policy() {
  local prompting="${1:-quiet}"
  if [[ "$prompting" == prompting ]]; then
    POLICY_BODY="$(read_root_file "$LIVE_NFT" 2>/dev/null)" || POLICY_BODY=""
  else
    POLICY_BODY="$(read_root_file_quiet "$LIVE_NFT" 2>/dev/null)" || POLICY_BODY=""
  fi
  if [[ -z "$POLICY_BODY" ]]; then
    if root_path_exists "$LIVE_NFT"; then
      die "the firewall policy at $LIVE_NFT needs privilege to read (try: sudo \"\$(command -v tkoc)\" vm net status)"
    fi
    die "no firewall policy is installed at $LIVE_NFT (run: tkoc firewall strong)"
  fi
  grep -Fq "$BEGIN_MARKER" <<<"$POLICY_BODY" \
    || die "the installed policy has no VM block; re-apply a tier to refresh it"
}

# "on" when at least one accept inside the block is live (not commented).
current_state() {
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0; next }
    inside && /^[[:space:]]+iifname/ { live = 1 }
    END { print (live ? "on" : "off") }
  ' <<<"$POLICY_BODY"
}

set_state() {
  local want="$1" tmp
  local now; now="$(current_state)"
  if [[ "$now" == "$want" ]]; then
    log "guest network passthrough is already $want"
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "[dry-run] would turn guest network passthrough $want in $LIVE_NFT"
    return 0
  fi

  tkoc_state_capture_file "$LIVE_NFT"
  tkoc_state_capture_nftables "inet tkoc_host"

  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-vmnet.XXXXXX")"
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" -v want="$want" '
    index($0, b) { inside = 1; print; next }
    index($0, e) { inside = 0; print; next }
    inside {
      if (want == "off") {
        # Comment out the rules, preserving them verbatim so "on" can restore
        # exactly what the tier rendered rather than a reconstruction.
        if ($0 ~ /^[[:space:]]+(iifname|oifname)/) { print "        # TKOC_VM_OFF:" $0; next }
      } else {
        if ($0 ~ /^[[:space:]]*# TKOC_VM_OFF:/) {
          sub(/^[[:space:]]*# TKOC_VM_OFF:/, "", $0); print; next
        }
      }
      print; next
    }
    { print }
  ' <<<"$POLICY_BODY" > "$tmp"

  tkoc_validate_nft "$tmp" privileged
  run_root_path "$LIVE_NFT" install -m 0600 -- "$tmp" "$LIVE_NFT"
  rm -f -- "$tmp"

  if command -v nft >/dev/null 2>&1 && [[ -z "${TKOC_TEST_ROOT:-}" ]]; then
    run_root nft --file "$LIVE_NFT"
    log "reloaded the firewall"
  fi
  log "guest network passthrough is now $want"
}

main() {
  local sub="${1:-status}"
  (( $# > 0 )) && shift
  # `tkoc vm on` and `tkoc vm net on` both reach here.
  [[ "$sub" == net ]] && { sub="${1:-status}"; (( $# > 0 )) && shift; }

  while [[ $# -gt 0 ]]; do
    tkoc_parse_safety_flag "$1" || die "vm net: unknown option: $1"
    shift
  done

  case "$sub" in
    on|enable)  require_policy prompting; set_state on ;;
    off|disable) require_policy prompting; set_state off ;;
    status|show)
      require_policy quiet
      printf '  guest network passthrough: %s\n' "$(current_state)"
      printf '  policy: %s\n' "$LIVE_NFT"
      ;;
    help|--help|-h) usage ;;
    *) die "Usage: tkoc vm net [on|off|status]" ;;
  esac
}

main "$@"
