#!/usr/bin/env bash
# 60-ricing.sh -- KDE Plasma appearance: global theme, colours, icons, fonts.
#
# Runs as your normal user and refuses to run as root: Plasma settings live in
# the user's own kconfig files, and a root-written one is unreadable by the
# session that needs it.
#
# A setting whose tool is not installed is skipped, not failed. Plasma ships
# plasma-apply-* only with the full desktop, and this stage should still be
# usable on a machine with a partial KDE install.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"

SOURCE_CONFIG="$REPO_ROOT/config"
readonly TKOC_THEME_KEYS="LOOK_AND_FEEL COLOR_SCHEME ICON_THEME CURSOR_THEME FONT_GENERAL FONT_FIXED_WIDTH"

THEME_APPLIED=0
THEME_SKIPPED=0
THEME_FONT_CHANGED=0

usage() {
  cat <<'HELP'
60-ricing -- apply a KDE Plasma appearance profile

Usage:
  bash stages/60-ricing.sh [--dry-run]        Apply config/theme/kde.conf
  tkoc theme                                  Same
  tkoc theme list                             List the named presets
  tkoc theme set <name> [--dry-run]           Apply a named preset
  tkoc theme <name>                           Shorthand for 'theme set <name>'

Plain `tkoc theme` applies your own hand-edited profile at config/theme/kde.conf.
The presets under config/theme/presets/ are applied with `theme set`.

Font changes need a logout and login (or a plasmashell restart) to take effect
everywhere; everything else applies immediately to the running session.
HELP
}

# ── Validation ──────────────────────────────────────────────────

validate_theme_config() {
  local file="$1" key
  [[ -r "$file" ]] || die "missing theme configuration: $file"

  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[^[:space:]].*$/ { next }
    { printf "%s:%d: invalid theme assignment\n", FILENAME, FNR > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || die "theme configuration failed structural validation"

  while IFS='=' read -r key _ || [[ -n "$key" ]]; do
    key="${key%%[[:space:]]*}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    case " $TKOC_THEME_KEYS " in
      *" $key "*) ;;
      *) die "unrecognized theme key in $file: $key" ;;
    esac
  done <"$file"
}

validate_theme_presets() {
  local dir="$1" preset found=0
  [[ -d "$dir" ]] || die "missing theme preset directory: $dir"
  for preset in "$dir"/*.conf; do
    [[ -e "$preset" ]] || continue
    found=1
    validate_theme_config "$preset"
  done
  (( found )) || die "no theme presets found in $dir"
}

read_theme_config() {
  local file="$1" key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ "$key" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    key="${key%%[[:space:]]*}"
    [[ -z "$key" ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\t%s\n' "$key" "$value"
  done <"$file"
}

# ── Application ─────────────────────────────────────────────────

theme_current_kdeglobals() {
  local group="$1" key="$2"
  command -v kreadconfig6 >/dev/null 2>&1 || return 1
  kreadconfig6 --file kdeglobals --group "$group" --key "$key" 2>/dev/null
}

apply_with_tool() {
  local tool="$1" label="$2" value="$3"
  shift 3
  if ! command -v "$tool" >/dev/null 2>&1; then
    log "skipped $label: $tool is not installed"
    THEME_SKIPPED=$((THEME_SKIPPED + 1))
    return 0
  fi
  if run_or_print "$@" >/dev/null; then
    log "applied $label: $value"
    THEME_APPLIED=$((THEME_APPLIED + 1))
  else
    warn "could not apply $label: $value"
  fi
}

apply_theme_kdeglobals() {
  local group="$1" config_key="$2" label="$3" value="$4" current
  if ! command -v kwriteconfig6 >/dev/null 2>&1; then
    log "skipped $label: kwriteconfig6 is not installed"
    THEME_SKIPPED=$((THEME_SKIPPED + 1))
    return 0
  fi
  current="$(theme_current_kdeglobals "$group" "$config_key" || true)"
  if [[ "$current" == "$value" ]]; then
    log "already set: $label"
    return 0
  fi
  tkoc_state_capture_kconfig kdeglobals "$group" "$config_key"
  run_or_print kwriteconfig6 --file kdeglobals --group "$group" --key "$config_key" "$value"
  log "applied $label: $value"
  THEME_APPLIED=$((THEME_APPLIED + 1))
  [[ "$group" == General ]] && THEME_FONT_CHANGED=1
  if [[ "$config_key" == Theme ]] && command -v kbuildsycoca6 >/dev/null 2>&1; then
    run_or_print kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
}

apply_theme_setting() {
  local key="$1" value="$2"
  case "$key" in
    LOOK_AND_FEEL)
      apply_with_tool plasma-apply-lookandfeel LOOK_AND_FEEL "$value" \
        plasma-apply-lookandfeel --apply "$value" ;;
    COLOR_SCHEME)
      apply_with_tool plasma-apply-colorscheme COLOR_SCHEME "$value" \
        plasma-apply-colorscheme "$value" ;;
    CURSOR_THEME)
      apply_with_tool plasma-apply-cursortheme CURSOR_THEME "$value" \
        plasma-apply-cursortheme "$value" ;;
    ICON_THEME)       apply_theme_kdeglobals Icons Theme ICON_THEME "$value" ;;
    FONT_GENERAL)     apply_theme_kdeglobals General font FONT_GENERAL "$value" ;;
    FONT_FIXED_WIDTH) apply_theme_kdeglobals General fixed FONT_FIXED_WIDTH "$value" ;;
    *) die "unrecognized theme key: $key" ;;
  esac
}

describe_theme_setting() {
  local key="$1" value="$2" tool=""
  case "$key" in
    LOOK_AND_FEEL) tool=plasma-apply-lookandfeel ;;
    COLOR_SCHEME)  tool=plasma-apply-colorscheme ;;
    CURSOR_THEME)  tool=plasma-apply-cursortheme ;;
    ICON_THEME|FONT_GENERAL|FONT_FIXED_WIDTH) tool=kwriteconfig6 ;;
  esac
  if command -v "$tool" >/dev/null 2>&1; then
    log "would apply $key: $value"
  else
    log "would skip $key: $tool is not installed"
  fi
}

cmd_apply() {
  local manifest="$1" key value
  validate_theme_config "$manifest"

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    while IFS=$'\t' read -r key value; do
      describe_theme_setting "$key" "$value"
    done < <(read_theme_config "$manifest")
    log "dry run: no theme settings were changed"
    return 0
  fi

  need_not_root
  THEME_APPLIED=0; THEME_SKIPPED=0; THEME_FONT_CHANGED=0
  while IFS=$'\t' read -r key value; do
    apply_theme_setting "$key" "$value"
  done < <(read_theme_config "$manifest")

  (( THEME_FONT_CHANGED )) \
    && log "font changes need a logout and login (or a plasmashell restart) to take effect everywhere"
  log "theme summary: $THEME_APPLIED applied, $THEME_SKIPPED skipped"
}

cmd_list() {
  local file
  local -a names=()
  for file in "$SOURCE_CONFIG"/theme/presets/*.conf; do
    [[ -e "$file" ]] || continue
    names[${#names[@]}]="$(basename -- "$file" .conf)"
  done
  (( ${#names[@]} > 0 )) || die "no theme presets found"
  log "available theme presets:"
  printf '  %s\n' "${names[@]}"
  log "apply one with: tkoc theme set <name>"
}

cmd_set() {
  local name="${1:-}" manifest
  [[ -n "$name" ]] || die "theme set requires a preset name (see: tkoc theme list)"
  manifest="$SOURCE_CONFIG/theme/presets/$name.conf"
  [[ -r "$manifest" ]] || die "unknown theme preset: $name (see: tkoc theme list)"
  cmd_apply "$manifest"
}

main() {
  local subcommand="" name="${RICE_THEME:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      list)  subcommand=list; shift ;;
      set)
        subcommand=set
        [[ $# -ge 2 ]] || die "theme set requires a preset name"
        name="$2"; shift 2 ;;
      validate) subcommand=validate; shift ;;
      help|--help|-h) usage; exit 0 ;;
      -*)
        tkoc_parse_safety_flag "$1" || die "unknown theme option: $1"
        shift ;;
      *)
        # A bare name is shorthand for `theme set <name>`, which is how
        # `tkoc theme nord` reaches here.
        subcommand=set; name="$1"; shift ;;
    esac
  done

  case "$subcommand" in
    list) cmd_list ;;
    set)  cmd_set "$name" ;;
    validate)
      validate_theme_config "$SOURCE_CONFIG/theme/kde.conf"
      validate_theme_presets "$SOURCE_CONFIG/theme/presets"
      log "theme configuration: valid" ;;
    *)
      if [[ -n "$name" ]]; then cmd_set "$name"; else cmd_apply "$SOURCE_CONFIG/theme/kde.conf"; fi ;;
  esac
}

main "$@"
