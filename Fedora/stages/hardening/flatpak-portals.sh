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
# These are reported, never revoked automatically -- an app that legitimately
# needs home access simply stops working, with no message saying why.
_wide=""
while read -r _app; do
  [[ -n "$_app" ]] || continue
  _perms="$(flatpak info --show-permissions "$_app" 2>/dev/null || true)"
  if grep -Eq '^filesystems=.*(home|host)' <<<"$_perms"; then
    _wide+="  $_app"$'\n'
  fi
done < <(flatpak list --app --columns=application 2>/dev/null || true)

if [[ -n "$_wide" ]]; then
  wrn "these flatpak apps can read your whole home directory:"
  printf '%s' "$_wide" | sed 's/^/    /'
  step "narrow one with: flatpak override --user --nofilesystem=home <app>"
  step "inspect one with: flatpak info --show-permissions <app>"
  tally_skip
else
  ok "no installed flatpak app holds home or host filesystem access"
  tally_ok
fi
unset _wide _app _perms

# Existing per-user overrides are worth showing: they are invisible in any GUI
# and silently outlive the app that prompted them.
_overrides="$(flatpak override --user --show 2>/dev/null || true)"
if [[ -n "$_overrides" ]]; then
  step "existing user-level overrides:"
  printf '%s\n' "$_overrides" | sed 's/^/      /'
else
  skip "no user-level flatpak overrides are set"
fi
tally_skip
unset _overrides

summary
