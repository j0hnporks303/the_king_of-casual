#!/usr/bin/env bash
# tools/postcheck.sh -- read-only status report. Safe any time; modifies nothing.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

usage() {
  cat <<'HELP'
status -- what this machine looks like right now

Usage:
  tkoc status

One page covering the platform, the firewall tier, the privacy posture, the
remote-access surface, recovery snapshots, and the managed dotfiles. Read-only
and never asks for privilege.
HELP
}

[[ "${1:-}" == help || "${1:-}" == --help || "${1:-}" == -h ]] && { usage; exit 0; }

section() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
line()    { printf '  %-30s %s\n' "$1" "$2"; }

unit_state() {
  local unit="$1"
  if ! unit_exists "$unit"; then printf 'not installed'
  elif unit_active "$unit"; then printf 'RUNNING'
  elif unit_enabled "$unit"; then printf 'enabled, not running'
  else printf 'off'; fi
}

section "Platform"
line "os" "$(tkoc_os_release PRETTY_NAME 2>/dev/null || printf 'not a Linux with /etc/os-release')"
line "kernel" "$(uname -r)"
line "desktop" "${XDG_CURRENT_DESKTOP:-unknown}"
line "selinux" "$(getenforce 2>/dev/null || printf unavailable)"

section "Firewall"
bash "$SCRIPT_DIR/firewall-status.sh" 2>/dev/null | sed -n '/Installed policy/,/^$/p' | sed '1d;$d' || true
line "nftables.service" "$(unit_state nftables.service)"
line "firewalld" "$(unit_state firewalld.service)"

section "Privacy posture"
PRIVACY_STATE_FILE="${TKOC_STATE_HOME}/privacy-status"
if [[ -r "$PRIVACY_STATE_FILE" ]]; then
  line "last applied level" "$(awk -F= '$1=="level"{print $2; exit}' "$PRIVACY_STATE_FILE")"
  line "applied at" "$(awk -F= '$1=="applied_utc"{print $2; exit}' "$PRIVACY_STATE_FILE")"
else
  line "last applied level" "never (run: tkoc privacy strong)"
fi

section "Remote access surface"
for _unit in sshd.service cockpit.socket avahi-daemon.service cups-browsed.service \
             bluetooth.service rpcbind.service smb.service nfs-server.service; do
  line "$_unit" "$(unit_state "$_unit")"
done
unset _unit
# A bare count invites the obvious question -- "14 of what?" -- so name them.
# Sockets bound to loopback or an AF_UNIX path are separated from the ones
# actually reachable from another machine, because that is the distinction
# that matters and it is not visible in `systemctl`.
if command -v ss >/dev/null 2>&1; then
  _all="$(ss -H -lntu 2>/dev/null | wc -l | tr -d '[:space:]')"
  _offhost="$(ss -H -lntu 2>/dev/null \
    | awk '$5 !~ /^(127\.|\[::1\]|\*:68$)/ { print $5 }' | sort -u)"
  _offcount="$(printf '%s' "$_offhost" | grep -c . || true)"
  line "listening sockets" "${_all:-0} total, ${_offcount:-0} not loopback-only"
  if [[ "${_offcount:-0}" != 0 ]]; then
    printf '%s\n' "$_offhost" | sed 's/^/      /'
    printf '      (the firewall still decides what reaches these: tkoc uav show all)\n'
  fi
  unset _all _offhost _offcount
fi
# systemd-ssh-generator creates this; it is an AF_UNIX path under /run, not
# TCP/22. It stays "listening" after sshd is off, which looks wrong and is not.
if unit_exists sshd-unix-local.socket; then
  line "sshd-unix-local.socket" "local AF_UNIX only, not a network listener"
fi

section "Recovery"
_count="$(tkoc_state_snapshots 2>/dev/null | wc -l | tr -d '[:space:]')"
line "snapshots" "${_count:-0}"
if [[ "${_count:-0}" != 0 ]]; then
  line "newest" "$(_tkoc_basename "$(tkoc_state_snapshots | head -1)")"
fi
unset _count

section "Managed dotfiles"
_dotfiles="${XDG_CONFIG_HOME:-$HOME/.config}/tkoc/dotfiles"
if [[ -d "$_dotfiles" ]]; then
  line "linked into" "$_dotfiles"
  line "prompt theme" "$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/tkoc/prompt-theme" 2>/dev/null || printf 'not selected')"
else
  line "dotfiles" "not deployed (run: tkoc dotfiles)"
fi
unset _dotfiles
printf '\n'
