#!/usr/bin/env bash
# tools/audit.sh -- the full Trust No One posture audit.
#
# Read-only. Reports PASS/WARN/FAIL/INFO and exits non-zero if anything FAILed,
# which makes it usable as the end-to-end gate after applying a tier.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/audit.sh
source "$REPO_ROOT/stages/lib/audit.sh"

LIVE_SYSCTL="${TKOC_TEST_ROOT:-}/etc/sysctl.d/60-tkoc-hardening.conf"

usage() {
  cat <<'HELP'
audit -- Trust No One posture audit

Usage:
  tkoc audit [--no-hardware]

Covers the firewall and sysctl policy match, firewalld contention, Secure Boot,
disk encryption, TPM, measured boot, kernel lockdown and module signing,
SELinux, auditd, CPU mitigations, listening sockets, and known remote-access
tooling -- then runs the same hardware assessment as `tkoc doctor`.

--no-hardware skips the hardware half when you only want the security posture.

Exits non-zero if anything FAILed. Read-only; changes nothing.
HELP
}

hardware=enabled
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-hardware) hardware=disabled; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) die "audit: unknown option: $1" ;;
  esac
done

reset_audit_counts
run_posture_audit "$LIVE_SYSCTL"

if [[ "$hardware" == enabled ]]; then
  audit_say ""
  run_system_health_assessment
fi

audit_say ""
audit_say "summary: $AUDIT_PASS pass, $AUDIT_WARN warning, $AUDIT_FAIL fail"
(( AUDIT_FAIL == 0 ))
