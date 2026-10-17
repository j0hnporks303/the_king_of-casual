#!/usr/bin/env bash
# tools/doctor.sh -- read-only system, storage, and driver assessment.
#
# Never repairs a filesystem, starts a SMART self-test, installs a package, or
# changes a driver. Filesystem repair generally requires an unmounted
# filesystem, and driver selection affects whether the machine boots to a
# desktop at all, so this reports evidence for the administrator to act on.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/audit.sh
source "$REPO_ROOT/stages/lib/audit.sh"

usage() {
  cat <<'HELP'
doctor -- read-only system health and driver assessment

Usage:
  tkoc doctor

Inventories mounted filesystems, verifies fstab, checks ext4 and btrfs error
counters and the last btrfs scrub, queries SMART/NVMe health when smartmontools
is installed, checks PCI driver bindings and the graphics stack (including
NVIDIA akmod ownership and Secure Boot module signing), searches 30 days of the
journal for filesystem, driver, and firmware failures, and reports pending
firmware updates.

Exits non-zero if anything FAILed. Changes nothing.
HELP
}

[[ "${1:-}" == help || "${1:-}" == --help || "${1:-}" == -h ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "doctor takes no arguments"

reset_audit_counts
audit_say "System health and driver assessment (read-only)"
audit_say ""
run_system_health_assessment
audit_say ""
audit_say "summary: $AUDIT_PASS pass, $AUDIT_WARN warning, $AUDIT_FAIL fail"
audit_say "no filesystems were repaired, SMART tests started, or drivers installed"
(( AUDIT_FAIL == 0 ))
