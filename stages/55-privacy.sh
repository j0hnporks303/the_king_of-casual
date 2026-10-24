#!/usr/bin/env bash
# 55-privacy.sh -- privacy hardening orchestrator.
#
# Runs the category scripts in stages/hardening/ according to
# TKOC_PRIVACY_LEVEL. One transaction covers the whole run, so a failure part
# way through rolls back every category, not just the one that failed.
#
#   basic     remote access, telemetry, crash dumps, network discovery
#   strong    + location, KDE privacy, package manager, flatpak, firmware
#   lockdown  + bluetooth, network services, SELinux report, resolved, sysctl
#
# Also supports direct category targeting:
#   bash stages/55-privacy.sh --categories telemetry,discovery
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"

HARDENING_DIR="$SCRIPT_DIR/hardening"

TKOC_PRIVACY_LEVEL="${TKOC_PRIVACY_LEVEL:-strong}"
TKOC_ALLOW_SSH="${TKOC_ALLOW_SSH:-disabled}"
STATUS_MODE=disabled
LIST_MODE=disabled
CUSTOM_CATEGORIES=()

PRIVACY_STATE_FILE="${TKOC_STATE_HOME}/privacy-status"

# ── Category tables ─────────────────────────────────────────────
# One list per tier. Order matters: remote-access runs first so a machine being
# hardened over SSH fails fast and visibly rather than half way through.

basic_categories() {
  printf '%s\n' remote-access telemetry crash-reports discovery
}
strong_categories() {
  printf '%s\n' geolocation kde-privacy package-manager flatpak-portals firmware
}
lockdown_categories() {
  printf '%s\n' bluetooth network-services selinux resolved firewall-extras
}

category_level() {
  case "$1" in
    remote-access|telemetry|crash-reports|discovery) printf 'basic' ;;
    geolocation|kde-privacy|package-manager|flatpak-portals|firmware) printf 'strong' ;;
    bluetooth|network-services|selinux|resolved|firewall-extras) printf 'lockdown' ;;
    *) printf 'unknown' ;;
  esac
}

usage() {
  cat <<'HELP'
55-privacy -- apply privacy hardening categories

Usage:
  bash stages/55-privacy.sh [basic|strong|lockdown]
  bash stages/55-privacy.sh --categories telemetry,discovery
  bash stages/55-privacy.sh lockdown --dry-run
  bash stages/55-privacy.sh --status

Levels:
  basic     remote access, telemetry, crash dumps, network discovery
  strong    basic + location, KDE privacy, package manager, flatpak, firmware
  lockdown  strong + bluetooth, network services, SELinux, resolved, sysctl

Options:
HELP
  tkoc_print_privacy_options
  cat <<'HELP'

--ssh-source is a firewall-tier flag; use tkoc harden or tkoc firewall for it.
HELP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      basic|strong|lockdown|--basic|--strong|--lockdown)
        TKOC_PRIVACY_LEVEL="${1#--}"; shift ;;
      --categories|--category)
        [[ $# -ge 2 ]] || die "--categories requires a comma-separated list"
        TKOC_PRIVACY_CATEGORIES="$2"; shift 2 ;;
      --categories=*)
        TKOC_PRIVACY_CATEGORIES="${1#*=}"; shift ;;
      --list-categories) LIST_MODE=enabled; shift ;;
      --status) STATUS_MODE=enabled; shift ;;
      --ssh|--no-ssh)
        tkoc_parse_ssh_flag "$1"; shift "$TKOC_FLAG_SHIFT" ;;
      --ssh=*|--ssh-source|--ssh-source=*)
        die "--ssh-source is a firewall-tier flag; use: tkoc firewall <tier> --ssh-source <cidr>" ;;
      help|--help|-h) usage; exit 0 ;;
      *)
        if tkoc_parse_safety_flag "$1"; then shift; continue; fi
        die "Unknown privacy option: $1" ;;
    esac
  done

  case "$TKOC_PRIVACY_LEVEL" in
    basic|strong|lockdown) ;;
    *) die "Invalid privacy level '$TKOC_PRIVACY_LEVEL'. Use: basic, strong, or lockdown" ;;
  esac
}

load_custom_categories() {
  CUSTOM_CATEGORIES=()
  [[ -n "${TKOC_PRIVACY_CATEGORIES:-}" ]] || return 0
  local item
  local _old_ifs="$IFS"
  IFS=','
  for item in $TKOC_PRIVACY_CATEGORIES; do
    item="$(trim_line "$item")"
    [[ -n "$item" ]] || continue
    [[ "$(category_level "$item")" == unknown ]] \
      && { IFS="$_old_ifs"; die "Unknown privacy category: $item (see --list-categories)"; }
    CUSTOM_CATEGORIES[${#CUSTOM_CATEGORIES[@]}]="$item"
  done
  IFS="$_old_ifs"
}

list_categories() {
  local category level
  printf 'Privacy categories, by the level that first includes them:\n\n'
  for category in $(basic_categories) $(strong_categories) $(lockdown_categories); do
    level="$(category_level "$category")"
    printf '  %-18s %s\n' "$category" "$level"
  done
  printf '\nRun a subset with: tkoc privacy --categories a,b,c\n'
}

# ── Selection ───────────────────────────────────────────────────

selected_categories() {
  if (( ${#CUSTOM_CATEGORIES[@]} > 0 )); then
    printf '%s\n' ${CUSTOM_CATEGORIES[@]+"${CUSTOM_CATEGORIES[@]}"}
    return 0
  fi
  basic_categories
  case "$TKOC_PRIVACY_LEVEL" in
    strong)   strong_categories ;;
    lockdown) strong_categories; lockdown_categories ;;
  esac
}

run_category() {
  local category="$1" rc=0
  local script="$HARDENING_DIR/$category.sh"
  [[ -f "$script" ]] || die "Privacy category script not found: $script"

  printf '\n\033[1;36m==> privacy: %s\033[0m\n' "$category"
  TKOC_CATEGORY_PARENT=enabled bash "$script" || rc=$?
  return "$rc"
}

record_level() {
  tkoc_bool_enabled TKOC_DRY_RUN disabled && return 0
  mkdir -p -- "$TKOC_STATE_HOME" 2>/dev/null || return 0
  {
    printf 'level=%s\n' "$TKOC_PRIVACY_LEVEL"
    printf 'applied_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'categories=%s\n' "$(selected_categories | paste -sd, -)"
  } > "$PRIVACY_STATE_FILE"
}

# ── Status ──────────────────────────────────────────────────────
#
# Read-only and never sudo. It re-probes the live system rather than echoing
# the recorded level back, so drift since the last apply is visible.

show_status() {
  local recorded="none"
  [[ -r "$PRIVACY_STATE_FILE" ]] \
    && recorded="$(awk -F= '$1=="level"{print $2; exit}' "$PRIVACY_STATE_FILE")"

  printf 'Privacy posture\n\n'
  printf '  last applied level:  %s\n' "${recorded:-none}"
  if [[ -r "$PRIVACY_STATE_FILE" ]]; then
    printf '  last applied at:     %s\n' \
      "$(awk -F= '$1=="applied_utc"{print $2; exit}' "$PRIVACY_STATE_FILE")"
  fi
  printf '\n  live observations:\n'

  _status_unit() {
    local unit="$1" label="$2"
    if ! unit_exists "$unit"; then
      printf '    %-28s not installed\n' "$label"
    elif unit_active "$unit"; then
      printf '    %-28s RUNNING\n' "$label"
    elif unit_enabled "$unit"; then
      printf '    %-28s enabled, not running\n' "$label"
    else
      printf '    %-28s off\n' "$label"
    fi
  }

  _status_unit sshd.service "sshd"
  _status_unit cockpit.socket "cockpit"
  _status_unit abrtd.service "abrt crash reporting"
  _status_unit avahi-daemon.service "avahi (mDNS)"
  _status_unit cups-browsed.service "cups-browsed"
  _status_unit geoclue.service "geoclue (location)"
  _status_unit bluetooth.service "bluetooth"
  _status_unit rpcbind.service "rpcbind"
  _status_unit smb.service "samba"

  printf '\n'
  printf '    %-28s %s\n' "SELinux" "$(getenforce 2>/dev/null || printf 'unavailable')"
  printf '    %-28s %s\n' "dnf countme" \
    "$(awk -F= '/^[[:space:]]*countme/{gsub(/[[:space:]]/,"",$2); print $2; found=1; exit} END{if(!found) print "unset (defaults to on)"}' /etc/dnf/dnf.conf 2>/dev/null || printf unknown)"
  printf '    %-28s %s\n' "coredump storage" \
    "$(cat /etc/systemd/coredump.conf.d/90-tkoc-no-storage.conf 2>/dev/null | awk -F= '/^Storage/{print $2; exit}' || printf 'vendor default (external)')"

  if command -v kreadconfig6 >/dev/null 2>&1; then
    printf '    %-28s %s\n' "Plasma user feedback" \
      "$(kreadconfig6 --file PlasmaUserFeedback --group Global --key FeedbackLevel 2>/dev/null || printf 'unset')"
    printf '    %-28s %s\n' "Baloo file indexing" \
      "$(kreadconfig6 --file baloofilerc --group 'Basic Settings' --key Indexing-Enabled 2>/dev/null || printf 'unset (defaults to on)')"
  fi
  printf '\n'
}

# ── Main ────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  if [[ "$LIST_MODE" == enabled ]]; then list_categories; return 0; fi
  if [[ "$STATUS_MODE" == enabled ]]; then show_status; return 0; fi

  load_custom_categories
  # Several categories are per-user (KDE settings, Flatpak overrides, the Baloo
  # index): run as root they inspect and change root's account, not yours, and
  # still report success. System changes go through sudo from your own account.
  need_not_root
  need_supported_fedora

  local -a categories=()
  local category
  while read -r category; do
    [[ -n "$category" ]] && categories[${#categories[@]}]="$category"
  done < <(selected_categories)
  (( ${#categories[@]} > 0 )) || die "no privacy categories selected"

  if (( ${#CUSTOM_CATEGORIES[@]} > 0 )); then
    log "Privacy hardening (categories: ${categories[*]})"
  else
    log "Privacy hardening (level: $TKOC_PRIVACY_LEVEL)"
  fi
  printf '  categories: %s\n' "${categories[*]}"

  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    tkoc_confirm "Apply this privacy posture?" || { log "Aborted. No changes made."; return 0; }
  fi

  local owns_snapshot=disabled
  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled && [[ -z "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
    tkoc_state_begin "tkoc privacy $TKOC_PRIVACY_LEVEL" "$@" >/dev/null
    owns_snapshot=enabled
    log "Recovery snapshot: $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT")"
  fi

  export TKOC_PRIVACY_LEVEL TKOC_ALLOW_SSH TKOC_DRY_RUN TKOC_UPDATE_YES \
    TKOC_ALLOW_UNSUPPORTED TKOC_ACTIVE_SNAPSHOT ROUTER_DNS TKOC_DNS_OVER_TLS TKOC_DNSSEC

  local rc=0
  for category in "${categories[@]}"; do
    run_category "$category" || { rc=$?; break; }
  done

  if (( rc != 0 )); then
    if [[ "$owns_snapshot" == enabled ]]; then
      tkoc_state_fail
      warn "Privacy category '$category' failed; rolling the whole run back."
      tkoc_state_restore "$TKOC_ACTIVE_SNAPSHOT" enabled \
        || warn "Recovery incomplete. Run: tkoc state restore $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT") --force"
    fi
    return "$rc"
  fi

  [[ "$owns_snapshot" == enabled ]] && tkoc_state_finish
  # A --categories run applied those categories, not a level; recording one
  # made `tkoc privacy status` claim a level that was never applied.
  if (( ${#CUSTOM_CATEGORIES[@]} > 0 )); then
    log "Privacy hardening complete (categories: ${categories[*]})."
  else
    record_level
    log "Privacy hardening complete (level: $TKOC_PRIVACY_LEVEL)."
  fi
}

main "$@"
