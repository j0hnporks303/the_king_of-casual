#!/usr/bin/env bash
# tools/linker.sh -- link executables into a PATH-accessible bin.
#
# Fedora keeps this simple: /usr/local/bin is on the default PATH for your user,
# for sudo, and for root, with no path_helper and no package manager competing
# for it. The macOS edition needed a separate bin and an /etc/paths.d entry to
# stay out of Homebrew's way; none of that applies here.
#
# This tool never runs automatically. Installing tkoc itself is `make`.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

BIN_DIR="${TKOC_LINK_BIN:-/usr/local/bin}"
FORCE=disabled
# Marker file recording which links this tool made, so `unlink` and `list` never
# touch a symlink somebody else put in /usr/local/bin.
REGISTRY="${XDG_STATE_HOME:-$HOME/.local/state}/tkoc/links.tsv"

usage() {
  cat <<'HELP'
link -- symlink executables into a bin directory on PATH

Usage:
  tkoc link <source> [name|/full/dest]   Link one executable
  tkoc link dir <directory>              Link every executable in a directory
  tkoc link list                         Show links this tool created
  tkoc link where                        Show the bin directory in use
  tkoc link unlink <name>                Remove a link this tool created

Options:
  --bin <dir>    Use a different bin directory (default: /usr/local/bin)
  --force        Replace a destination this tool did not create
  --dry-run      Show what would happen, change nothing

The name defaults to the source's basename without its extension, so
`tkoc link ~/scripts/deploy.sh` becomes `deploy`.
HELP
}

registry_add() {
  local name="$1" source="$2"
  tkoc_bool_enabled TKOC_DRY_RUN disabled && return 0
  mkdir -p -- "$(dirname -- "$REGISTRY")"
  touch -- "$REGISTRY"
  # Rewrite rather than append, so re-linking the same name does not accumulate.
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-links.XXXXXX")"
  awk -F'\t' -v n="$name" '$1 != n' "$REGISTRY" > "$tmp" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$name" "$BIN_DIR/$name" "$source" >> "$tmp"
  mv -- "$tmp" "$REGISTRY"
}

registry_has() {
  [[ -r "$REGISTRY" ]] || return 1
  awk -F'\t' -v n="$1" '$1 == n { found=1 } END { exit(found ? 0 : 1) }' "$REGISTRY"
}

link_one() {
  local source="$1" requested="${2:-}" name dest
  [[ -e "$source" ]] || die "no such file: $source"
  source="$(readlink -f -- "$source" 2>/dev/null || printf '%s' "$source")"
  [[ -x "$source" ]] || die "not executable: $source (chmod +x it first)"

  if [[ "$requested" == */* ]]; then
    dest="$requested"; name="$(basename -- "$dest")"
  else
    name="${requested:-$(basename -- "$source")}"
    name="${name%.*}"
    [[ -n "$name" ]] || die "could not derive a link name from: $source"
    dest="$BIN_DIR/$name"
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" && "$(readlink -- "$dest")" == "$source" ]]; then
      log "already linked: $dest -> $source"
      return 0
    fi
    # Refusing here is the whole point: silently replacing something in
    # /usr/local/bin that this tool did not create can shadow a real command.
    if ! registry_has "$name" && ! tkoc_bool_enabled FORCE disabled; then
      die "$dest already exists and was not created by tkoc link. Use --force to replace it."
    fi
  fi

  run_root mkdir -p -- "$(dirname -- "$dest")"
  run_root ln -sfn -- "$source" "$dest"
  registry_add "$name" "$source"
  log "linked: $dest -> $source"
}

link_dir() {
  local dir="$1" entry count=0
  [[ -d "$dir" ]] || die "not a directory: $dir"
  for entry in "$dir"/*; do
    [[ -f "$entry" && -x "$entry" ]] || continue
    link_one "$entry"
    count=$((count+1))
  done
  (( count > 0 )) || log "no executable files found in $dir"
}

cmd_list() {
  if [[ ! -r "$REGISTRY" ]] || [[ ! -s "$REGISTRY" ]]; then
    log "no links created by this tool"
    return 0
  fi
  printf '%-20s %-32s %s\n' NAME LINK TARGET
  while IFS=$'\t' read -r name dest source; do
    local state="ok"
    [[ -L "$dest" ]] || state="MISSING"
    [[ -e "$dest" ]] || state="DANGLING"
    printf '%-20s %-32s %s  [%s]\n' "$name" "$dest" "$source" "$state"
  done < "$REGISTRY"
}

cmd_unlink() {
  local name="${1:-}" dest
  [[ -n "$name" ]] || die "unlink requires a link name (see: tkoc link list)"
  registry_has "$name" || die "tkoc link did not create a link named '$name'"
  dest="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$REGISTRY")"
  [[ -L "$dest" ]] || log "note: $dest is not a symlink any more"
  run_root rm -f -- "$dest"
  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-links.XXXXXX")"
    awk -F'\t' -v n="$name" '$1 != n' "$REGISTRY" > "$tmp"
    mv -- "$tmp" "$REGISTRY"
  fi
  log "removed: $dest"
}

main() {
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin) [[ $# -ge 2 ]] || die "--bin requires a directory"; BIN_DIR="$2"; shift 2 ;;
      --bin=*) BIN_DIR="${1#*=}"; shift ;;
      --force) FORCE=enabled; shift ;;
      help|--help|-h) usage; exit 0 ;;
      -*) tkoc_parse_safety_flag "$1" || die "link: unknown option: $1"; shift ;;
      *) rest[${#rest[@]}]="$1"; shift ;;
    esac
  done

  case "${rest[0]:-help}" in
    dir|directory) link_dir "${rest[1]:-}" ;;
    list|ls)       cmd_list ;;
    where|bin)     printf '%s\n' "$BIN_DIR" ;;
    unlink|rm)     cmd_unlink "${rest[1]:-}" ;;
    help)          usage ;;
    link)          link_one "${rest[1]:-}" "${rest[2]:-}" ;;
    *)             link_one "${rest[0]}" "${rest[1]:-}" ;;
  esac
}

main "$@"
