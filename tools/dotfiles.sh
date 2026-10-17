#!/usr/bin/env bash
# tools/dotfiles.sh -- user-scoped shell provisioning.
#
# Runs as your normal user and refuses to run as root: everything it touches is
# under $HOME, $XDG_CONFIG_HOME and $XDG_STATE_HOME. Nothing here is a system
# file, and root-owned files in a user's config directory are a support problem
# the moment the session tries to write one.
#
# Fedora note: the stock ~/.bashrc already sources ~/.bashrc.d/*.sh. That is the
# preferred hook here, because it is a drop-in file that can simply be deleted,
# rather than a block edited into a file you also maintain by hand. The guarded
# ~/.bashrc block remains available with --bashrc for systems whose ~/.bashrc
# has been rewritten without the .bashrc.d loop.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

SOURCE_CONFIG="$REPO_ROOT/config"
USER_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
USER_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
USER_DOTFILES_DIR="$USER_CONFIG_HOME/tkoc/dotfiles"
USER_BACKUP_DIR="$USER_STATE_HOME/tkoc/backups"
USER_BASHRC="$HOME/.bashrc"
USER_BASHRC_D="$HOME/.bashrc.d"
USER_PROMPT_THEME_FILE="$USER_STATE_HOME/tkoc/prompt-theme"
USER_BACKUP_SNAPSHOT=""

# Fedora ships a fedora prompt theme; defaulting to arch here would be an odd
# first impression on the distribution this edition targets.
DEFAULT_PROMPT_THEME=fedora
HOOK_MODE=auto

readonly TKOC_PROMPT_THEME_KEYS="ACCENT1 ACCENT2 ACCENT3 ACCENT4 USER_ICON HOST_ICON DIR_ICON GIT_ICON"

usage() {
  cat <<'HELP'
Usage: tkoc dotfiles [--dry-run] [--bashrc|--bashrc-d]
       tkoc dotfiles list-themes
       tkoc dotfiles set-theme <name> [--dry-run]

Symlinks the managed shell-snippet directory, environment-variable file, and
prompt-theme library from config/dotfiles/ into $XDG_CONFIG_HOME/tkoc/dotfiles/,
then installs a loader so your interactive shells source them.

Loader placement:
  --bashrc-d   Write ~/.bashrc.d/50-tkoc.sh   (Fedora's own drop-in hook)
  --bashrc     Append a guarded block to ~/.bashrc
  (default)    Use ~/.bashrc.d when your ~/.bashrc sources it, else ~/.bashrc

Re-running is a no-op once everything is linked; anything it would replace is
backed up first under $XDG_STATE_HOME/tkoc/backups/.

Examples:
  tkoc dotfiles --dry-run
  tkoc dotfiles
  tkoc dotfiles list-themes
  tkoc dotfiles set-theme nord
HELP
}

# ── Validation ──────────────────────────────────────────────────

validate_environment_file() {
  local file="$1"
  [[ -r "$file" ]] || die "missing dotfiles environment file: $file"
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[^[:space:]].*$/ { next }
    { printf "%s:%d: invalid environment assignment\n", FILENAME, FNR > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || die "dotfiles environment file failed structural validation"
}

validate_shell_snippets() {
  local dir="$1" snippet found=0
  [[ -d "$dir" ]] || die "missing dotfiles shell snippet directory: $dir"
  for snippet in "$dir"/*.sh; do
    [[ -e "$snippet" ]] || continue
    found=1
    bash -n "$snippet" || die "shell snippet failed syntax validation: $snippet"
  done
  (( found )) || die "dotfiles shell snippet directory is empty: $dir"
}

validate_prompt_theme() {
  local file="$1" key
  [[ -r "$file" ]] || die "missing prompt theme: $file"
  while IFS='=' read -r key _ || [[ -n "$key" ]]; do
    key="${key%%[[:space:]]*}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    case " $TKOC_PROMPT_THEME_KEYS " in
      *" $key "*) ;;
      *) die "unrecognized prompt theme key in $file: $key" ;;
    esac
  done <"$file"
}

validate_prompt_themes() {
  local dir="$1" preset found=0
  [[ -d "$dir" ]] || die "missing prompt theme directory: $dir"
  for preset in "$dir"/*.conf; do
    [[ -e "$preset" ]] || continue
    found=1
    validate_prompt_theme "$preset"
  done
  (( found )) || die "no prompt themes found in $dir"
}

validate_config() {
  validate_environment_file "$SOURCE_CONFIG/dotfiles/environment.conf"
  validate_shell_snippets "$SOURCE_CONFIG/dotfiles/shell.d"
  validate_prompt_themes "$SOURCE_CONFIG/dotfiles/prompt-themes"
  [[ -r "$SOURCE_CONFIG/dotfiles/bashrc.block" ]] \
    || die "missing dotfiles bashrc block: $SOURCE_CONFIG/dotfiles/bashrc.block"
}

# ── User-scoped backups ─────────────────────────────────────────

ensure_user_snapshot() {
  if [[ -z "$USER_BACKUP_SNAPSHOT" ]]; then
    local id
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    USER_BACKUP_SNAPSHOT="$USER_BACKUP_DIR/$id"
    mkdir -p -- "$USER_BACKUP_SNAPSHOT"
    ln -sfn -- "$id" "$USER_BACKUP_DIR/latest"
  fi
  printf '%s\n' "$USER_BACKUP_SNAPSHOT"
}

backup_user_path() {
  local target="$1" name="$2" snapshot
  snapshot="$(ensure_user_snapshot)"
  cp -a -- "$target" "$snapshot/$name"
  log "backed up existing $name to $snapshot/$name"
}

# ── Linking ─────────────────────────────────────────────────────

link_status() {
  local source="$1" target="$2"
  if [[ -L "$target" && "$(readlink -- "$target")" == "$source" ]]; then
    printf 'linked'
  elif [[ -e "$target" || -L "$target" ]]; then
    printf 'replace'
  else
    printf 'absent'
  fi
}

link_targets() {
  printf '%s\t%s\t%s\n' \
    "$SOURCE_CONFIG/dotfiles/shell.d" "$USER_DOTFILES_DIR/shell.d" "managed shell snippets" \
    "$SOURCE_CONFIG/dotfiles/environment.conf" "$USER_DOTFILES_DIR/environment.conf" "managed environment variables" \
    "$SOURCE_CONFIG/dotfiles/prompt-themes" "$USER_DOTFILES_DIR/prompt-themes" "managed prompt themes"
}

link_dotfile() {
  local source="$1" target="$2" label="$3" status
  status="$(link_status "$source" "$target")"
  if [[ "$status" == linked ]]; then
    log "already linked: $label"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$target")"
  [[ "$status" == replace ]] && backup_user_path "$target" "$(basename -- "$target")"
  rm -rf -- "$target"
  ln -sfn -- "$source" "$target"
  log "linked: $label -> $source"
}

describe_dotfile_link() {
  local source="$1" target="$2" label="$3"
  case "$(link_status "$source" "$target")" in
    linked)  log "already linked: $label" ;;
    replace) log "would back up and relink: $label" ;;
    absent)  log "would link: $label -> $source" ;;
  esac
}

# ── Loader placement ────────────────────────────────────────────

# Fedora's /etc/skel/.bashrc ends with a loop over ~/.bashrc.d/*.sh. When that
# loop is present, a drop-in there is strictly better than editing ~/.bashrc:
# it is one file, owned entirely by this tool, and removing it is a complete
# uninstall. A ~/.bashrc that has been replaced by hand may not have the loop,
# which is what the fallback is for.
bashrc_d_supported() {
  [[ -r "$USER_BASHRC" ]] || return 1
  grep -Eq '\.bashrc\.d' "$USER_BASHRC"
}

resolve_hook_mode() {
  case "$HOOK_MODE" in
    bashrc-d|bashrc) return 0 ;;
  esac
  if bashrc_d_supported; then
    HOOK_MODE=bashrc-d
  else
    HOOK_MODE=bashrc
  fi
}

bashrc_d_loader() { printf '%s' "$USER_BASHRC_D/50-tkoc.sh"; }

sync_bashrc_d() {
  local loader content current
  loader="$(bashrc_d_loader)"
  content="$(cat -- "$SOURCE_CONFIG/dotfiles/bashrc.block")"

  if [[ -r "$loader" ]]; then
    current="$(cat -- "$loader")"
    if [[ "$current" == "$content" ]]; then
      log "already up to date: $loader"
      return 0
    fi
    backup_user_path "$loader" "$(basename -- "$loader")"
  fi
  mkdir -p -- "$USER_BASHRC_D"
  printf '%s\n' "$content" > "$loader"
  chmod 0644 "$loader"
  log "installed loader: $loader"
}

describe_bashrc_d() {
  local loader content
  loader="$(bashrc_d_loader)"
  content="$(cat -- "$SOURCE_CONFIG/dotfiles/bashrc.block")"
  if [[ -r "$loader" ]] && [[ "$(cat -- "$loader")" == "$content" ]]; then
    log "already up to date: $loader"
  elif [[ -e "$loader" ]]; then
    log "would back up and replace: $loader"
  else
    log "would install loader: $loader"
  fi
}

bashrc_block_status() {
  local block_file="$1" bashrc="$2" current
  [[ -e "$bashrc" ]] || { printf 'missing'; return; }
  grep -Fq '# >>> tkoc >>>' "$bashrc" || { printf 'missing'; return; }
  current="$(sed -n '/# >>> tkoc >>>/,/# <<< tkoc <<</p' "$bashrc")"
  if diff -q <(printf '%s\n' "$current") "$block_file" >/dev/null 2>&1; then
    printf 'current'
  else
    printf 'stale'
  fi
}

sync_bashrc_block() {
  local block_file="$SOURCE_CONFIG/dotfiles/bashrc.block" status
  status="$(bashrc_block_status "$block_file" "$USER_BASHRC")"
  case "$status" in
    current) log "already up to date: $USER_BASHRC" ;;
    missing)
      [[ -e "$USER_BASHRC" ]] && backup_user_path "$USER_BASHRC" "$(basename -- "$USER_BASHRC")"
      {
        [[ -s "$USER_BASHRC" ]] && printf '\n'
        cat -- "$block_file"
      } >>"$USER_BASHRC"
      log "appended managed block to $USER_BASHRC"
      ;;
    stale)
      backup_user_path "$USER_BASHRC" "$(basename -- "$USER_BASHRC")"
      awk -v block="$block_file" '
        /# >>> tkoc >>>/ {
            skip=1
            while ((getline line < block) > 0) print line
            close(block)
            next
        }
        /# <<< tkoc <<</ { skip=0; next }
        skip { next }
        { print }
      ' "$USER_BASHRC" >"$USER_BASHRC.tkoc-tmp"
      mv -- "$USER_BASHRC.tkoc-tmp" "$USER_BASHRC"
      log "updated managed block in $USER_BASHRC"
      ;;
  esac
}

describe_bashrc_block() {
  case "$(bashrc_block_status "$SOURCE_CONFIG/dotfiles/bashrc.block" "$USER_BASHRC")" in
    current) log "already up to date: $USER_BASHRC" ;;
    missing) log "would append managed block to: $USER_BASHRC" ;;
    stale)   log "would update managed block in: $USER_BASHRC" ;;
  esac
}

# ── Prompt theme ────────────────────────────────────────────────

ensure_prompt_theme_selected() {
  [[ -f "$USER_PROMPT_THEME_FILE" ]] && return 0
  mkdir -p -- "$(dirname -- "$USER_PROMPT_THEME_FILE")"
  printf '%s\n' "$DEFAULT_PROMPT_THEME" >"$USER_PROMPT_THEME_FILE"
}

cmd_list_themes() {
  local file name current=""
  local -a names=()
  [[ -r "$USER_PROMPT_THEME_FILE" ]] && current="$(<"$USER_PROMPT_THEME_FILE")"
  for file in "$SOURCE_CONFIG"/dotfiles/prompt-themes/*.conf; do
    [[ -e "$file" ]] || continue
    name="$(basename -- "$file" .conf)"
    names[${#names[@]}]="$name"
  done
  (( ${#names[@]} > 0 )) || die "no prompt themes found"

  log "available prompt themes:"
  for name in "${names[@]}"; do
    if [[ "$name" == "$current" ]]; then
      printf '  %s (current)\n' "$name"
    else
      printf '  %s\n' "$name"
    fi
  done
  log "switch with: tkoc dotfiles set-theme <name>"
}

cmd_set_theme() {
  local name="${1:-}" preset
  [[ -n "$name" ]] || die "dotfiles set-theme requires a theme name (see: tkoc dotfiles list-themes)"
  preset="$SOURCE_CONFIG/dotfiles/prompt-themes/$name.conf"
  [[ -r "$preset" ]] || die "unknown prompt theme: $name (see: tkoc dotfiles list-themes)"
  validate_prompt_theme "$preset"

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "would select prompt theme: $name"
    return 0
  fi

  need_not_root
  mkdir -p -- "$(dirname -- "$USER_PROMPT_THEME_FILE")"
  printf '%s\n' "$name" >"$USER_PROMPT_THEME_FILE"
  log "selected prompt theme: $name"
  cmd_apply
}

# ── Apply ───────────────────────────────────────────────────────

cmd_apply() {
  local source target label
  validate_config
  resolve_hook_mode

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    while IFS=$'\t' read -r source target label; do
      describe_dotfile_link "$source" "$target" "$label"
    done < <(link_targets)
    if [[ "$HOOK_MODE" == bashrc-d ]]; then describe_bashrc_d; else describe_bashrc_block; fi
    log "dry run: no files were modified"
    return 0
  fi

  need_not_root
  while IFS=$'\t' read -r source target label; do
    link_dotfile "$source" "$target" "$label"
  done < <(link_targets)
  ensure_prompt_theme_selected
  if [[ "$HOOK_MODE" == bashrc-d ]]; then sync_bashrc_d; else sync_bashrc_block; fi

  [[ -n "$USER_BACKUP_SNAPSHOT" ]] && log "backup: $USER_BACKUP_SNAPSHOT"
  log "dotfiles deployed (loader: $HOOK_MODE)"
  log "open a new shell, or run: source ~/.bashrc"
}

# ── Main ────────────────────────────────────────────────────────

main() {
  local subcommand="" theme_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      list-themes) subcommand=list-themes; shift ;;
      set-theme)
        subcommand=set-theme
        [[ $# -ge 2 ]] || die "dotfiles set-theme requires a theme name"
        theme_name="$2"; shift 2 ;;
      --bashrc)   HOOK_MODE=bashrc; shift ;;
      --bashrc-d) HOOK_MODE=bashrc-d; shift ;;
      help|--help|-h) usage; exit 0 ;;
      *)
        if tkoc_parse_safety_flag "$1"; then shift; continue; fi
        die "unknown dotfiles option: $1 (see: tkoc dotfiles --help)" ;;
    esac
  done

  case "$subcommand" in
    list-themes) cmd_list_themes ;;
    set-theme)   cmd_set_theme "$theme_name" ;;
    *)           cmd_apply ;;
  esac
}

main "$@"
