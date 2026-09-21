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
hc_set_config /etc/dnf/dnf.conf main countme False "dnf countme reporting"

# The same counting happens through the mirror URL when it is enabled per-repo.
if [[ -d /etc/yum.repos.d ]]; then
  if grep -rlq '^countme=1' /etc/yum.repos.d 2>/dev/null; then
    hc_advise "countme=1 is set in individual files under /etc/yum.repos.d; review them (grep -rn '^countme' /etc/yum.repos.d)"
  else
    skip "no repo file under /etc/yum.repos.d sets countme=1"
    tally_skip
  fi
fi

# Firmware/LVFS reporting is its own category (strong tier); see firmware.sh.

summary
