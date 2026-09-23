#!/usr/bin/env bash
# tools/uninstall.sh -- take tkoc off this machine.
#
# Deleting the checkout is not enough on its own: the nftables policy is loaded
# at boot by nftables.service, the sysctl file is read by systemd-sysctl, the
# dispatcher runs on every network change, and every service this repo disabled
# stays disabled. Removing the repo alone leaves a machine still enforcing
# settings with nothing left to turn them off.
#
# Order matters. Anything that re-applies policy is stopped FIRST.
#
#   1. persistence      the NetworkManager dispatcher, the ClamAV timer
#   2. firewall         drop the tkoc table, remove the include, restore firewalld
#   3. kernel           remove the sysctl policy and reload the defaults
#   4. services         nothing is re-enabled automatically -- see below
#   5. command          the ~/.local/bin/tkoc symlink and the root-owned copies
#
# The checkout is never deleted; that is yours to remove.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"
# shellcheck source=../stages/lib/persistence.sh
source "$REPO_ROOT/stages/lib/persistence.sh"

APPLY=disabled
LIVE_NFT="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"
LIVE_SYSCTL="${TKOC_TEST_ROOT:-}/etc/sysctl.d/60-tkoc-hardening.conf"
NFT_SYSCONFIG="${TKOC_TEST_ROOT:-}/etc/sysconfig/nftables.conf"
BIN_LINK="${TKOC_BIN_DIR:-$HOME/.local/bin}/tkoc"
ROOT_LIBEXEC="${TKOC_TEST_ROOT:-}/usr/local/libexec/tkoc"
ROOT_SBIN="${TKOC_TEST_ROOT:-}/usr/local/sbin"

usage() {
  cat <<'HELP'
uninstall -- show, or undo, everything tkoc wrote outside its own directory

Usage:
  tkoc uninstall            Report what would be undone; change nothing
  tkoc uninstall --apply    Actually undo it

Removes the firewall policy and its boot include, the sysctl policy, the
network-watch dispatcher, the ClamAV timer, the root-owned tool copies and the
command symlink, and restores firewalld to the state a snapshot recorded.

It does NOT re-enable services that privacy categories disabled. Turning sshd,
Avahi, Bluetooth and Samba back on wholesale is a bigger change than removing
this tool, and some of them were probably off before you ever ran it. Restore a
snapshot for that:  tkoc state restore <id>

The checkout itself is left alone.
HELP
}

step() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
item() { printf '  %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=enabled; shift ;;
    help|--help|-h) usage; exit 0 ;;
    *) tkoc_parse_safety_flag "$1" || die "uninstall: unknown option: $1"; shift ;;
  esac
done
tkoc_bool_enabled TKOC_DRY_RUN disabled && APPLY=disabled

if [[ "$APPLY" != enabled ]]; then
  log "report only. Re-run with --apply to actually undo this."
fi

do_it() {
  [[ "$APPLY" == enabled ]] || return 0
  "$@"
}

step "1. Persistence"
if [[ -f "$TKOC_DISPATCHER_DIR/90-tkoc-network-watch" ]]; then
  item "remove the NetworkManager dispatcher"
  do_it bash "$SCRIPT_DIR/network-watch.sh" uninstall
else
  item "no network-watch dispatcher installed"
fi
_timer="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/tkoc-clamav.timer"
if [[ -f "$_timer" ]]; then
  item "remove the daily ClamAV timer"
  if [[ "$APPLY" == enabled ]]; then
    # A staged uninstall must never control the real user's systemd instance.
    if [[ -z "${TKOC_TEST_ROOT:-}" ]]; then
      systemctl --user disable --now tkoc-clamav.timer >/dev/null 2>&1 || true
    fi
    rm -f -- "$_timer" "${_timer%.timer}.service"
    if [[ -z "${TKOC_TEST_ROOT:-}" ]]; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi
else
  item "no ClamAV timer installed"
fi
unset _timer

step "2. Firewall"
if [[ -f "$LIVE_NFT" ]]; then
  item "remove $LIVE_NFT and drop the tkoc_host table"
  do_it run_root_path "$LIVE_NFT" rm -f -- "$LIVE_NFT"
  if [[ "$APPLY" == enabled && -z "${TKOC_TEST_ROOT:-}" ]] && command -v nft >/dev/null 2>&1; then
    run_root nft delete table inet tkoc_host >/dev/null 2>&1 || true
  fi
else
  item "no firewall policy installed"
fi
# 0600 root:root on Fedora: read it the way everything else does, or this
# aborts the uninstall part way through with "Permission denied".
_sysconf_body=""
if [[ -f "$NFT_SYSCONFIG" ]] && _sysconf_body="$(read_root_file "$NFT_SYSCONFIG")" \
  && grep -Fq '# >>> tkoc >>>' <<<"$_sysconf_body"; then
  item "remove the tkoc include from $NFT_SYSCONFIG"
  if [[ "$APPLY" == enabled ]]; then
    _tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-uninst.XXXXXX")"
    printf '%s\n' "$_sysconf_body" \
      | awk '/# >>> tkoc >>>/ { skip=1; next } /# <<< tkoc <<</ { skip=0; next } !skip' \
      > "$_tmp"
    run_root_path "$NFT_SYSCONFIG" install -m "$(existing_mode "$NFT_SYSCONFIG" 0600)" \
      -- "$_tmp" "$NFT_SYSCONFIG"
    rm -f -- "$_tmp"; unset _tmp
  fi
elif [[ -f "$NFT_SYSCONFIG" && -z "$_sysconf_body" ]]; then
  item "cannot read $NFT_SYSCONFIG without privilege; re-run with sudo to clear the include"
else
  item "no tkoc include in $NFT_SYSCONFIG"
fi
unset _sysconf_body
if [[ -z "${TKOC_TEST_ROOT:-}" ]] \
  && command -v systemctl >/dev/null 2>&1 \
  && [[ "$(systemctl is-enabled firewalld.service 2>/dev/null || true)" == masked* ]]; then
  item "firewalld is masked; unmask it"
  do_it run_root systemctl unmask firewalld.service
  item "NOTE: firewalld is left stopped. Start it yourself if you want it back:"
  item "      sudo systemctl enable --now firewalld"
fi

step "3. Kernel policy"
if [[ -f "$LIVE_SYSCTL" ]]; then
  item "remove $LIVE_SYSCTL"
  do_it run_root_path "$LIVE_SYSCTL" rm -f -- "$LIVE_SYSCTL"
  item "NOTE: the values it set stay in the running kernel until you reboot,"
  item "      or restore a snapshot that recorded the originals."
  if [[ "$APPLY" == enabled && -z "${TKOC_TEST_ROOT:-}" ]]; then
    run_root systemctl restart systemd-sysctl.service >/dev/null 2>&1 || true
  fi
else
  item "no sysctl policy installed"
fi

step "4. Services"
item "nothing is re-enabled automatically, on purpose."
item "to put the disabled services back exactly as they were:"
item "    tkoc state list"
item "    tkoc state restore <id>"

step "5. Command and root-owned copies"
# Only remove the link if it points into THIS checkout. ~/.local/bin/tkoc is a
# name the macOS edition uses too, and removing somebody else's working command
# because it happens to share a filename is not an uninstall, it is damage.
if [[ -L "$BIN_LINK" ]]; then
  _dest="$(readlink -f -- "$BIN_LINK" 2>/dev/null || readlink -- "$BIN_LINK")"
  if [[ "$_dest" == "$REPO_ROOT"/* ]]; then
    item "remove $BIN_LINK -> $_dest"
    do_it rm -f -- "$BIN_LINK"
  else
    item "leaving $BIN_LINK alone: it points at $_dest, outside this checkout"
  fi
  unset _dest
else
  item "no command symlink at $BIN_LINK"
fi
for _f in "$ROOT_SBIN/tkoc-downlock" "$ROOT_SBIN/tkoc-lockdown" "$ROOT_SBIN/tkoc-apply"; do
  if [[ -e "$_f" ]]; then
    item "remove $_f"
    do_it run_root_path "$_f" rm -f -- "$_f"
  fi
done
unset _f
if [[ -d "$ROOT_LIBEXEC" ]]; then
  item "remove $ROOT_LIBEXEC"
  do_it run_root_path "$ROOT_LIBEXEC" rm -rf -- "$ROOT_LIBEXEC"
fi

printf '\n'
if [[ "$APPLY" == enabled ]]; then
  log "tkoc removed from this machine."
else
  log "nothing was changed. Re-run with --apply to do it."
fi
log "the checkout at $REPO_ROOT was left alone; delete it yourself if you want it gone."
log "recovery snapshots under $TKOC_SNAPSHOT_ROOT were kept."
