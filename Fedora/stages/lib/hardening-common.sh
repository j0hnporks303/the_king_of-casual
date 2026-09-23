#!/usr/bin/env bash
# hardening-common.sh -- shared helpers for privacy hardening category scripts.
# Sourced by stages/55-privacy.sh and stages/hardening/*.sh
#
# A category script can be run two ways: through the orchestrator (`tkoc privacy
# strong`), which owns one transaction covering every category, or directly
# (`bash stages/hardening/telemetry.sh`) for narrow work. Run directly, the
# script opens and closes its own transaction so it is still recoverable.

[[ -n "${TKOC_HARDENING_LIB_LOADED:-}" ]] && return 0
TKOC_HARDENING_LIB_LOADED=1

_tkoc_hardening_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$_tkoc_hardening_lib_dir/common.sh"
# shellcheck source=state.sh
source "$_tkoc_hardening_lib_dir/state.sh"

# The caller is a category script when it lives in stages/hardening/.
# BASH_SOURCE[-1] would be cleaner but needs bash 4.3; the explicit index works
# on the bash 3.2 that macOS still ships, which the test suite runs under.
TKOC_CATEGORY_DIRECT=disabled
_tkoc_entry="${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]}"
TKOC_CATEGORY_NAME="$(basename -- "$_tkoc_entry" .sh)"
_tkoc_entry_dir="$(cd -- "$(dirname -- "$_tkoc_entry")" && pwd -P)"
[[ "$(basename -- "$_tkoc_entry_dir")" == hardening ]] && TKOC_CATEGORY_DIRECT=enabled
unset _tkoc_entry _tkoc_entry_dir

# ────────────────────────────────────────────────────────────────
# LOGGING
# ────────────────────────────────────────────────────────────────

hdr()  { printf '\n  \033[1;36m> %s\033[0m\n' "$*"; }
step() { printf '  \033[0;36m-\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32mok\033[0m   %s\n' "$*"; }
wrn()  { printf '    \033[1;33mwarn\033[0m %s\n' "$*"; }
skip() { printf '    \033[0;90mskip\033[0m %s\n' "$*"; }

# ────────────────────────────────────────────────────────────────
# TALLY
# ────────────────────────────────────────────────────────────────

applied=0
failed=0
skipped=0
total=0

tally_ok()   { applied=$((applied+1)); total=$((total+1)); }
tally_fail() { failed=$((failed+1));   total=$((total+1)); }
tally_skip() { skipped=$((skipped+1)); total=$((total+1)); }

summary() {
  printf '\n  ---------------------------------\n'
  printf '  Applied: %d  Failed: %d  Skipped: %d  Total: %d\n' \
    "$applied" "$failed" "$skipped" "$total"
  (( failed == 0 ))
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ────────────────────────────────────────────────────────────────
# SYSTEMD UNITS
# ────────────────────────────────────────────────────────────────

# Disable a unit, recording its exact prior state first. A unit that is not
# installed is skipped, not failed: a Fedora system without Samba should not
# fail the network-services category.
#
# Masking is reserved for units that something else will otherwise pull back in
# through a dependency — disabling alone does not stop a socket-activated or
# dbus-activated service from starting on demand.
hc_disable_unit() {
  local unit="$1" reason="${2:-}" note=""
  [[ -n "$reason" ]] && note=" ($reason)"

  if ! unit_exists "$unit"; then
    skip "$unit is not installed$note"
    tally_skip
    return 0
  fi
  if ! unit_enabled "$unit" && ! unit_active "$unit"; then
    skip "$unit is already disabled and stopped$note"
    tally_skip
    return 0
  fi

  tkoc_state_capture_systemd "$unit"
  if run_root systemctl disable --now -- "$unit" >/dev/null 2>&1; then
    ok "disabled $unit$note"
    tally_ok
  else
    wrn "could not disable $unit$note"
    tally_fail
  fi
}

hc_mask_unit() {
  local unit="$1" reason="${2:-}" note=""
  [[ -n "$reason" ]] && note=" ($reason)"

  if ! unit_exists "$unit"; then
    skip "$unit is not installed$note"
    tally_skip
    return 0
  fi
  if [[ "$(systemctl is-enabled -- "$unit" 2>/dev/null || true)" == masked* ]]; then
    skip "$unit is already masked$note"
    tally_skip
    return 0
  fi

  tkoc_state_capture_systemd "$unit"
  if run_root systemctl mask --now -- "$unit" >/dev/null 2>&1; then
    ok "masked $unit$note"
    tally_ok
  else
    wrn "could not mask $unit$note"
    tally_fail
  fi
}

# ────────────────────────────────────────────────────────────────
# INI-STYLE CONFIG FILES  (/etc/dnf/dnf.conf, systemd drop-ins, ...)
# ────────────────────────────────────────────────────────────────

hc_config_get() {
  local file="$1" section="$2" key="$3"
  [[ -r "$file" ]] || return 1
  awk -F= -v section="$section" -v key="$key" '
    /^[[:space:]]*\[/ {
      current = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
      next
    }
    current == section {
      k = $1
      gsub(/[[:space:]]/, "", k)
      if (k == key) {
        sub(/^[^=]*=[[:space:]]*/, "")
        print
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# Set key=value inside [section] of an ini file, creating the section if it is
# absent. Rewrites through a temp file and install(1) so a failed write cannot
# leave a half-written config behind, and snapshots the original first.
hc_set_config() {
  local file="$1" section="$2" key="$3" value="$4"
  local label="${5:-$key}"
  local current tmp

  if current="$(hc_config_get "$file" "$section" "$key" 2>/dev/null)" \
    && [[ "$current" == "$value" ]]; then
    skip "$label is already $value"
    tally_skip
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    step "[dry-run] would set $key=$value in [$section] of $file"
    tally_ok
    return 0
  fi

  [[ -e "$file" ]] && tkoc_state_capture_file "$file"
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-conf.XXXXXX")"
  if [[ -r "$file" ]]; then
    awk -v section="$section" -v key="$key" -v value="$value" '
      BEGIN { in_section = 0; written = 0; seen_section = 0 }
      /^[[:space:]]*\[/ {
        if (in_section && !written) { print key "=" value; written = 1 }
        current = $0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
        in_section = (current == section)
        if (in_section) seen_section = 1
        print
        next
      }
      {
        if (in_section) {
          k = $0
          sub(/=.*$/, "", k)
          gsub(/[[:space:]]/, "", k)
          if (k == key) {
            if (!written) { print key "=" value; written = 1 }
            next
          }
        }
        print
      }
      END {
        if (in_section && !written) { print key "=" value; written = 1 }
        if (!seen_section) { print ""; print "[" section "]"; print key "=" value }
      }
    ' "$file" > "$tmp"
  else
    printf '[%s]\n%s=%s\n' "$section" "$key" "$value" > "$tmp"
  fi

  if run_root install -m 0644 -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    ok "$label set to $value in $file"
    tally_ok
  else
    rm -f -- "$tmp"
    wrn "could not write $file"
    tally_fail
  fi
}

# Write a systemd drop-in. Drop-ins are preferred over editing a vendor unit or
# config file: dnf never overwrites them on upgrade, and removing the file is a
# complete, obvious undo.
hc_drop_in() {
  local unit_dir="$1" name="$2" content="$3"
  local label="${4:-$name}"
  local target="$unit_dir/$name" tmp

  if [[ -r "$target" ]] && [[ "$(cat "$target")" == "$content" ]]; then
    skip "$label drop-in is already in place"
    tally_skip
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    step "[dry-run] would write $target"
    tally_ok
    return 0
  fi

  [[ -e "$target" ]] && tkoc_state_capture_file "$target"
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-dropin.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  if run_root mkdir -p -- "$unit_dir" && run_root install -m 0644 -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    run_root systemctl daemon-reload >/dev/null 2>&1 || true
    ok "$label drop-in written to $target"
    tally_ok
  else
    rm -f -- "$tmp"
    wrn "could not write $target"
    tally_fail
  fi
}

# ────────────────────────────────────────────────────────────────
# KDE  (kconfig)
# ────────────────────────────────────────────────────────────────
#
# These run as the invoking user, never root: kconfig files live in the user's
# own ~/.config and a root-written one would be unreadable by the session.

hc_kde_available() { have_cmd kwriteconfig6 && have_cmd kreadconfig6; }

hc_set_kconfig() {
  local file="$1" group="$2" key="$3" value="$4"
  local label="${5:-$file/$group/$key}"
  local current

  if ! hc_kde_available; then
    skip "$label: kwriteconfig6 is not installed (KDE Plasma 6 not present)"
    tally_skip
    return 0
  fi
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    skip "$label: KDE settings are per-user and are not applied as root"
    tally_skip
    return 0
  fi

  current="$(kreadconfig6 --file "$file" --group "$group" --key "$key" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    skip "$label is already $value"
    tally_skip
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    step "[dry-run] would set $label to $value"
    tally_ok
    return 0
  fi

  tkoc_state_capture_kconfig "$file" "$group" "$key"
  if kwriteconfig6 --file "$file" --group "$group" --key "$key" "$value" 2>/dev/null; then
    ok "$label set to $value"
    tally_ok
  else
    wrn "could not set $label"
    tally_fail
  fi
}

# ────────────────────────────────────────────────────────────────
# SYSCTL  (runtime + persisted drop-in)
# ────────────────────────────────────────────────────────────────

hc_set_sysctl() {
  local key="$1" value="$2" current
  local label="${3:-$key}"

  current="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    skip "$label: $key is not available on this kernel"
    tally_skip
    return 0
  fi
  if [[ "$current" == "$value" ]]; then
    skip "$label is already $value"
    tally_skip
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    step "[dry-run] would set $key=$value"
    tally_ok
    return 0
  fi

  tkoc_state_capture_sysctl "$key"
  if run_root sysctl -q -w "$key=$value" >/dev/null 2>&1; then
    ok "$label set to $value"
    tally_ok
  else
    wrn "could not set $key"
    tally_fail
  fi
}

# ────────────────────────────────────────────────────────────────
# ADVISORY REPORTING
# ────────────────────────────────────────────────────────────────
#
# Some surfaces should be reported rather than changed: anything where an
# automatic change could break login, lose data, or require a relabel. These
# count as skips, not applications, so the tally never overstates what ran.

hc_advise() {
  local message="$1"
  wrn "$message"
  tally_skip
}

# ────────────────────────────────────────────────────────────────
# DIRECT INVOCATION
# ────────────────────────────────────────────────────────────────
#
# When a category is run on its own rather than through the orchestrator, it
# needs its own confirmation, its own transaction, and its own recovery on
# failure. TKOC_CATEGORY_PARENT=enabled tells it the orchestrator has already
# done all three.

TKOC_CATEGORY_OWNS_SNAPSHOT=disabled

hc_category_begin() {
  [[ "$TKOC_CATEGORY_DIRECT" == enabled ]] || return 0
  [[ "${TKOC_CATEGORY_PARENT:-disabled}" != enabled ]] || return 0

  while (( $# )); do
    case "$1" in
      help|--help|-h)
        printf '%s -- TKOC privacy category\n' "$TKOC_CATEGORY_NAME"
        printf 'Usage: bash stages/hardening/%s.sh [--dry-run] [--yes]\n' "$TKOC_CATEGORY_NAME"
        printf 'Normally invoked through: tkoc privacy <basic|strong|lockdown>\n'
        exit 0
        ;;
      *) tkoc_parse_safety_flag "$1" || die "Unknown privacy-category option: $1" ;;
    esac
    shift
  done

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    printf '[tkoc][dry-run] previewing privacy category %s\n' "$TKOC_CATEGORY_NAME"
    return 0
  fi

  need_supported_fedora
  tkoc_confirm "Apply privacy category $TKOC_CATEGORY_NAME?" \
    || { log "Aborted. No changes made."; exit 0; }

  if [[ -z "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
    tkoc_state_begin "privacy-category $TKOC_CATEGORY_NAME" >/dev/null
    TKOC_CATEGORY_OWNS_SNAPSHOT=enabled
    log "Recovery snapshot: $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT")"
  fi
  trap hc_category_exit EXIT
}

hc_category_exit() {
  local rc=$?
  if [[ "$TKOC_CATEGORY_OWNS_SNAPSHOT" == enabled ]]; then
    if (( rc == 0 && failed == 0 )); then
      tkoc_state_finish
    else
      tkoc_state_fail
      warn "Privacy category failed; attempting automatic recovery."
      tkoc_state_restore "$TKOC_ACTIVE_SNAPSHOT" enabled \
        || warn "Recovery incomplete. Run: tkoc state restore $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT") --force"
    fi
  fi
  return "$rc"
}
