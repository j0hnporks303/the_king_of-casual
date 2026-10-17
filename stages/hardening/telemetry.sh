#!/usr/bin/env bash
# telemetry.sh -- disable crash/usage reporting back to Fedora and Red Hat
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Telemetry and reporting"

# ABRT collects crashes and offers to upload them, including process memory in
# some configurations. The whole family goes, not just abrtd: each sub-unit
# harvests a different source and any one of them left running keeps collecting.
for _unit in abrtd.service abrt-journal-core.service abrt-oops.service \
             abrt-xorg.service abrt-vmcore.service abrt-pstoreoops.service; do
  hc_disable_unit "$_unit" "crash reporting"
done
unset _unit

# DNF's "countme" flag tags one request per week per system with a rough age
# bucket, so Fedora can count installs. It is a deliberate, documented metric
# and it is still a phone-home; off by explicit choice here.
_root="${TKOC_TEST_ROOT:-}"
hc_set_config "$_root/etc/dnf/dnf.conf" main countme False "dnf countme reporting"

# That alone changes nothing for Fedora's own repositories: fedora.repo,
# fedora-updates.repo and fedora-updates-testing.repo each set countme=1, and a
# per-repo setting wins over [main]. dnf5 reads per-repo overrides from
# /etc/dnf/repos.override.d, which survive package upgrades without editing the
# package-owned repo files -- so that is where countme goes off.
_repos_dir="$_root/etc/yum.repos.d"
_countme_repos="$(awk '
    FNR == 1 { section = "" }
    /^[[:space:]]*\[/ { section = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section); next }
    section != "" && /^[[:space:]]*countme[[:space:]]*=[[:space:]]*(1|[Tt]rue|[Yy]es|[Oo]n)[[:space:]]*$/ { print section }
  ' "$_repos_dir"/*.repo 2>/dev/null | LC_ALL=C sort -u || true)"

if [[ -z "$_countme_repos" ]]; then
  skip "no repository under /etc/yum.repos.d sets countme=1"
  tally_skip
elif [[ "$(tkoc_dnf_major)" != 5 ]]; then
  hc_advise "countme=1 is set per-repo for: $(paste -sd' ' - <<<"$_countme_repos"); dnf4 has no override directory, so turn it off with: sudo dnf config-manager --save --setopt=<repo>.countme=0"
else
  _override='# Managed by tkoc: do not send DNF'"'"'s weekly "countme" install count.
# Per-repo, because Fedora'"'"'s repo files set countme=1 and that wins over dnf.conf.'
  while IFS= read -r _repo; do
    _override+=$'\n\n'"[$_repo]"$'\ncountme=0'
  done <<<"$_countme_repos"
  hc_drop_in "$_root/etc/dnf/repos.override.d" 90-tkoc-no-countme.repo "$_override" \
    "per-repository countme" none

  # Trust dnf's own answer, not the file: anything that sorts after this
  # override (dnf config-manager writes 99-config_manager.repo) can undo it.
  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    _still_on=""
    while IFS= read -r _repo; do
      _value="$(dnf ${_root:+--installroot="$_root"} --dump-repo-config="$_repo" 2>/dev/null \
        | awk -F'=' '{ gsub(/[[:space:]]/, "", $1) } $1 == "countme" { gsub(/[[:space:]]/, "", $2); print $2; exit }' || true)"
      [[ "$_value" == 0 || "$_value" == false ]] || _still_on+=" $_repo(${_value:-unknown})"
    done <<<"$_countme_repos"
    if [[ -z "$_still_on" ]]; then
      ok "dnf reports countme off for every repository that had it on"
      tally_ok
    else
      wrn "dnf still reports countme on for:$_still_on -- check /etc/dnf/repos.override.d for a later override"
      tally_fail
    fi
  fi
fi
unset _root _repos_dir _countme_repos _override _repo _still_on _value

# Firmware/LVFS reporting is its own category (strong tier); see firmware.sh.

summary
