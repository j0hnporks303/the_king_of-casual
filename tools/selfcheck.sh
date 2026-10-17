#!/usr/bin/env bash
# tools/selfcheck.sh -- pre-flight checks before running any tkoc stage.
# Read-only. Reports findings. Never modifies the system and never calls sudo.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

ok_count=0
warn_count=0
blocker_count=0

# Two classes of finding, because they mean different things. A missing
# optional tool degrades a report; a missing required tool or an invalid policy
# file means a command will not work. Only the second class sets the exit
# status, so `tkoc check` does not fail on a perfectly healthy machine that
# simply has no flatpak installed.
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ ok ]  %s\n' "$label"
    ok_count=$((ok_count+1))
  else
    printf '  [WARN]  %s\n' "$label"
    warn_count=$((warn_count+1))
  fi
}

require() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [ ok ]  %s\n' "$label"
    ok_count=$((ok_count+1))
  else
    printf '  [FAIL]  %s\n' "$label"
    blocker_count=$((blocker_count+1))
  fi
}

note() { printf '          %s\n' "$*"; }

usage() {
  cat <<'HELP'
selfcheck -- read-only pre-flight for the Fedora tkoc edition

Usage:
  bash tools/selfcheck.sh
  tkoc check

Verifies the platform, the required tools, and that every shipped policy file
parses. Changes nothing and never asks for privilege.
HELP
}

[[ "${1:-}" == help || "${1:-}" == --help || "${1:-}" == -h ]] && { usage; exit 0; }

printf '\nPlatform\n'
require "running Linux" test "$(uname -s)" = Linux
require "Fedora-family /etc/os-release" is_fedora
note "detected: $(tkoc_os_release PRETTY_NAME 2>/dev/null || printf unknown)"

printf '\nRequired tools\n'
require "nft (nftables)" command -v nft
require "systemctl (systemd)" command -v systemctl
require "dnf" command -v dnf
require "rpm" command -v rpm
require "ss (iproute2)" command -v ss
require "nmcli (NetworkManager)" command -v nmcli

printf '\nOptional tools\n'
check "kwriteconfig6 (KDE Plasma 6)" command -v kwriteconfig6
check "smartctl (smartmontools)" command -v smartctl
check "lspci (pciutils)" command -v lspci
check "fwupdmgr (fwupd)" command -v fwupdmgr
check "flatpak" command -v flatpak
check "getenforce (SELinux tools)" command -v getenforce

printf '\nConflicting services\n'
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld.service 2>/dev/null; then
  printf '  [WARN]  firewalld is running and also manages nftables\n'
  note "applying a tkoc firewall tier will offer to disable and mask it"
  warn_count=$((warn_count+1))
else
  printf '  [ ok ]  nothing else is managing the nftables ruleset\n'
  ok_count=$((ok_count+1))
fi

printf '\nShipped policy files\n'
render_check() {
  local label="$1" out
  shift
  out="$(mktemp "${TMPDIR:-/tmp}/tkoc-selfcheck.XXXXXX")"
  if "$@" "$out" >/dev/null 2>&1; then
    printf '  [ ok ]  %s\n' "$label"
    ok_count=$((ok_count+1))
  else
    printf '  [FAIL]  %s\n' "$label"
    blocker_count=$((blocker_count+1))
  fi
  rm -f -- "$out"
}

nft_tier() {
  local out="${!#}"
  tkoc_render_markers "$REPO_ROOT/config/firewall/tkoc.nft" "$out" "${@:1:$#-1}" \
    && tkoc_validate_nft "$out"
}

render_check "firewall template renders and validates (vanilla)" nft_tier
render_check "firewall template renders and validates (strong)" nft_tier TKOC_LAN_NOISE TKOC_IPV6_OFF
render_check "firewall template renders and validates (lockdown)" nft_tier TKOC_LAN_NOISE TKOC_IPV6_OFF TKOC_DNS_ENFORCE
require "sysctl policy parses" tkoc_validate_sysctl "$REPO_ROOT/config/sysctl.d/60-tkoc-hardening.conf"
require "theme configuration is valid" bash "$REPO_ROOT/stages/60-ricing.sh" validate
require "ice manifest is valid" bash "$REPO_ROOT/tools/ice.sh" list

printf '\nShell snippets\n'
for snippet in "$REPO_ROOT"/config/dotfiles/shell.d/*.sh; do
  require "$(basename -- "$snippet") parses" bash -n "$snippet"
done

printf '\n  %d ok, %d warning(s), %d blocker(s)\n' "$ok_count" "$warn_count" "$blocker_count"
if (( blocker_count > 0 )); then
  printf '  Blockers mean a tkoc command will not work. Warnings only mean a\n'
  printf '  report will be less complete; "tkoc install base" installs the\n'
  printf '  optional diagnostic tools.\n\n'
else
  printf '\n'
fi
(( blocker_count == 0 ))
