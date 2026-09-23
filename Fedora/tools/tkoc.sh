#!/usr/bin/env bash
# tools/tkoc.sh -- the_king_of-casual unified CLI, Fedora edition.
#
# One command. Everything else in this repo is reachable through it, and the
# scripts underneath are meant to be read and edited directly when you want
# something this CLI does not expose.
set -Eeuo pipefail

# `make` installs a symlink. Resolve it before locating the checkout, including
# relative links and links through another directory; HOME is not its location.
_tkoc_self="${BASH_SOURCE[0]}"
while [[ -L "$_tkoc_self" ]]; do
  _tkoc_dir="$(cd -- "$(dirname -- "$_tkoc_self")" && pwd -P)"
  _tkoc_self="$(readlink -- "$_tkoc_self")"
  [[ "$_tkoc_self" == /* ]] || _tkoc_self="$_tkoc_dir/$_tkoc_self"
done
REPO_ROOT="$(cd -- "$(dirname -- "$_tkoc_self")/.." && pwd -P)"

[[ -f "$REPO_ROOT/stages/lib/common.sh" ]] \
  || { printf 'tkoc: cannot locate repo root from %s\n' "$REPO_ROOT" >&2; exit 1; }

for _tkoc_lib in stages/lib/common.sh stages/lib/state.sh; do
  [[ -f "$REPO_ROOT/$_tkoc_lib" ]] \
    || { printf 'tkoc: missing required library: %s\n' "$_tkoc_lib" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$REPO_ROOT/$_tkoc_lib"
done
unset _tkoc_lib

_header() { printf '\n\033[1;36m==> tkoc: %s\033[0m\n' "$*"; }
_die()    { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
_ok()     { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
_warn_()  { printf '\033[1;33m warn\033[0m %s\n' "$*"; }
_deprecated() { _warn_ "'$1' is a deprecated alias; use '$2'."; }

_tool()  { bash "$REPO_ROOT/tools/$1.sh" "${@:2}"; }
_stage() { bash "$REPO_ROOT/stages/$1.sh" "${@:2}"; }

_stage_script() {
  case "$1" in
    base)              printf '00-base' ;;
    hardening|firewall) printf '40-hardening' ;;
    wireguard|wg)      printf '45-wireguard' ;;
    antivirus|clamav)  printf '50-antivirus' ;;
    privacy)           printf '55-privacy' ;;
    ricing|theme)      printf '60-ricing' ;;
    postcheck|status)  printf '99-postcheck' ;;
    *) _die "Unknown stage '$1'. Valid: base hardening wireguard antivirus privacy ricing postcheck" ;;
  esac
}

# ── Commands ────────────────────────────────────────────────────

cmd_check()  { _header "Pre-flight selfcheck"; _tool selfcheck "$@"; }
cmd_status() { _tool postcheck "$@"; }
cmd_doctor() { _tool doctor "$@"; }
cmd_audit()  { _tool audit "$@"; }
cmd_state()  { _tool state "$@"; }
cmd_uav()    { _tool uav "$@"; }
cmd_pgp()    { _tool pgp "$@"; }
cmd_link()   { _tool linker "$@"; }
cmd_killall()   { _tool killall "$@"; }
cmd_update()    { _header "Update report"; need_not_root; _tool update "$@"; }
cmd_uninstall() { _tool uninstall "$@"; }
cmd_dotfiles()  { _tool dotfiles "$@"; }
cmd_ice()       { _header "Optional customization packages"; _tool ice "$@"; }

cmd_theme() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && _die "Run 'tkoc theme' as your normal user, not root."
  _stage 60-ricing "$@"
}

cmd_firewall() {
  local sub="${1:-status}"
  case "$sub" in
    status|show)
      _header "Firewall status"
      if (( $# > 0 )); then shift; fi
      _tool firewall-status "$@" ;;
    test|check)
      shift; _header "Firewall live test"; _tool firewall-test "$@" ;;
    learn)
      shift; _header "Learning the current network"; _tool network-learn "$@" ;;
    auto)
      shift; _header "Applying the matching network profile"; _tool network-profile "$@" ;;
    watch)
      shift; _header "Automatic per-network DNS and IPv6"; _tool network-watch "$@" ;;
    help|--help|-h)
      cat <<'HELP'
Usage:
  tkoc firewall status
  tkoc firewall test [--local-only] [--ports 22,445]
  tkoc firewall test --inbound-check [port]
  tkoc firewall learn
  tkoc firewall auto [--dry-run] [--yes]
  tkoc firewall watch [install|uninstall|status]
  tkoc firewall vanilla [options]
  tkoc firewall strong [options]
  tkoc firewall lockdown [options]

Tiers:
  vanilla   Default-deny inbound and forwarded; permissive egress
  strong    + LAN discovery dropped, IPv6 off, sysctl hardening
  lockdown  + DNS pinned to one resolver, DNS-over-TLS/QUIC dropped

HELP
      tkoc_print_lockdown_note
      printf '\n"learn" captures the Wi-Fi network you are on right now (SSID, BSSID,\n'
      printf 'gateway) into config/network-profiles.json -- it shows what it found and\n'
      printf 'asks before saving.\n'
      printf '"auto" matches the current SSID against that file and applies the profile'"'"'s\n'
      printf 'DNS and IPv6 -- edit the file first; it asks to confirm.\n'
      printf '"watch" installs a root-owned NetworkManager dispatcher that re-applies DNS\n'
      printf 'and IPv6 (only those two -- never the tier, the ruleset, or a service) on\n'
      printf 'every network change, unattended.\n'
      printf '\nOptions:\n'
      # Printed from stages/lib/common.sh so this list cannot drift from the
      # flags stages/40-hardening.sh actually accepts.
      tkoc_print_firewall_options
      ;;
    vanilla|basic|strong|lockdown|--vanilla|--basic|--strong|--lockdown|--ipv6|--ipv6-enabled|--ipv6-disabled|--dns|--no-dns|--dry-run|-n|--interface|--keep-firewalld|--wireguard|--wg|--no-wireguard|--ssh|--ssh=*|--ssh-source|--ssh-source=*|--no-ssh|--yes|-y|--allow-unsupported)
      _header "Applying firewall hardening"
      _stage 40-hardening "$@" ;;
    *)
      _die "Usage: tkoc firewall [status|test|learn|auto|watch|vanilla|strong|lockdown] [options]" ;;
  esac
}

cmd_privacy() {
  local sub="${1:-help}"
  case "$sub" in
    basic|strong|lockdown)
      _header "Applying privacy level: $sub"; shift
      TKOC_PRIVACY_LEVEL="$sub" _stage 55-privacy "$@" ;;
    apply|run)
      shift
      local level="${TKOC_PRIVACY_LEVEL:-strong}"
      if [[ -n "${1:-}" && "$1" != -* ]]; then level="$1"; shift; fi
      _header "Applying privacy level: $level"
      TKOC_PRIVACY_LEVEL="$level" _stage 55-privacy "$@" ;;
    status)
      _header "Privacy posture"; _stage 55-privacy --status ;;
    list|list-categories)
      _stage 55-privacy --list-categories ;;
    # Forward instead of falling through to the help text below. A documented
    # feature that silently prints help and exits 0 is worse than one that
    # errors: it looks like it worked.
    --categories|--categories=*|--category|--dry-run|-n|--yes|-y|--allow-unsupported|--ssh|--no-ssh|--list-categories|--status)
      _header "Applying privacy categories"; _stage 55-privacy "$@" ;;
    help|--help|-h)
      cat <<'HELP'
Usage:
  tkoc privacy basic                           Non-breaking defaults
  tkoc privacy strong                          + location, KDE, packaging (default)
  tkoc privacy lockdown                        + bluetooth, sharing, resolved, sysctl
  tkoc privacy apply [basic|strong|lockdown]   Apply a level
  tkoc privacy --categories telemetry,discovery
  tkoc privacy list                            Every category and its level
  tkoc privacy status                          Show the current posture

Levels:
  basic     remote access off, ABRT/telemetry off, crash dumps off, mDNS off
  strong    + geoclue, KDE telemetry/Baloo, dnf/flatpak review, fwupd reporting
  lockdown  + bluetooth, Samba/NFS/rpcbind, SELinux report, resolved, sysctl

HELP
      tkoc_print_lockdown_note
      printf '\nOptions:\n'
      # Printed from stages/lib/common.sh so this cannot drift from what
      # stages/55-privacy.sh accepts.
      tkoc_print_privacy_options
      cat <<'HELP'

--ssh-source is a firewall-tier flag; use tkoc harden or tkoc firewall for it.

Nothing here flips SELinux. The selinux category reports the mode and tells you
how to change it; doing it for you can leave a machine that will not boot.
HELP
      ;;
    -*) _die "Unknown privacy option: $sub. Run 'tkoc privacy help'." ;;
    *)  _die "Unknown privacy subcommand: $sub. Run 'tkoc privacy help'." ;;
  esac
}

# ── harden: privacy + firewall together ─────────────────────────

_apply_harden_profile() {
  case "$1" in
    basic)    export TKOC_PRIVACY_LEVEL=basic    TKOC_FW_LEVEL=vanilla  TKOC_IPV6=enabled ;;
    strong)   export TKOC_PRIVACY_LEVEL=strong   TKOC_FW_LEVEL=strong   TKOC_IPV6=disabled ;;
    lockdown) export TKOC_PRIVACY_LEVEL=lockdown TKOC_FW_LEVEL=lockdown TKOC_IPV6=disabled ;;
    *) _die "Unknown hardening level '$1'. Use: basic, strong, lockdown" ;;
  esac
}

_parse_harden_args() {
  HARDEN_LEVEL="strong"
  HARDEN_FIREWALL="enabled"
  HARDEN_PRIVACY="enabled"
  HARDEN_EXTRA=()

  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      basic|strong|lockdown|--basic|--strong|--lockdown)
        HARDEN_LEVEL="${1#--}"; shift ;;
      *) rest[${#rest[@]}]="$1"; shift ;;
    esac
  done

  _apply_harden_profile "$HARDEN_LEVEL"

  set -- ${rest[@]+"${rest[@]}"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --firewall)
        [[ $# -ge 2 ]] || _die "--firewall requires vanilla, strong, or lockdown"
        export TKOC_FW_LEVEL="$2"; shift 2 ;;
      --privacy)
        [[ $# -ge 2 ]] || _die "--privacy requires basic, strong, or lockdown"
        export TKOC_PRIVACY_LEVEL="$2"; shift 2 ;;
      --ipv6)
        [[ $# -ge 2 ]] || _die "--ipv6 requires enabled or disabled"
        export TKOC_IPV6="$2"; shift 2 ;;
      --ipv6-enabled)  export TKOC_IPV6=enabled; shift ;;
      --ipv6-disabled) export TKOC_IPV6=disabled; shift ;;
      --dns)
        [[ $# -ge 2 && "$2" != --* ]] || _die "--dns requires a resolver IP"
        export TKOC_ENFORCE_DNS=enabled ROUTER_DNS="$2"; shift 2 ;;
      --no-dns) export TKOC_ENFORCE_DNS=disabled; shift ;;
      --keep-firewalld) HARDEN_EXTRA[${#HARDEN_EXTRA[@]}]="--keep-firewalld"; shift ;;
      --wireguard|--wg) export TKOC_ALLOW_WIREGUARD=enabled; shift ;;
      --ssh|--ssh=*|--ssh-source|--ssh-source=*|--no-ssh)
        tkoc_parse_ssh_flag "$@"; shift "$TKOC_FLAG_SHIFT" ;;
      --firewall-only) HARDEN_PRIVACY="disabled"; shift ;;
      --privacy-only)  HARDEN_FIREWALL="disabled"; shift ;;
      help|--help|-h)
        cat <<'HELP'
Usage:
  tkoc harden [basic|strong|lockdown] [options]

Profiles:
  basic     privacy=basic,    firewall=vanilla,  ipv6=enabled
  strong    privacy=strong,   firewall=strong,   ipv6=disabled
  lockdown  privacy=lockdown, firewall=lockdown, ipv6=disabled

Options:
  --firewall vanilla|strong|lockdown
  --privacy basic|strong|lockdown
  --ipv6 enabled|disabled
  --dns <resolver-ip> | --no-dns
  --keep-firewalld
  --wireguard
  --ssh[=<source-ip-or-cidr>] | --ssh-source <cidr> | --no-ssh
  --firewall-only | --privacy-only
  --dry-run | --yes | --allow-unsupported

One recovery snapshot covers both stages, so a failure in either rolls the
whole run back rather than leaving the machine half-hardened.
HELP
        exit 0 ;;
      *)
        if tkoc_parse_safety_flag "$1"; then shift; continue; fi
        _die "Unknown harden option: $1" ;;
    esac
  done
}

cmd_harden() {
  need_not_root
  _parse_harden_args "$@"
  need_supported_fedora
  tkoc_guard_ambient_ssh "$TKOC_FW_LEVEL"

  _header "Hardening: $HARDEN_LEVEL"
  printf '  privacy:  %s\n' "$TKOC_PRIVACY_LEVEL"
  printf '  firewall: %s\n' "$TKOC_FW_LEVEL"
  printf '  ipv6:     %s\n' "$(tkoc_bool_value TKOC_IPV6 disabled)"
  printf '  ssh:      %s\n' "$(tkoc_bool_value TKOC_ALLOW_SSH disabled)"

  tkoc_confirm "Apply this hardening profile?" \
    || { _warn_ "Aborted. No changes made."; return 0; }

  if ! tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    tkoc_state_begin "tkoc harden" "$@" >/dev/null
    _ok "Recovery snapshot: $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT")"
  fi

  # The firewall stage's remote-access handling and the privacy stage's
  # remote-access category do identical work, each self-sufficient so its stage
  # works standalone. Running both back to back would apply it twice.
  local both_stages=disabled
  tkoc_bool_enabled HARDEN_FIREWALL enabled && tkoc_bool_enabled HARDEN_PRIVACY enabled \
    && both_stages=enabled

  local rc=0
  if tkoc_bool_enabled HARDEN_FIREWALL enabled; then
    TKOC_UPDATE_YES=enabled _stage 40-hardening "$TKOC_FW_LEVEL" \
      ${HARDEN_EXTRA[@]+"${HARDEN_EXTRA[@]}"} || rc=$?
  fi
  if (( rc == 0 )) && tkoc_bool_enabled HARDEN_PRIVACY enabled; then
    TKOC_UPDATE_YES=enabled TKOC_SKIP_REMOTE_ACCESS="$both_stages" \
      _stage 55-privacy "$TKOC_PRIVACY_LEVEL" || rc=$?
  fi

  if (( rc != 0 )); then
    tkoc_state_fail
    _warn_ "Hardening failed; attempting recovery from $(_tkoc_basename "${TKOC_ACTIVE_SNAPSHOT:-}")."
    tkoc_state_restore "$TKOC_ACTIVE_SNAPSHOT" enabled \
      || _warn_ "Automatic recovery was incomplete. Run: tkoc state restore $(_tkoc_basename "$TKOC_ACTIVE_SNAPSHOT") --force"
    return "$rc"
  fi
  [[ -z "${TKOC_ACTIVE_SNAPSHOT:-}" ]] || tkoc_state_finish
  _ok "Hardening complete. Verify with: sudo $(printf '%q' "$REPO_ROOT/tools/tkoc.sh") audit"
}

# ── Remaining groups ────────────────────────────────────────────

cmd_install() {
  local stage="${1:-}"
  case "$stage" in
    help|--help|-h)
      printf 'Usage: tkoc install <stage> [options]\nStages: base hardening wireguard antivirus privacy ricing postcheck\n'
      return 0 ;;
  esac
  [[ -n "$stage" ]] || _die "Usage: tkoc install <stage>"
  shift
  local script; script="$(_stage_script "$stage")"
  _header "Running stage: $stage"
  _stage "$script" "$@"
}

cmd_clamav() {
  local sub="${1:-help}"
  case "$sub" in
    install)
      _header "Installing ClamAV"; shift; _stage 50-antivirus "$@" ;;
    install-daily|daily)
      _header "Installing ClamAV plus the daily scan timer"; shift
      _stage 50-antivirus --daily "$@" ;;
    scan)
      shift
      local -a scan_args=()
      while (( $# > 0 )); do
        case "$1" in
          -*) tkoc_parse_safety_flag "$1" || _die "Unknown scan option: $1" ;;
          *) scan_args+=("$1") ;;
        esac
        shift
      done
      (( ${#scan_args[@]} <= 1 )) || _die "Usage: tkoc clamav scan [path] [--dry-run]"
      set -- "${scan_args[@]}"
      local target="${1:-$HOME/Downloads}"
      command -v clamscan >/dev/null 2>&1 || _die "clamscan not found. Run: tkoc clamav install"
      _header "Scanning $target"
      run_or_print clamscan -ri --bell -- "$target" ;;
    uninstall-daily)
      shift
      while (( $# > 0 )); do
        tkoc_parse_safety_flag "$1" || _die "Unknown uninstall-daily option: $1"
        shift
      done
      run_or_print systemctl --user disable --now tkoc-clamav.timer || true
      run_or_print rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/tkoc-clamav."{timer,service}
      run_or_print systemctl --user daemon-reload || true
      _ok "daily scan timer removed" ;;
    help|--help|-h)
      cat <<'HELP'
Usage:
  tkoc clamav install            Install ClamAV and refresh signatures
  tkoc clamav install --daily    Also enable a daily user-level scan timer
  tkoc clamav scan [path]        Scan a path (default: ~/Downloads)
  tkoc clamav uninstall-daily    Remove the daily timer

The daily timer runs as your own user over your Downloads, Desktop and
Documents. It is not a root scanner and does not crawl the whole filesystem.
HELP
      ;;
    *) _die "Unknown ClamAV subcommand: $sub. Run 'tkoc clamav help'." ;;
  esac
}

cmd_wg() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      _header "WireGuard status"
      local iface="${TKOC_WG_IFACE:-wg0}" pub="/etc/wireguard/${TKOC_WG_IFACE:-wg0}.pubkey"
      if [[ -f "$pub" ]]; then
        _ok "keypair exists for $iface"
        printf '  Public key: %s\n' "$(cat "$pub" 2>/dev/null || printf '(permission denied)')"
      else
        _warn_ "no keypair found. Run: tkoc install wireguard"
      fi
      if command -v wg >/dev/null 2>&1; then
        printf '\n'
        sudo -n wg show 2>/dev/null || printf '  no active tunnel, or no cached sudo access\n'
      fi ;;
    up|down)
      shift
      local iface="${TKOC_WG_IFACE:-wg0}"
      if [[ -n "${1:-}" && "$1" != -* ]]; then iface="$1"; shift; fi
      while (( $# > 0 )); do
        tkoc_parse_safety_flag "$1" || _die "Unknown WireGuard option: $1"
        shift
      done
      tkoc_valid_interface "$iface" || _die "Not a valid interface name: $iface"
      run_root systemctl "$([[ "$sub" == up ]] && printf start || printf stop)" "wg-quick@$iface" ;;
    help|--help|-h)
      printf 'Usage: tkoc wg [show|up|down] [interface] [--dry-run]\nInstall tools and keys with: tkoc install wireguard\n' ;;
    *) _die "Usage: tkoc wg [show|up|down]" ;;
  esac
}

cmd_vm()  { _tool vm-net "$@"; }
cmd_fs() {
  case "${1:-help}" in
    lock|downlock) shift; _tool downlock "$@" ;;
    lockdown)      shift; _tool lockdown "$@" ;;
    *)
      cat <<'HELP'
Usage:
  tkoc fs lock [path] [--list|--apply|--anywhere|--verbose]
  sudo "$(command -v tkoc)" fs lockdown [path] [--list|--apply|--include-dirs|--verbose]

Both report by default and only change modes with --apply.
HELP
      ;;
  esac
}

cmd_help() {
  cat <<'HELP'
tkoc -- the_king_of-casual unified CLI (Fedora edition, bash)

Usage:
  tkoc check                  Read-only pre-flight
  tkoc status                 What this machine looks like now
  tkoc doctor                 Filesystems, storage, drivers, firmware
  tkoc audit                  Full Trust No One posture audit
  tkoc harden <level>         Firewall + privacy together (basic|strong|lockdown)
  tkoc firewall               Show the live firewall posture
  tkoc firewall <tier>        Apply a tier (vanilla|strong|lockdown)
  tkoc firewall test          Live check: listeners, egress, reachability
  tkoc firewall learn|auto|watch   Per-network DNS and IPv6
  tkoc privacy <level>        Apply privacy hardening (basic|strong|lockdown)
  tkoc privacy list|status    Categories, and the current posture
  tkoc state list|show|restore|prune   Recovery snapshots
  tkoc update                 Report and apply repo/dnf/flatpak/firmware updates
  tkoc uninstall [--apply]    Undo everything written outside this checkout
  tkoc install <stage>        Run one stage on its own
  tkoc ice                    Install the optional customization packages
  tkoc dotfiles               Link the managed shell config into your home
  tkoc theme [name|list|set]  Apply a KDE Plasma appearance profile
  tkoc clamav <subcommand>    ClamAV install/scan (see: tkoc clamav help)
  tkoc wg [show|up|down]      WireGuard keypair and tunnel state
  tkoc install wireguard      Install WireGuard and generate a keypair
  tkoc vm net on|off|status   Guest network passthrough in the firewall
  tkoc uav [PORT|show|detect] Port and reachability analysis
  tkoc fs lock [path]         Tighten file permissions you own
  sudo "$(command -v tkoc)" fs lockdown   Same, for root-owned files
  tkoc pgp <subcommand>       Encrypt/decrypt with GnuPG
  tkoc link <source> [name]   Symlink an executable onto PATH
  tkoc killall                Close every open graphical app
  tkoc help                   This message

Stages:
  base  hardening  wireguard  antivirus  privacy  ricing  postcheck

Hardening profiles:
  basic     privacy basic,    firewall vanilla,  IPv6 enabled
  strong    privacy strong,   firewall strong,   IPv6 disabled (default)
  lockdown  privacy lockdown, firewall lockdown, IPv6 disabled

Firewall tiers:
  vanilla   Default-deny inbound and forwarded; permissive egress
  strong    + LAN discovery dropped, IPv6 off, sysctl hardening
  lockdown  + DNS pinned to one resolver, DNS-over-TLS/QUIC dropped

SSH carve-out:
  --ssh keeps sshd reachable and adds one scoped nftables accept for TCP/22,
  from the current LAN /24 unless --ssh-source or --ssh=<source> says otherwise.

Notes:
  - firewalld is disabled and masked when you apply a tier; it also manages
    nftables, and the two cannot both own the ruleset. It asks first, and
    `tkoc state restore` puts it back.
  - nothing runs on its own. Every change is a command you type, and --dry-run
    works on all of them.
  - SELinux is never flipped for you; the audit reports its mode.
  - ClamAV and WireGuard are opt-in and install nothing by default.

Install / uninstall (from this directory):
  make              link tkoc into ~/.local/bin
  make root-tools   install root-owned copies of the privileged tools
  make check        verify the link resolves, runs, and is not stale
  make uninstall    remove the symlink
  make purge        remove tkoc from this machine
HELP
}

# ── Dispatch ────────────────────────────────────────────────────

cmd="${1:-help}"
(( $# > 0 )) && shift

case "$cmd" in
  check)          cmd_check "$@" ;;
  status)         cmd_status "$@" ;;
  doctor)         cmd_doctor "$@" ;;
  audit)          cmd_audit "$@" ;;
  firewall)       cmd_firewall "$@" ;;
  harden)         cmd_harden "$@" ;;
  privacy)        cmd_privacy "$@" ;;
  state)          cmd_state "$@" ;;
  update)         cmd_update "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  install)        cmd_install "$@" ;;
  ice)            cmd_ice "$@" ;;
  dotfiles)       cmd_dotfiles "$@" ;;
  theme)          cmd_theme "$@" ;;
  clamav)         cmd_clamav "$@" ;;
  # `wg` is the status command; the full word `wireguard` is the stage, the
  # same way `base` and `hardening` name stages. These must not share an arm:
  # whichever came first silently swallowed the other.
  wg)             cmd_wg "$@" ;;
  vm)             cmd_vm "$@" ;;
  uav)            cmd_uav "$@" ;;
  fs)             cmd_fs "$@" ;;
  downlock)       _tool downlock "$@" ;;
  lockdown)       _tool lockdown "$@" ;;
  pgp)            cmd_pgp "$@" ;;
  link)           cmd_link "$@" ;;
  killall)        cmd_killall "$@" ;;

  # Deprecated aliases. The Arch edition's vocabulary still works, with a
  # warning naming the replacement, so muscle memory is not punished silently.
  backups)        _deprecated backups "state list"; cmd_state list "$@" ;;
  rollback)       _deprecated rollback "state restore"; cmd_state restore "${1:-latest}" "${@:2}" ;;
  apply)          _deprecated apply "firewall <tier>"; cmd_firewall "${TKOC_FW_LEVEL:-strong}" "$@" ;;
  gut)            _deprecated gut "privacy lockdown --categories remote-access"
                  cmd_privacy --categories remote-access "$@" ;;
  snapshot|snapshots) _deprecated "$cmd" state; cmd_state "$@" ;;
  av)             _deprecated av clamav; cmd_clamav "$@" ;;
  gpg)            _deprecated gpg pgp; cmd_pgp "$@" ;;
  linker)         _deprecated linker link; cmd_link "$@" ;;
  filesystem)     _deprecated filesystem fs; cmd_fs "$@" ;;
  network|port)   _deprecated "$cmd" uav; cmd_uav "$@" ;;

  base|hardening|wireguard|antivirus|ricing|postcheck)
                  cmd_install "$cmd" "$@" ;;
  help|--help|-h) cmd_help ;;
  *) _die "Unknown command: $cmd. Run 'tkoc help'." ;;
esac
