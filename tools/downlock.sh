#!/usr/bin/env bash
# tools/downlock.sh -- tighten owned file permissions.
#
# Reports by default. It only changes modes when you pass --apply, because a
# recursive chmod over a home directory is not something that should happen as a
# side effect of running a command to look at it.
#
# Deliberately NOT ported from the macOS edition: `chflags nouchg`. The nearest
# Linux equivalent is `chattr +i`, which makes a file unmodifiable even by root
# until the attribute is cleared. That is a good way to brick a package upgrade
# and a bad default, so this tool only ever touches mode bits.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

TARGET="$HOME"
CONFIG="${TKOC_DOWNLOCK_CONFIG:-$REPO_ROOT/config/downlock.json}"
OWNER="${TKOC_DOWNLOCK_OWNER:-$(id -un)}"
APPLY=disabled
LIST_ONLY=disabled
ALLOW_ANYWHERE="$(tkoc_bool_value TKOC_DOWNLOCK_ANYWHERE disabled)"
FILES_ONLY=disabled
VERBOSE=disabled
MAX_REPORT=40

usage() {
  cat <<'HELP'
downlock -- report and tighten file permissions you own

Usage:
  tkoc fs lock [path] [options]
  tkoc downlock [path] [options]

Options:
  --apply        Actually change modes (default is report only)
  --list         List matching paths and their target modes, change nothing
  --anywhere     Permit a target outside your home directory
  --owner <user> Only touch files owned by this user (default: you)
  --files-only   Skip directories
  --verbose      Show every path, not just the first 40 that differ
  --dry-run      Same as the default report, stated explicitly
  --yes          Skip the confirmation prompt when applying

Rules come from config/downlock.json. Private material (.ssh, .gnupg, keys,
credential files) goes to 600/700; everything else to 644/755.

This never sets the immutable attribute and never deletes anything.
HELP
}

# Rules are parsed with awk rather than jq: jq is not installed by default on
# Fedora Workstation, and a permissions tool that cannot run until you install
# a JSON parser is a permissions tool nobody runs.
read_rules() {
  [[ -r "$CONFIG" ]] || die "downlock config not found: $CONFIG"
  awk '
    /"pattern"[[:space:]]*:/ {
      line = $0
      pattern = line; sub(/^.*"pattern"[[:space:]]*:[[:space:]]*"/, "", pattern); sub(/".*$/, "", pattern)
      type = line; sub(/^.*"type"[[:space:]]*:[[:space:]]*"/, "", type); sub(/".*$/, "", type)
      mode = line; sub(/^.*"mode"[[:space:]]*:[[:space:]]*"/, "", mode); sub(/".*$/, "", mode)
      if (pattern != "" && type != "" && mode != "") printf "%s\t%s\t%s\n", pattern, type, mode
    }
  ' "$CONFIG"
}

match_rule() {
  local path="$1" kind="$2" base pattern rule_kind mode
  base="$(basename -- "$path")"
  while IFS=$'\t' read -r pattern rule_kind mode; do
    [[ "$rule_kind" == "$kind" ]] || continue
    if [[ "$pattern" == */* ]]; then
      # shellcheck disable=SC2053
      [[ "$path" == *"/$pattern" || "$path" == *"/$pattern"/* ]] && { printf '%s' "$mode"; return 0; }
      case "$path" in
        */${pattern}) printf '%s' "$mode"; return 0 ;;
      esac
    else
      # shellcheck disable=SC2053
      [[ "$base" == $pattern ]] && { printf '%s' "$mode"; return 0; }
    fi
  done < <(read_rules)
  return 1
}

main() {
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) APPLY=enabled; shift ;;
      --list) LIST_ONLY=enabled; shift ;;
      --anywhere) ALLOW_ANYWHERE=enabled; shift ;;
      --owner) [[ $# -ge 2 ]] || die "--owner requires a user name"; OWNER="$2"; shift 2 ;;
      --owner=*) OWNER="${1#*=}"; shift ;;
      --files-only) FILES_ONLY=enabled; shift ;;
      --verbose) VERBOSE=enabled; shift ;;
      help|--help|-h) usage; exit 0 ;;
      -*) tkoc_parse_safety_flag "$1" || die "downlock: unknown option: $1"; shift ;;
      *) rest[${#rest[@]}]="$1"; shift ;;
    esac
  done
  [[ -n "${rest[0]:-}" ]] && TARGET="${rest[0]}"

  [[ -e "$TARGET" ]] || die "no such path: $TARGET"
  TARGET="$(readlink -f -- "$TARGET" 2>/dev/null || printf '%s' "$TARGET")"

  # Operating outside $HOME by accident is how a tool like this damages a
  # system, so it takes an explicit flag.
  if [[ "$ALLOW_ANYWHERE" != enabled ]]; then
    case "$TARGET/" in
      "$HOME"/*) ;;
      *) die "$TARGET is outside your home directory. Pass --anywhere if that is intentional." ;;
    esac
  fi
  [[ "$TARGET" == / ]] && die "refusing to operate on /"

  local owner_uid
  owner_uid="$(id -u "$OWNER" 2>/dev/null)" || die "no such user: $OWNER"

  log "target:  $TARGET"
  log "owner:   $OWNER ($owner_uid)"
  log "rules:   $CONFIG"
  [[ "$APPLY" == enabled ]] && log "mode:    APPLY" || log "mode:    report only (pass --apply to change anything)"
  printf '\n'

  local -a changes=()
  local path kind current want
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -L "$path" ]] && continue                       # never chmod through a symlink
    if [[ -d "$path" ]]; then
      [[ "$FILES_ONLY" == enabled ]] && continue
      kind=dir
    elif [[ -f "$path" ]]; then
      kind=file
    else
      continue
    fi
    [[ "$(tkoc_stat uid "$path")" == "$owner_uid" ]] || continue
    want="$(match_rule "$path" "$kind")" || continue
    current="$(tkoc_stat mode "$path")"
    # Left-pad so 644 and 0644 compare equal.
    [[ "${current#0}" == "${want#0}" ]] && continue
    changes[${#changes[@]}]="$current"$'\t'"$want"$'\t'"$path"
  done < <(find "$TARGET" \( -type f -o -type d \) -print 2>/dev/null)

  if (( ${#changes[@]} == 0 )); then
    log "every matching path already has its target mode"
    return 0
  fi

  local shown=0 entry
  log "${#changes[@]} path(s) differ from the target mode:"
  for entry in "${changes[@]}"; do
    IFS=$'\t' read -r current want path <<<"$entry"
    printf '  %s -> %s  %s\n' "$current" "$want" "$path"
    shown=$((shown+1))
    if [[ "$VERBOSE" != enabled ]] && (( shown >= MAX_REPORT )); then
      printf '  ... and %d more (pass --verbose to see them all)\n' "$(( ${#changes[@]} - shown ))"
      break
    fi
  done

  if [[ "$LIST_ONLY" == enabled || "$APPLY" != enabled ]]; then
    printf '\n'
    log "nothing was changed. Re-run with --apply to set these modes."
    return 0
  fi
  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "dry run: nothing was changed"
    return 0
  fi

  tkoc_confirm "Change the mode of ${#changes[@]} path(s)?" \
    || { log "Aborted. Nothing changed."; return 0; }

  local applied=0
  for entry in "${changes[@]}"; do
    IFS=$'\t' read -r current want path <<<"$entry"
    tkoc_state_capture_permission "$path"
    if chmod "$want" "$path" 2>/dev/null; then
      applied=$((applied+1))
    else
      warn "could not chmod $path"
    fi
  done
  log "changed $applied of ${#changes[@]} path(s)"
}

main "$@"
