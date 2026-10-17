#!/usr/bin/env bash
# selinux.sh -- verify SELinux is enforcing. Advisory only, by design.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "SELinux"

# This category deliberately never changes SELinux state.
#
# Switching a permissive system to enforcing can make it unbootable: if the
# filesystem has been relabelled incorrectly, or a service has been running
# under a context it was never confined to, enforcing mode denies it at the next
# boot with no obvious message. Going from disabled to enforcing requires a full
# relabel, which is a reboot-and-wait operation, not a toggle. Both are real
# decisions for the administrator, taken after reading the denials -- so what
# happens here is a report.

# This category reports; it never changes SELinux state. So a finding here --
# even "the tools are missing on a Fedora system", which is a real problem --
# counts as a skip, not a failure. A failure would roll back the entire
# privacy run, and rolling back a dozen applied categories because a report
# could not be produced is not a proportionate response to a report.
if ! have_cmd getenforce; then
  wrn "SELinux userspace tools are not installed on a Fedora system"
  step "install them with: sudo dnf install policycoreutils selinux-policy-targeted"
  tally_skip
  summary
  exit 0
fi

_mode="$(getenforce 2>/dev/null || printf unknown)"
case "$_mode" in
  Enforcing)
    ok "SELinux is enforcing"
    tally_ok
    ;;
  Permissive)
    wrn "SELinux is permissive: policy violations are logged but not blocked"
    step "review what would be denied first:  sudo ausearch -m AVC -ts recent"
    step "then make it permanent yourself:     sudo setenforce 1 && edit /etc/selinux/config"
    tally_skip
    ;;
  Disabled)
    wrn "SELinux is disabled on a Fedora system"
    step "re-enabling needs a full filesystem relabel and a reboot:"
    step "  set SELINUX=permissive in /etc/selinux/config, then: sudo fixfiles -F onboot && sudo reboot"
    step "confirm it is clean in permissive mode before moving to enforcing"
    tally_skip
    ;;
  *)
    wrn "SELinux mode could not be determined"
    tally_skip
    ;;
esac
unset _mode

# A pending relabel flag means the last boot was expected to relabel and may not
# have finished; that leaves files with the wrong context.
if [[ -e /.autorelabel ]]; then
  hc_advise "/.autorelabel exists: a filesystem relabel is scheduled for the next boot"
fi

# Denials since boot are worth surfacing even on an enforcing system: they are
# usually either a real misconfiguration or an app that silently lost a feature.
if have_cmd ausearch; then
  _denials="$(ausearch -m AVC -ts boot 2>/dev/null | grep -c 'denied' || true)"
  if [[ "$_denials" =~ ^[0-9]+$ ]] && (( _denials > 0 )); then
    hc_advise "$_denials SELinux denial(s) since boot; review with: sudo ausearch -m AVC -ts boot"
  else
    ok "no SELinux denials since boot"
    tally_ok
  fi
  unset _denials
fi

summary
