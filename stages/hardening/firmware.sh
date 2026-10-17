#!/usr/bin/env bash
# firmware.sh -- fwupd's reporting back to the LVFS
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Firmware update service"

if ! have_cmd fwupdmgr; then
  skip "fwupd is not installed; no firmware reporting to configure"
  tally_skip
  summary
  exit 0
fi

_root="${TKOC_TEST_ROOT:-}"

# fwupd uploads the result of each firmware update to the LVFS, along with the
# machine's hardware identifiers. What decides whether that happens without
# asking is AutomaticReports (and AutomaticSecurityReports, for the HSI report)
# in each remote that defines a ReportURI. With both off, a report is sent only
# when you say yes at the fwupdmgr prompt after an update. Turning reporting off
# does not stop firmware updates working.
_remotes=0
for _remote in "$_root"/etc/fwupd/remotes.d/*.conf; do
  [[ -r "$_remote" ]] || continue
  grep -Eq '^[[:space:]]*ReportURI[[:space:]]*=[[:space:]]*[^[:space:]]' "$_remote" || continue
  _remotes=$((_remotes + 1))
  _name="$(basename -- "$_remote" .conf)"
  hc_set_config "$_remote" "fwupd Remote" AutomaticReports false "$_name automatic reports"
  if grep -Eq '^[[:space:]]*AutomaticSecurityReports[[:space:]]*=' "$_remote"; then
    hc_set_config "$_remote" "fwupd Remote" AutomaticSecurityReports false "$_name automatic security reports"
  fi
done
if (( _remotes == 0 )); then
  skip "no fwupd remote defines a ReportURI"
  tally_skip
else
  step "reports are now sent only if you approve one at the fwupdmgr prompt after an update"
fi

# An earlier tkoc wrote this drop-in for the job above. It set UpdateMotd --
# the login message -- which has nothing to do with reporting, so it is removed
# rather than left looking like protection.
_noop="$_root/etc/fwupd/fwupd.conf.d/90-tkoc-no-report.conf"
case "$(root_path_state "$_noop")" in
  absent) ;;
  present)
    if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
      step "[dry-run] would remove $_noop (it set UpdateMotd, which does not control reporting)"
      tally_ok
    else
      tkoc_state_capture_file "$_noop"
      if run_root rm -f -- "$_noop"; then
        ok "removed $_noop (it set UpdateMotd, which does not control reporting)"
        tally_ok
      else
        wrn "could not remove $_noop"
        tally_fail
      fi
    fi
    ;;
  *) hc_advise "cannot check for the old no-op drop-in $_noop without sudo; remove it if present" ;;
esac
unset _root _remote _remotes _name _noop

# Pending firmware updates are reported, never applied: a firmware flash is not
# something a privacy category should start on its own.
if fwupdmgr get-updates --no-unreported-check >/dev/null 2>&1; then
  hc_advise "fwupd reports pending firmware updates; review them yourself with: fwupdmgr get-updates"
else
  ok "no pending firmware updates reported"
  tally_ok
fi

summary
