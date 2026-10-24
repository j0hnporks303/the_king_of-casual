#!/usr/bin/env bash
# 40-hardening.sh -- nftables host firewall + kernel hardening, in three tiers.
#
# Tiers (see config/firewall/tkoc.nft for the policy itself):
#   vanilla   default-deny inbound/forward, permissive egress
#   strong    + LAN discovery noise dropped, + IPv6 off, + sysctl hardening
#   lockdown  + DNS pinned to the chosen resolvers, + other DoT/DoQ dropped
#
# Fedora ships firewalld enabled, and firewalld owns the nftables ruleset. The
# two cannot both manage it, so this stage asks before displacing firewalld and
# records its prior state in the recovery snapshot.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"

TEST_ROOT="${TKOC_TEST_ROOT:-}"
NFT_TEMPLATE="$REPO_ROOT/config/firewall/tkoc.nft"
SYSCTL_TEMPLATE="$REPO_ROOT/config/sysctl.d/60-tkoc-hardening.conf"
LIVE_NFT="${TEST_ROOT}/etc/nftables/tkoc.nft"
LIVE_SYSCTL="${TEST_ROOT}/etc/sysctl.d/60-tkoc-hardening.conf"
# Fedora's nftables.service loads this one file at boot; everything else is
# pulled in by `include` directives from it.
NFT_SYSCONFIG="${TEST_ROOT}/etc/sysconfig/nftables.conf"
NFT_INCLUDE_BEGIN='# >>> tkoc >>>'
NFT_INCLUDE_END='# <<< tkoc <<<'

usage() {
  cat <<'HELP'
40-hardening -- apply the nftables firewall and kernel hardening

Usage:
  bash stages/40-hardening.sh <tier> [options]
  tkoc firewall <tier> [options]

Tiers:
  vanilla   Default-deny inbound and forwarded traffic; permissive egress
  strong    + LAN discovery/multicast dropped, IPv6 off, sysctl hardening
  lockdown  + DNS pinned to the chosen resolvers, other DNS-over-TLS/QUIC dropped

Options:
HELP
  tkoc_print_firewall_options
  cat <<'HELP'

firewalld:
  Fedora enables firewalld by default and firewalld owns nftables. Applying a
  tier disables and masks it after asking; --keep-firewalld skips that, but
  then whichever tool writes last wins and the posture is not dependable.
  `tkoc state restore` puts firewalld back exactly as it was.

HELP
  tkoc_print_lockdown_note
}

# ────────────────────────────────────────────────────────────────
# ARGUMENTS
# ────────────────────────────────────────────────────────────────

FW_LEVEL="${TKOC_FW_LEVEL:-strong}"
KEEP_FIREWALLD="$(tkoc_bool_value TKOC_KEEP_FIREWALLD disabled)"
EXTERNAL_INTERFACE="${TKOC_INTERFACE:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      vanilla|basic|strong|lockdown|--vanilla|--basic|--strong|--lockdown)
        FW_LEVEL="${1#--}"
        [[ "$FW_LEVEL" == basic ]] && FW_LEVEL=vanilla
        shift
        ;;
      --ipv6)
        [[ $# -ge 2 ]] || die "--ipv6 requires enabled or disabled"
        TKOC_IPV6="$2"; export TKOC_IPV6; shift 2
        ;;
      --ipv6-enabled)  TKOC_IPV6=enabled;  export TKOC_IPV6; shift ;;
      --ipv6-disabled) TKOC_IPV6=disabled; export TKOC_IPV6; shift ;;
      --dns)
        [[ $# -ge 2 && "$2" != --* ]] || die "--dns requires a resolver address or a comma-separated list"
        tkoc_parse_dns_list "$2"
        TKOC_ENFORCE_DNS=enabled; ROUTER_DNS="$2"
        export TKOC_ENFORCE_DNS ROUTER_DNS; shift 2
        ;;
      --dns-over-tls)
        [[ $# -ge 2 ]] || die "--dns-over-tls requires yes, opportunistic, or no"
        tkoc_valid_dns_over_tls "$2" || die "--dns-over-tls takes yes, opportunistic, or no, got: $2"
        TKOC_DNS_OVER_TLS="$2"; export TKOC_DNS_OVER_TLS; shift 2
        ;;
      --no-dns)
        TKOC_ENFORCE_DNS=disabled; export TKOC_ENFORCE_DNS; shift
        ;;
      --interface)
        [[ $# -ge 2 ]] || die "--interface requires an interface name"
        tkoc_valid_interface "$2" || die "not a valid interface name: $2"
        EXTERNAL_INTERFACE="$2"; shift 2
        ;;
      --keep-firewalld) KEEP_FIREWALLD=enabled; shift ;;
      --wireguard|--wg)
        TKOC_ALLOW_WIREGUARD=enabled; export TKOC_ALLOW_WIREGUARD; shift ;;
      --no-wireguard)
        TKOC_ALLOW_WIREGUARD=disabled; export TKOC_ALLOW_WIREGUARD; shift ;;
      --ssh|--ssh=*|--ssh-source|--ssh-source=*|--no-ssh)
        tkoc_parse_ssh_flag "$@"; shift "$TKOC_FLAG_SHIFT"
        ;;
      help|--help|-h) usage; exit 0 ;;
      *)
        if tkoc_parse_safety_flag "$1"; then shift; continue; fi
        die "Unknown firewall option: $1"
        ;;
    esac
  done

  case "$FW_LEVEL" in
    vanilla|strong|lockdown) ;;
    *) die "Unknown firewall tier '$FW_LEVEL'. Use: vanilla, strong, lockdown" ;;
  esac
}

# ────────────────────────────────────────────────────────────────
# TIER -> POLICY
# ────────────────────────────────────────────────────────────────

# Resolve the tier into the marker set and the effective toggles. Explicit flags
# win over tier defaults, with one exception: lockdown forces DNS enforcement,
# because "lockdown without the DNS pin" is a different tier wearing its name.
resolve_policy() {
  local ipv6 enforce_dns

  case "$FW_LEVEL" in
    vanilla)  ipv6="$(tkoc_bool_value TKOC_IPV6 enabled)";  enforce_dns="$(tkoc_bool_value TKOC_ENFORCE_DNS disabled)" ;;
    strong)   ipv6="$(tkoc_bool_value TKOC_IPV6 disabled)"; enforce_dns="$(tkoc_bool_value TKOC_ENFORCE_DNS disabled)" ;;
    lockdown) ipv6="$(tkoc_bool_value TKOC_IPV6 disabled)"; enforce_dns=enabled ;;
  esac

  if [[ "$FW_LEVEL" == lockdown ]] \
    && [[ "$(tkoc_bool_value TKOC_ENFORCE_DNS enabled)" == disabled ]]; then
    warn "--no-dns does not apply at the lockdown tier; DNS stays pinned."
  fi

  POLICY_IPV6="$ipv6"
  POLICY_DNS="$enforce_dns"
  POLICY_DOT="${TKOC_DNS_OVER_TLS:-no}"
  tkoc_valid_dns_over_tls "$POLICY_DOT" \
    || die "TKOC_DNS_OVER_TLS must be yes, opportunistic, or no, got: $POLICY_DOT"

  MARKERS=()
  [[ "$FW_LEVEL" == vanilla ]] || MARKERS+=( TKOC_LAN_NOISE )
  [[ "$POLICY_IPV6" == disabled ]] && MARKERS+=( TKOC_IPV6_OFF )
  [[ "$POLICY_DNS" == enabled ]] && MARKERS+=( TKOC_DNS_ENFORCE )
  # Without a pin nothing on 853 is dropped, so there is nothing to carve out.
  [[ "$POLICY_DNS" == enabled && "$POLICY_DOT" != no ]] && MARKERS+=( TKOC_DOT_ALLOW )
  tkoc_bool_enabled TKOC_ALLOW_SSH disabled && MARKERS+=( TKOC_SSH_ALLOW )
  tkoc_bool_enabled TKOC_ALLOW_WIREGUARD disabled && MARKERS+=( TKOC_WG_ALLOW )

  # A trailing conditional is the function's exit status. Without this, not
  # asking for WireGuard makes resolve_policy return 1, and `set -e` then kills
  # the whole run silently.
  return 0
}

# ────────────────────────────────────────────────────────────────
# DNS RESOLVER DETECTION
# ────────────────────────────────────────────────────────────────

# Loopback addresses are skipped deliberately. On Fedora, /etc/resolv.conf
# normally points at systemd-resolved's stub (127.0.0.53) and the real upstream
# is only visible through resolvectl. Applications reach the stub over the
# loopback accept rule regardless, so what belongs in ALLOWED_DNS4 is the
# upstream resolver that resolved itself talks to.
#
# Detection only ever finds one IPv4 resolver. Lists, IPv6 and DoT server names
# are for --dns to say; guessing them from whatever the network handed out is
# how a machine ends up pinned to a resolver it never meant to trust.
detect_dns4() {
  local address
  if command -v resolvectl >/dev/null 2>&1; then
    while read -r address; do
      if tkoc_valid_ipv4 "$address" && [[ "$address" != 127.* ]]; then
        printf '%s\n' "$address"; return 0
      fi
    done < <(resolvectl dns 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
  fi
  if command -v nmcli >/dev/null 2>&1; then
    while read -r address; do
      if tkoc_valid_ipv4 "$address" && [[ "$address" != 127.* ]]; then
        printf '%s\n' "$address"; return 0
      fi
    done < <(nmcli -g IP4.DNS device show 2>/dev/null | tr ', ' '\n\n' || true)
  fi
  if [[ -r "${TEST_ROOT}/etc/resolv.conf" ]]; then
    while read -r address; do
      if tkoc_valid_ipv4 "$address" && [[ "$address" != 127.* ]]; then
        printf '%s\n' "$address"; return 0
      fi
    done < <(awk '$1 == "nameserver" { print $2 }' "${TEST_ROOT}/etc/resolv.conf")
  fi
  return 1
}

# Fills TKOC_DNS_SERVERS/ADDR4/ADDR6 (see tkoc_parse_dns_list). Call it
# directly: in a command substitution the arrays would die with the subshell.
select_dns() {
  local list="${ROUTER_DNS:-${TKOC_DNS4:-}}"
  if [[ -z "$list" ]]; then
    if list="$(detect_dns4)"; then
      log "detected IPv4 DNS resolver: $list"
    else
      tkoc_have_tty \
        || die "could not detect a DNS resolver; pass --dns <ip>[,<ip>...] and run again"
      list="$(tkoc_prompt 'DNS resolver(s), comma-separated: ')"
    fi
  fi
  tkoc_parse_dns_list "$list"

  # Off-host IPv6 is dropped before the DNS rules are ever reached, so an IPv6
  # resolver at an IPv6-off tier is configured but unreachable.
  if [[ "$POLICY_IPV6" == disabled ]] && (( ${#TKOC_DNS_ADDR6[@]} > 0 )); then
    (( ${#TKOC_DNS_ADDR4[@]} > 0 )) \
      || die "every resolver given is IPv6, but IPv6 is off at this tier; add an IPv4 resolver or pass --ipv6 enabled"
    warn "IPv6 is off at this tier, so ${TKOC_DNS_ADDR6[*]} cannot be reached; only the IPv4 resolvers will answer"
  fi
}

# "a, b, c": the element list of an nftables set.
nft_elements() {
  local joined
  printf -v joined '%s, ' "$@"
  printf '%s' "${joined%, }"
}

# ────────────────────────────────────────────────────────────────
# FIREWALLD
# ────────────────────────────────────────────────────────────────

handle_firewalld() {
  [[ -n "$TEST_ROOT" ]] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  unit_exists firewalld.service || return 0

  if ! unit_enabled firewalld.service && ! unit_active firewalld.service; then
    log "firewalld is present but neither enabled nor running; nothing to displace"
    return 0
  fi

  tkoc_state_capture_firewalld

  if tkoc_bool_enabled KEEP_FIREWALLD disabled; then
    warn "firewalld is left running because --keep-firewalld was given."
    warn "firewalld also manages nftables. Whichever tool writes last wins, so"
    warn "the tkoc_host policy is not dependable while both are active."
    return 0
  fi

  printf '\n'
  printf 'firewalld is active and it owns the nftables ruleset on Fedora.\n'
  printf 'Leaving it running alongside the tkoc policy means the two overwrite\n'
  printf "each other and neither posture is dependable.\n\n"
  printf 'Proposed: systemctl disable --now firewalld && systemctl mask firewalld\n'
  printf 'Its exact prior state is recorded in this run'"'"'s recovery snapshot, so\n'
  printf '"tkoc state restore" brings firewalld back.\n\n'

  if ! tkoc_confirm "Disable and mask firewalld?"; then
    warn "Left firewalld alone. The tkoc policy will be applied anyway, but"
    warn "firewalld may overwrite it. Re-run without --keep-firewalld, or stop"
    warn "firewalld yourself, for a dependable result."
    return 0
  fi

  run_root systemctl disable --now firewalld.service || warn "could not disable firewalld"
  run_root systemctl mask firewalld.service || warn "could not mask firewalld"
  log "firewalld disabled and masked"
}

# ────────────────────────────────────────────────────────────────
# RENDER / INSTALL / APPLY
# ────────────────────────────────────────────────────────────────

RENDERED_NFT=""
RENDERED_SYSCTL=""
STAGE_COMPLETE=disabled

# A single EXIT handler, installed before anything is rendered or written.
#
# Without this, a failure part way through left the recovery snapshot marked
# "capturing" forever and said nothing about the machine being half-configured
# -- which is exactly what happened when an unreadable
# /etc/sysconfig/nftables.conf aborted the run after the policy was installed
# but before it was applied.
#
# It deliberately does not roll back on its own. A policy file that has been
# written but not loaded is inert, and an automatic undo that itself fails part
# way is harder to reason about than a clear instruction.
_hardening_exit() {
  local rc=$?
  [[ -n "$RENDERED_NFT" ]] && rm -f -- "$RENDERED_NFT"
  [[ -n "$RENDERED_SYSCTL" ]] && rm -f -- "$RENDERED_SYSCTL"
  if [[ "${OWNS_SNAPSHOT:-disabled}" == enabled && "$STAGE_COMPLETE" != enabled ]]; then
    local id; id="$(_tkoc_basename "${TKOC_ACTIVE_SNAPSHOT:-}")"
    tkoc_state_fail
    warn ""
    warn "This run stopped before it finished, so the machine may be part way"
    warn "through a tier change. Nothing was undone automatically."
    warn "Inspect and roll back with:"
    warn "    tkoc state show $id"
    warn "    tkoc state restore $id"
  fi
  return "$rc"
}
trap _hardening_exit EXIT

render_policy() {
  local ssh_source=""

  RENDERED_NFT="$(mktemp "${TMPDIR:-/tmp}/tkoc-nft.XXXXXX")"
  RENDERED_SYSCTL="$(mktemp "${TMPDIR:-/tmp}/tkoc-sysctl.XXXXXX")"

  tkoc_render_markers "$NFT_TEMPLATE" "$RENDERED_NFT" ${MARKERS[@]+"${MARKERS[@]}"}
  tkoc_render_markers "$SYSCTL_TEMPLATE" "$RENDERED_SYSCTL" ${MARKERS[@]+"${MARKERS[@]}"}

  if [[ "$POLICY_DNS" == enabled ]]; then
    # A family with no resolver keeps the template's loopback placeholder.
    if (( ${#TKOC_DNS_ADDR4[@]} > 0 )); then
      tkoc_render_define "$RENDERED_NFT" ALLOWED_DNS4 "$(nft_elements "${TKOC_DNS_ADDR4[@]}")"
    fi
    if (( ${#TKOC_DNS_ADDR6[@]} > 0 )); then
      tkoc_render_define "$RENDERED_NFT" ALLOWED_DNS6 "$(nft_elements "${TKOC_DNS_ADDR6[@]}")"
    fi
    POLICY_DNS_ADDRESS="${TKOC_DNS_SERVERS[*]}"
  fi

  if tkoc_bool_enabled TKOC_ALLOW_SSH disabled; then
    ssh_source="${TKOC_SSH_SOURCE:-}"
    if [[ -z "$ssh_source" ]]; then
      ssh_source="$(detect_lan_cidr)" \
        || die "--ssh could not determine your LAN range; pass --ssh-source <ip-or-cidr>"
      log "SSH carve-out scoped to the current LAN: $ssh_source"
    fi
    tkoc_render_define "$RENDERED_NFT" SSH_SOURCE "$ssh_source"
    POLICY_SSH_SOURCE="$ssh_source"
  fi

  tkoc_validate_nft "$RENDERED_NFT" privileged
  tkoc_validate_sysctl "$RENDERED_SYSCTL"
}

# Derive a /24 from the primary IPv4 address. Deliberately narrow: a bare --ssh
# should never open TCP/22 to a range wider than the network the machine is
# actually on, and anything else must be typed with --ssh-source.
detect_lan_cidr() {
  local address
  address="$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{ print $4 }' | head -1)"
  [[ -n "$address" ]] || return 1
  address="${address%%/*}"
  tkoc_valid_ipv4 "$address" || return 1
  printf '%s.0/24' "${address%.*}"
}

# Fedora's nftables.service loads /etc/sysconfig/nftables.conf. A guarded
# include block there is what makes the policy survive a reboot; rewriting the
# whole file would discard include lines the operator added themselves.
ensure_nft_include() {
  local existing="" readable=yes tmp mode

  if [[ -f "$NFT_SYSCONFIG" ]]; then
    if existing="$(read_root_file "$NFT_SYSCONFIG")"; then
      if grep -Fq 'include "/etc/nftables/tkoc.nft"' <<<"$existing" \
        && grep -Fq "$NFT_INCLUDE_BEGIN" <<<"$existing"; then
        log "nftables.service already includes the tkoc policy"
        return 0
      fi
    else
      # 0600 root:root is how Fedora ships this file, so an unprivileged dry
      # run legitimately cannot see inside it. Say that, rather than silently
      # assuming the include is absent and then reporting a change that may
      # already be in place.
      readable=no
      existing=""
      warn "cannot read $NFT_SYSCONFIG without privilege; its current contents are unknown"
    fi
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    if [[ "$readable" == no ]]; then
      log "[dry-run] would ensure the tkoc include block in $NFT_SYSCONFIG"
    else
      log "[dry-run] would add the tkoc include block to $NFT_SYSCONFIG"
    fi
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-nftinc.XXXXXX")"
  if [[ -f "$NFT_SYSCONFIG" ]]; then
    tkoc_state_capture_file "$NFT_SYSCONFIG"
    # Re-read under privilege now that this is a real run, so the rewrite is
    # based on the actual contents rather than the empty string a failed
    # unprivileged read produced.
    existing="$(read_root_file "$NFT_SYSCONFIG")" \
      || { rm -f -- "$tmp"; die "could not read $NFT_SYSCONFIG"; }
    # Drop any previous tkoc block, then append the current one.
    printf '%s\n' "$existing" | awk -v b="$NFT_INCLUDE_BEGIN" -v e="$NFT_INCLUDE_END" '
      index($0, b) { skip = 1; next }
      index($0, e) { skip = 0; next }
      !skip { print }
    ' > "$tmp"
    mode="$(existing_mode "$NFT_SYSCONFIG" 0600)"
  else
    : > "$tmp"
    mode=0600
  fi
  {
    printf '%s\n' "$NFT_INCLUDE_BEGIN"
    printf '# Managed by tkoc. Do not edit between these markers.\n'
    printf 'include "/etc/nftables/tkoc.nft"\n'
    printf '%s\n' "$NFT_INCLUDE_END"
  } >> "$tmp"

  run_root_path "$NFT_SYSCONFIG" mkdir -p -- "$(dirname -- "$NFT_SYSCONFIG")"
  run_root_path "$NFT_SYSCONFIG" install -m "$mode" -- "$tmp" "$NFT_SYSCONFIG"
  rm -f -- "$tmp"
  log "nftables.service will load the tkoc policy at boot"
}

install_policy() {
  copy_file_root "$RENDERED_NFT" "$LIVE_NFT" 0644
  copy_file_root "$RENDERED_SYSCTL" "$LIVE_SYSCTL" 0644
  ensure_nft_include
}

apply_policy() {
  if [[ -n "$TEST_ROOT" ]]; then
    log "test root: activation skipped"
    return 0
  fi
  tkoc_state_capture_nftables "inet tkoc_host"
  while read -r key; do
    tkoc_state_capture_sysctl "$key"
  done < <(awk -F= '/^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=/ {
      key=$1; gsub(/[[:space:]]/, "", key); print key
  }' "$RENDERED_SYSCTL")

  run_root sysctl -q --load "$LIVE_SYSCTL"
  run_root nft --file "$LIVE_NFT"
  if command -v systemctl >/dev/null 2>&1 && unit_exists nftables.service; then
    _tkoc_snapshot_unit nftables.service
    run_root systemctl enable --now nftables.service
  else
    warn "nftables.service is not installed; the policy is live now but will not"
    warn "survive a reboot. Install it with: sudo dnf install nftables"
  fi
}

summary() {
  local dns_note="" ssh_state ssh_note=""
  [[ "$POLICY_DNS" == enabled ]] \
    && dns_note=" (${POLICY_DNS_ADDRESS:-resolved at apply time}; dns-over-tls $POLICY_DOT)"
  ssh_state="$(tkoc_bool_value TKOC_ALLOW_SSH disabled)"
  [[ "$ssh_state" == enabled ]] && ssh_note=" (${POLICY_SSH_SOURCE:-scoped at apply time})"

  printf '\n'
  printf '  tier:       %s\n' "$FW_LEVEL"
  printf '  ipv6:       %s\n' "$POLICY_IPV6"
  printf '  dns pin:    %s%s\n' "$POLICY_DNS" "$dns_note"
  printf '  ssh:        %s%s\n' "$ssh_state" "$ssh_note"
  printf '  interface:  %s\n' "${EXTERNAL_INTERFACE:-auto}"
  printf '  markers:    %s\n' "${MARKERS[*]:-none}"
  printf '\n'
}

main() {
  parse_args "$@"
  need_supported_fedora
  tkoc_guard_ambient_ssh "$FW_LEVEL"
  resolve_policy
  # Before the snapshot, so a resolver list this tier cannot use is refused
  # without leaving a half-started run behind.
  if [[ "$POLICY_DNS" == enabled ]]; then
    select_dns
  fi

  log "Firewall tier: $FW_LEVEL"

  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled && [[ -z "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
    tkoc_state_begin "tkoc firewall $FW_LEVEL" "$@" >/dev/null
    log "Recovery snapshot: $(_tkoc_basename "${TKOC_ACTIVE_SNAPSHOT}")"
    OWNS_SNAPSHOT=enabled
  fi

  render_policy
  summary
  handle_firewalld
  install_policy
  apply_policy
  # A fresh tier starts with guest networking off. VirtualBox NAT bypasses the
  # forward chain, so reconcile its virtual cables as part of that posture.
  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    bash "$REPO_ROOT/tools/vm-net.sh" off
  fi

  STAGE_COMPLETE=enabled
  if [[ "${OWNS_SNAPSHOT:-disabled}" == enabled ]]; then
    tkoc_state_finish
  fi
  log "Firewall tier applied: $FW_LEVEL"
}

main "$@"
