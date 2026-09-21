#!/usr/bin/env bash
# 50-antivirus.sh -- ClamAV, opt-in, with an optional daily systemd timer.
#
# Never installed as part of a tier. An on-access scanner is a real performance
# and false-positive cost, and that is a choice, not a default.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/persistence.sh
source "$SCRIPT_DIR/lib/persistence.sh"

ENABLE_DAILY="$(tkoc_bool_value TKOC_ENABLE_CLAMAV_DAILY disabled)"
SCAN_PATHS="${TKOC_CLAMAV_PATHS:-$HOME/Downloads $HOME/Desktop $HOME/Documents}"

usage() {
  cat <<'HELP'
50-antivirus -- install ClamAV and optionally a daily scan timer

Usage:
  bash stages/50-antivirus.sh [--daily] [--dry-run] [--yes]
  tkoc clamav install
  tkoc clamav install --daily

Installs clamav, clamav-update and clamd, then refreshes signatures with
freshclam. With --daily it also installs a systemd timer that scans your
Downloads, Desktop and Documents once a day as your own user -- not as root, and
not over the whole filesystem.

The timer is removed by: tkoc clamav uninstall-daily
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daily) ENABLE_DAILY=enabled; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) tkoc_parse_safety_flag "$1" || die "50-antivirus: unknown option: $1"; shift ;;
  esac
done

need_supported_fedora
log "ClamAV"
dnf_install clamav clamav-update clamd

if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  log "[dry-run] would run freshclam to fetch signatures"
else
  log "updating signatures (this takes a minute on a first run)"
  run_root freshclam || warn "freshclam failed; signatures may be stale"
fi

[[ "$ENABLE_DAILY" == enabled ]] || {
  log "ClamAV installed. Scan something with: tkoc clamav scan ~/Downloads"
  exit 0
}

# A user-level timer, not a system one: scanning your own files needs your
# privileges, and a root scanner reading every user's home is a bigger change
# than "check my downloads".
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
log "installing the daily scan timer for $(id -un)"

if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  log "[dry-run] would write $UNIT_DIR/tkoc-clamav.{service,timer}"
  exit 0
fi

mkdir -p -- "$UNIT_DIR"
cat > "$UNIT_DIR/tkoc-clamav.service" <<UNIT
[Unit]
Description=tkoc daily ClamAV scan of this user's own files

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/clamscan -ri --bell $SCAN_PATHS
UNIT

cat > "$UNIT_DIR/tkoc-clamav.timer" <<'UNIT'
[Unit]
Description=Run the tkoc ClamAV scan daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now tkoc-clamav.timer 2>/dev/null \
  && log "daily scan enabled (systemctl --user list-timers to see it)" \
  || warn "could not enable the user timer; is a user systemd session running?"
