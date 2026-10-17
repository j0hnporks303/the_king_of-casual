#!/usr/bin/env bash
# crash-reports.sh -- stop core dumps and crash dialogs from retaining process memory
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Crash dumps"

# systemd-coredump writes full process memory into the journal by default. That
# is a copy of whatever the process had in RAM -- keys, tokens, documents -- kept
# on disk and readable by anyone who can read the journal.
hc_drop_in /etc/systemd/coredump.conf.d 90-tkoc-no-storage.conf \
'# Managed by tkoc: keep crash dumps out of persistent storage.
[Coredump]
Storage=none
ProcessSizeMax=0' "systemd-coredump storage"

# The kernel-side limit, so nothing writes a dump even if the handler changes.
hc_set_sysctl kernel.core_pattern "|/bin/false" "kernel core pattern"
hc_set_sysctl fs.suid_dumpable 0 "setuid core dumps"

# DrKonqi is KDE's crash dialog; it offers to upload a backtrace to bugs.kde.org.
hc_set_kconfig kdeglobals DrKonqi IgnoreAllKdeCrashes true "KDE crash dialog"

summary
