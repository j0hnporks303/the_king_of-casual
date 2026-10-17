#!/usr/bin/env bash
# tools/state.sh -- inspect and restore TKOC recovery snapshots.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

usage() {
  cat <<'HELP'
state -- inspect and restore TKOC recovery snapshots

Usage:
  tkoc state list
  tkoc state show [snapshot]
  tkoc state restore <snapshot|latest> [--dry-run] [--yes] [--force]
  tkoc state prune --keep <count> --yes

Snapshots live under $XDG_STATE_HOME/tkoc/snapshots and are never removed by
uninstall. Each one records the prior value of every file, systemd unit, sysctl,
kconfig key, NetworkManager setting and nftables table a command was about to
change, so a restore puts the machine back rather than guessing at defaults.

Use --force only to restore a snapshot created by another host or UID; that
check exists because restoring another machine's state onto this one writes
files that were never true here.
HELP
}

snapshot_label() {
  local snapshot="$1" command args created status
  command="$(tkoc_b64_decode "$(tkoc_state_meta "$snapshot" command_b64)" 2>/dev/null || printf unknown)"
  args="$(tkoc_b64_decode "$(tkoc_state_meta "$snapshot" arguments_b64)" 2>/dev/null || true)"
  created="$(tkoc_state_meta "$snapshot" created_utc)"
  status="$(tkoc_state_meta "$snapshot" status)"
  printf '%s\t%s\t%s\t%s\n' "$(_tkoc_basename "$snapshot")" "$status" "$created" "$command${args:+ $args}"
}

cmd_list() {
  local snapshot id status created command count=0
  local -a rows=()
  while read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    rows[${#rows[@]}]="$snapshot"
  done < <(tkoc_state_snapshots)

  if (( ${#rows[@]} == 0 )); then
    log "no snapshots"
    return 0
  fi

  printf '%-30s  %-10s  %-18s  %s\n' ID STATUS CREATED COMMAND
  for snapshot in "${rows[@]}"; do
    IFS=$'\t' read -r id status created command < <(snapshot_label "$snapshot")
    printf '%-30s  %-10s  %-18s  %s\n' "$id" "$status" "$created" "$command"
    count=$((count+1))
  done
  printf '\n%d snapshot(s). Restore one with: tkoc state restore <id>\n' "$count"
}

cmd_show() {
  local requested="${1:-latest}" snapshot kind a
  snapshot="$(tkoc_state_resolve "$requested")" || die "snapshot not found: $requested"

  printf 'Snapshot:  %s\n' "$(_tkoc_basename "$snapshot")"
  printf 'Status:    %s\n' "$(tkoc_state_meta "$snapshot" status)"
  printf 'Created:   %s\n' "$(tkoc_state_meta "$snapshot" created_utc)"
  printf 'Command:   %s %s\n' \
    "$(tkoc_b64_decode "$(tkoc_state_meta "$snapshot" command_b64)")" \
    "$(tkoc_b64_decode "$(tkoc_state_meta "$snapshot" arguments_b64)")"
  printf 'System:    %s (%s)\n' \
    "$(tkoc_state_meta "$snapshot" os)" "$(tkoc_state_meta "$snapshot" kernel)"
  printf '\nCaptured state:\n'

  while IFS=$'\t' read -r kind a _; do
    case "$kind" in
      file)       printf '  file       %s\n' "$(tkoc_b64_decode "$a")" ;;
      systemd)    printf '  unit       %s\n' "$(tkoc_b64_decode "$a")" ;;
      sysctl)     printf '  sysctl     %s\n' "$(tkoc_b64_decode "$a")" ;;
      kconfig)    printf '  kconfig    %s\n' "$(tkoc_b64_decode "$a")" ;;
      nmdns)      printf '  dns        %s\n' "$(tkoc_b64_decode "$a")" ;;
      nmipv6)     printf '  ipv6       %s\n' "$(tkoc_b64_decode "$a")" ;;
      nftables)   printf '  nftables   %s\n' "$(tkoc_b64_decode "$a")" ;;
      firewalld)  printf '  firewalld  service state\n' ;;
      permission) printf '  perms      %s\n' "$(tkoc_b64_decode "$a")" ;;
      command)    printf '  command    %s\n' "$(tkoc_b64_decode "$a")" ;;
    esac
  done < "$snapshot/manifest.tsv"
}

cmd_restore() {
  local requested="" force=disabled snapshot rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=enabled; shift ;;
      -*) tkoc_parse_safety_flag "$1" || die "state restore: unknown option: $1"; shift ;;
      *) requested="$1"; shift ;;
    esac
  done
  [[ -n "$requested" ]] || die "state restore requires a snapshot ID or 'latest' (see: tkoc state list)"

  snapshot="$(tkoc_state_resolve "$requested")" || die "snapshot not found: $requested"
  log "Restoring $(_tkoc_basename "$snapshot")"
  cmd_show "$requested" | sed -n '/^Captured state:/,$p'

  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    tkoc_confirm "Restore this snapshot?" || { log "Aborted. Nothing restored."; return 0; }
  fi

  tkoc_state_restore "$snapshot" "$force" || rc=$?
  case "$rc" in
    0) log "Restore complete." ;;
    1) die "snapshot is incomplete or uses an unsupported schema" ;;
    2) die "snapshot was created by a different user; re-run with --force if that is intended" ;;
    3) die "snapshot was created on a different machine; re-run with --force if that is intended" ;;
    4) die "snapshot failed its ownership and permission checks and was not trusted" ;;
    *) die "restore failed with status $rc" ;;
  esac
}

cmd_prune() {
  local keep="" snapshot index=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) [[ $# -ge 2 ]] || die "--keep requires a count"; keep="$2"; shift 2 ;;
      --keep=*) keep="${1#*=}"; shift ;;
      -*) tkoc_parse_safety_flag "$1" || die "state prune: unknown option: $1"; shift ;;
      *) die "state prune: unexpected argument: $1" ;;
    esac
  done
  [[ "$keep" =~ ^[0-9]+$ ]] || die "state prune requires --keep <count>"
  [[ -d "$TKOC_SNAPSHOT_ROOT" ]] || { log "no snapshots"; return 0; }

  local -a doomed=()
  while read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    index=$((index+1))
    (( index > keep )) && doomed[${#doomed[@]}]="$snapshot"
  done < <(tkoc_state_snapshots)

  if (( ${#doomed[@]} == 0 )); then
    log "nothing to prune; $index snapshot(s) present, keeping $keep"
    return 0
  fi

  log "would remove ${#doomed[@]} snapshot(s), keeping the newest $keep:"
  for snapshot in "${doomed[@]}"; do printf '  %s\n' "$(_tkoc_basename "$snapshot")"; done

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "dry run: nothing was removed"
    return 0
  fi
  tkoc_confirm "Permanently delete these snapshots?" \
    || { log "Aborted. Nothing removed."; return 0; }

  for snapshot in "${doomed[@]}"; do
    # Refuse anything that is not directly inside the snapshot root: a bad
    # resolve here would be an rm -rf on an arbitrary path.
    [[ "$(_tkoc_dirname "$snapshot")" == "$(readlink -f -- "$TKOC_SNAPSHOT_ROOT")" ]] \
      || die "refusing to remove a path outside the snapshot root: $snapshot"
    rm -rf -- "$snapshot"
  done
  log "removed ${#doomed[@]} snapshot(s)"
}

main() {
  local subcommand="${1:-help}"
  (( $# > 0 )) && shift
  case "$subcommand" in
    list)    cmd_list "$@" ;;
    show)    cmd_show "$@" ;;
    restore) cmd_restore "$@" ;;
    prune)   cmd_prune "$@" ;;
    help|--help|-h) usage ;;
    *) die "unknown state subcommand: $subcommand (see: tkoc state help)" ;;
  esac
}

main "$@"
