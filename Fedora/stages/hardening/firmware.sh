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

# fwupd uploads the result of each firmware update to the LVFS, along with the
# machine's hardware identifiers. Turning reporting off does not stop firmware
# updates working; it stops the report afterwards.
hc_drop_in /etc/fwupd/fwupd.conf.d 90-tkoc-no-report.conf \
'# Managed by tkoc: do not upload firmware update reports to the LVFS.
[fwupd]
UpdateMotd=false' "fwupd result reporting"

# Reporting is also governed per-remote by ReportURI.
_reporting=""
for _remote in /etc/fwupd/remotes.d/*.conf; do
  [[ -r "$_remote" ]] || continue
  grep -Eq '^[[:space:]]*ReportURI[[:space:]]*=[[:space:]]*http' "$_remote" \
    && _reporting+=" $(basename -- "$_remote")"
done
if [[ -n "$_reporting" ]]; then
  hc_advise "these fwupd remotes still define a ReportURI:$_reporting (comment it out in /etc/fwupd/remotes.d/ to stop result uploads entirely)"
else
  skip "no fwupd remote defines a ReportURI"
  tally_skip
fi
unset _reporting _remote

# Pending firmware updates are reported, never applied: a firmware flash is not
# something a privacy category should start on its own.
if fwupdmgr get-updates --no-unreported-check >/dev/null 2>&1; then
  hc_advise "fwupd reports pending firmware updates; review them yourself with: fwupdmgr get-updates"
else
  ok "no pending firmware updates reported"
  tally_ok
fi

summary
