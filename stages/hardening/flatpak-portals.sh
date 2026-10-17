#!/usr/bin/env bash
# flatpak-portals.sh -- report and tighten what sandboxed apps may reach
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Flatpak sandbox permissions"

if ! have_cmd flatpak; then
  skip "flatpak is not installed"
  tally_skip
  summary
  exit 0
fi

# An application with filesystem=home or filesystem=host has no meaningful
# sandbox left: it can read every document, key, and shell history in $HOME.
#
# Which folder an app still needs is the one thing tkoc cannot decide for you:
# take away an IDE's home access without granting its project folder, and it
# simply stops working with no message saying why. So the decision lives in a
# file, one line per app, and tkoc applies and re-checks it on every run:
#
#   ~/.config/tkoc/flatpak-access.json   yours: not in the checkout, so it
#                                        survives updates and is never committed
#   config/flatpak-access.json           the documented, empty template
#
# Apps not listed there are reported, never changed.
_user_config="${XDG_CONFIG_HOME:-$HOME/.config}/tkoc/flatpak-access.json"
_template="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/config/flatpak-access.json"
ACCESS_CONFIG="${TKOC_FLATPAK_ACCESS:-}"
if [[ -z "$ACCESS_CONFIG" ]]; then
  ACCESS_CONFIG="$_template"
  [[ -r "$_user_config" ]] && ACCESS_CONFIG="$_user_config"
fi
OVERRIDES_DIR="${FLATPAK_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak}/overrides"

# One filesystem entry per line, as flatpak reports it after every override.
fp_filesystems() {
  flatpak info --show-permissions "$1" 2>/dev/null \
    | awk -F= '$1 == "filesystems" { n = split($2, e, ";"); for (i = 1; i <= n; i++) if (e[i] != "") print e[i] }' \
    || true
}

# flatpak strips a trailing slash before the mode: "~/Games/:ro" is "~/Games:ro".
fp_normalize() {
  local entry="$1" mode=""
  [[ "$entry" == *:* ]] && { mode=":${entry##*:}"; entry="${entry%:*}"; }
  [[ "$entry" == */ && "$entry" != / ]] && entry="${entry%/}"
  printf '%s%s' "$entry" "$mode"
}

# Whole-home or whole-filesystem access, read-only or not.
fp_is_wide() {
  local entry="${1%%:*}"
  # A literal ~: flatpak expands it itself, so that is how it is reported.
  # shellcheck disable=SC2088
  case "$entry" in home|host|'~'|'~/') return 0 ;; esac
  [[ "$entry" == "$HOME" || "$entry" == "$HOME/" ]]
}

fp_any_wide() {
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && fp_is_wide "$entry" && return 0
  done <<<"$1"
  return 1
}

fp_has_all() {
  local have="$1" wanted="$2" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -qxF -- "$(fp_normalize "$path")" <<<"$have" || return 1
  done <<<"$wanted"
}

fp_describe() {
  local list; list="$(grep -v '^$' <<<"$1" | paste -sd, - || true)"
  printf '%s' "${list:-no folders}"
}

# "app<TAB>folder" lines; "app<TAB>" for an app that should see no folders.
# Every value is checked here, before any of it reaches flatpak.
fp_config() {
  python3 - "$ACCESS_CONFIG" "$HOME" <<'PY'
import json, re, sys
path, home = sys.argv[1], sys.argv[2].rstrip("/")
with open(path) as fh:
    data = json.load(fh)
apps = data.get("apps", {})
if not isinstance(apps, dict):
    sys.exit('"apps" must be an object of {"app.id": ["folder", ...]}')
app_id = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$")
folder = re.compile(r"^(~/[^;\n\r:]+|/[^;\n\r:]+|xdg-[a-z-]+(/[^;\n\r:]*)?)(:(ro|rw|create))?$")
for app, folders in apps.items():
    if not app_id.match(app):
        sys.exit(f"not a Flatpak application id: {app!r}")
    if not isinstance(folders, list) or not all(isinstance(f, str) for f in folders):
        sys.exit(f"{app}: folders must be a list of strings")
    if not folders:
        print(f"{app}\t")
    for f in folders:
        bare = f.rsplit(":", 1)[0] if re.search(r":(ro|rw|create)$", f) else f
        bare = bare.rstrip("/")
        if not folder.match(f) or bare in ("", "~", "/home", home):
            sys.exit(f"{app}: {f!r} is not a folder tkoc will grant (whole home or filesystem access is what this removes)")
        print(f"{app}\t{f}")
PY
}

fp_limit() {
  local app="$1" wanted="$2" have="$3" path expanded extra="" entry
  local -a args=(--nofilesystem=home --nofilesystem=host)

  if ! fp_any_wide "$have" && fp_has_all "$have" "$wanted"; then
    skip "$app is already limited to $(fp_describe "$wanted")"
    tally_skip
  else
    while IFS= read -r path; do
      [[ -n "$path" ]] && args+=("--filesystem=$path")
    done <<<"$wanted"

    if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
      step "[dry-run] would limit $app to $(fp_describe "$wanted")"
      tally_ok
      return 0
    fi

    # The per-app override file is plain text, so a snapshot restores it
    # exactly -- including "there was none".
    tkoc_state_capture_file "$OVERRIDES_DIR/$app"
    if ! flatpak override --user "${args[@]}" "$app" >/dev/null 2>&1; then
      wrn "could not change $app's filesystem access"
      tally_fail
      return 0
    fi
    have="$(fp_filesystems "$app")"
    if fp_any_wide "$have" || ! fp_has_all "$have" "$wanted"; then
      wrn "$app still reports filesystems=$(paste -sd';' - <<<"$have"); check: flatpak override --user --show $app"
      tally_fail
      return 0
    fi
    ok "limited $app to $(fp_describe "$wanted") (from its next start)"
    tally_ok
  fi

  # Overrides add up rather than replace, so a folder taken out of the config
  # stays granted until the app's overrides are reset. Say so, never guess.
  # Only the user-level grants count: what the app itself ships with is not
  # something a reset removes.
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != '!'* ]] || continue
    grep -qxF -- "$entry" < <(while IFS= read -r path; do fp_normalize "$path"; printf '\n'; done <<<"$wanted") \
      || extra+=" $entry"
  done < <(flatpak override --user --show "$app" 2>/dev/null \
    | awk -F= '$1 == "filesystems" { n = split($2, e, ";"); for (i = 1; i <= n; i++) if (e[i] != "") print e[i] }' || true)
  [[ -z "$extra" ]] || step "$app can also reach:$extra (not in your config; to drop them: flatpak override --user --reset $app, then re-run)"

  while IFS= read -r path; do
    # shellcheck disable=SC2088  # a literal ~/ prefix, expanded on the next lines
    [[ "$path" == '~/'* || "$path" == /* ]] || continue
    expanded="${path%:ro}"; expanded="${expanded%:rw}"; expanded="${expanded%:create}"
    expanded="${expanded/#\~/$HOME}"
    [[ -e "$expanded" || "$path" == *:create ]] \
      || hc_advise "$app was given ${path%%:*}, which does not exist yet; create it, or move the app's files there"
  done <<<"$wanted"
}

_config=""
_config_ok=yes
if [[ -r "$ACCESS_CONFIG" ]]; then
  if ! have_cmd python3; then
    hc_advise "python3 is needed to read $ACCESS_CONFIG; no app was changed"
    _config_ok=no
  elif ! _config="$(fp_config 2>&1)"; then
    wrn "$ACCESS_CONFIG: ${_config##*$'\n'}"
    tally_fail
    _config="" _config_ok=no
  fi
fi

_wide=""
while read -r _app; do
  [[ -n "$_app" ]] || continue
  _have="$(fp_filesystems "$_app")"
  if [[ "$_config_ok" == yes ]] && awk -F'\t' -v a="$_app" '$1 == a { found = 1 } END { exit !found }' <<<"$_config"; then
    fp_limit "$_app" "$(awk -F'\t' -v a="$_app" '$1 == a && $2 != "" { print $2 }' <<<"$_config")" "$_have"
  elif fp_any_wide "$_have"; then
    _wide+="  $_app"$'\n'
  fi
done < <(flatpak list --app --columns=application 2>/dev/null || true)

if [[ -n "$_wide" ]]; then
  wrn "these flatpak apps can read your whole home directory or filesystem:"
  printf '%s' "$_wide" | sed 's/^/    /'
  step "limit one by listing the folders it needs in $_user_config"
  step "  (template: $_template); tkoc applies and checks it on the next run"
  tally_skip
elif [[ -z "$_config" ]]; then
  ok "no installed flatpak app holds home or host filesystem access"
  tally_ok
fi
unset _wide _app _have _config _config_ok

# Existing per-user overrides are worth showing: they are invisible in any GUI
# and silently outlive the app that prompted them. `flatpak override --user
# --show` with no app prints only the global ones, so the per-app files are
# listed too -- otherwise this said "none are set" right after setting three.
_overrides="$(flatpak override --user --show 2>/dev/null || true)"
_per_app="$(find "$OVERRIDES_DIR" -mindepth 1 -maxdepth 1 -type f ! -name global -printf '%f\n' 2>/dev/null \
  | LC_ALL=C sort | paste -sd' ' - || true)"
if [[ -n "$_overrides" ]]; then
  step "global user-level overrides (every app):"
  printf '%s\n' "$_overrides" | sed 's/^/      /'
fi
if [[ -n "$_per_app" ]]; then
  step "apps with user-level overrides: $_per_app"
  step "  inspect one with: flatpak override --user --show <app>"
fi
[[ -n "$_overrides$_per_app" ]] || skip "no user-level flatpak overrides are set"
tally_skip
unset _overrides _per_app _user_config _template

summary
