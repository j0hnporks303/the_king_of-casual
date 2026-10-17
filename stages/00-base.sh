#!/usr/bin/env bash
# 00-base.sh -- the command-line tools this repo's own commands rely on,
# plus the ones that make a terminal usable.
#
# Nothing here is a security control. It is the difference between `tkoc doctor`
# being able to answer a question and having to say "install smartmontools".
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'HELP'
00-base -- install the base CLI tools

Usage:
  bash stages/00-base.sh [--dry-run] [--yes] [--diagnostics-only]
  tkoc install base

Two groups:
  diagnostics  what tkoc doctor/audit/uav need to answer fully
               (smartmontools, pciutils, nvme-cli, iproute2, util-linux,
                fwupd, policycoreutils, setools-console, wmctrl)
  daily        ordinary terminal tools (git, ripgrep, fd-find, jq, htop, ...)

--diagnostics-only installs the first group and skips the second.
HELP
}

DIAGNOSTICS_ONLY=disabled
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diagnostics-only) DIAGNOSTICS_ONLY=enabled; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) tkoc_parse_safety_flag "$1" || die "00-base: unknown option: $1"; shift ;;
  esac
done

need_supported_fedora
need_dnf

# Packages tkoc's own read-only commands depend on. Without these the audit
# degrades to "could not check", which looks like a pass and is not one.
diagnostics_packages() {
  printf '%s\n' \
    nftables iproute util-linux \
    smartmontools pciutils nvme-cli \
    fwupd policycoreutils setools-console audit \
    wmctrl
}

daily_packages() {
  printf '%s\n' \
    git curl wget rsync less \
    ripgrep fd-find jq tree htop \
    ShellCheck gnupg2 tar
}

log "Base tooling"
declare -a wanted=()
while read -r pkg; do wanted[${#wanted[@]}]="$pkg"; done < <(diagnostics_packages)
if [[ "$DIAGNOSTICS_ONLY" != enabled ]]; then
  while read -r pkg; do wanted[${#wanted[@]}]="$pkg"; done < <(daily_packages)
fi

declare -a missing=()
for pkg in "${wanted[@]}"; do
  rpm_installed "$pkg" || missing[${#missing[@]}]="$pkg"
done

if (( ${#missing[@]} == 0 )); then
  log "every base package is already installed"
  exit 0
fi

log "missing: ${missing[*]}"
if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  log "dry run: nothing was installed"
  exit 0
fi
tkoc_confirm "Install ${#missing[@]} package(s)?" \
  || { log "Aborted. Nothing installed."; exit 0; }
dnf_install "${missing[@]}"
log "base tooling installed"
