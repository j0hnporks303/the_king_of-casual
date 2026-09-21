#!/usr/bin/env bash
# =============================================================================
#  the_king_of-casual (Fedora edition) — common library
# =============================================================================
# Ported from the_king_of_maCasual/stages/lib/common.zsh. Fedora ships bash as
# the login shell and bash is always present on a minimal install, so nothing
# here needs a zsh dependency.

[[ -n "${TKOC_COMMON_LIB_LOADED:-}" ]] && return 0
TKOC_COMMON_LIB_LOADED=1
readonly TKOC_COMMON_LIB_LOADED

# Fedora releases this code is exercised against. Older/newer releases still
# work with --allow-unsupported after the operator has read the commands.
readonly TKOC_SUPPORTED_FEDORA_MIN=40

# ────────────────────────────────────────────────────────────────
# LOGGING
# ────────────────────────────────────────────────────────────────

log()  { printf '[tkoc] %s\n' "$*"; }
warn() { printf '[tkoc][warn] %s\n' "$*" >&2; }
die()  { printf '[tkoc][error] %s\n' "$*" >&2; exit 1; }

# ────────────────────────────────────────────────────────────────
# TERMINAL INTERACTION
# ────────────────────────────────────────────────────────────────
# These read the controlling terminal directly rather than stdin, so prompts
# still work under `curl ... | bash` where stdin is the piped script itself.

# -r/-w on /dev/tty can succeed even when it cannot be opened: with no
# controlling terminal (CI, pipes, nohup) the open fails with ENXIO
# ("no such device or address"). So actually try to open it for read+write.
tkoc_have_tty() { ( exec </dev/tty >/dev/tty ) 2>/dev/null; }

# Print a prompt to the terminal and echo back the user's line. Empty on no-tty.
tkoc_prompt() {
  local reply=""
  if tkoc_have_tty; then
    printf '%s' "$1" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
  fi
  printf '%s' "$reply"
}

tkoc_tty_say() { tkoc_have_tty && printf '%s\n' "$*" > /dev/tty || true; }

# Ask until the answer is one of the accepted choices. Returns the choice, or
# the default when there is no terminal to ask.
# Usage: tkoc_choose <default> <prompt> <choice> [choice ...]
tkoc_choose() {
  local fallback="$1" prompt="$2"; shift 2
  local -a choices=( "$@" )
  local answer choice
  tkoc_have_tty || { printf '%s' "$fallback"; return 0; }
  while true; do
    answer="$(tkoc_prompt "$prompt")"
    [[ -n "$answer" ]] || { printf '%s' "$fallback"; return 0; }
    for choice in "${choices[@]}"; do
      [[ "$answer" == "$choice" ]] && { printf '%s' "$answer"; return 0; }
    done
    tkoc_tty_say "Please answer one of: ${choices[*]}"
  done
}

# ────────────────────────────────────────────────────────────────
# GUARDS
# ────────────────────────────────────────────────────────────────

need_not_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Do NOT run as root/sudo. This command operates on your own account."
  fi
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "This command must run as root."
  fi
}

need_linux() { [[ "$(uname -s)" == Linux ]] || die "This repo targets Fedora Linux only."; }

tkoc_os_release() {
  local key="$1" file="${TKOC_TEST_ROOT:-}/etc/os-release" value
  [[ -r "$file" ]] || return 1
  value="$(awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file")"
  value="${value%\"}"; value="${value#\"}"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

is_fedora() {
  local id id_like
  id="$(tkoc_os_release ID || true)"
  id_like="$(tkoc_os_release ID_LIKE || true)"
  [[ "$id" == fedora ]] && return 0
  [[ " $id_like " == *" fedora "* ]]
}

need_fedora() {
  [[ -n "${TKOC_TEST_ROOT:-}" ]] && return 0
  need_linux
  is_fedora || die "This repo targets Fedora. /etc/os-release reports: $(tkoc_os_release PRETTY_NAME || printf unknown)"
}

need_supported_fedora() {
  need_fedora
  [[ -n "${TKOC_TEST_ROOT:-}" ]] && return 0
  local version="${1:-}"
  version="$(tkoc_os_release VERSION_ID || printf 0)"
  version="${version%%.*}"
  [[ "$version" =~ ^[0-9]+$ ]] && (( version >= TKOC_SUPPORTED_FEDORA_MIN )) && return 0
  tkoc_bool_enabled TKOC_ALLOW_UNSUPPORTED disabled && {
    warn "Unsupported Fedora ${version:-unknown}; continuing because --allow-unsupported was supplied."
    return 0
  }
  die "TKOC mutating commands support Fedora ${TKOC_SUPPORTED_FEDORA_MIN}+. Found ${version:-unknown}. Use --allow-unsupported only after reviewing the commands."
}

need_nft() {
  [[ -n "${TKOC_TEST_ROOT:-}" ]] && return 0
  command -v nft >/dev/null 2>&1 \
    || die "nft is required. Install it with: sudo dnf install nftables"
}

need_dnf() {
  [[ -n "${TKOC_TEST_ROOT:-}" ]] && return 0
  command -v dnf >/dev/null 2>&1 || die "dnf is required and was not found."
}

# `dnf5` (Fedora 41+) and `dnf-3` differ enough in output that callers which
# parse anything must know which one they got.
tkoc_dnf_major() {
  local version
  version="$(dnf --version 2>/dev/null | head -1 || true)"
  case "$version" in
    5.*) printf '5' ;;
    4.*) printf '4' ;;
    *)   printf 'unknown' ;;
  esac
}

rpm_installed() { rpm -q -- "$1" >/dev/null 2>&1; }

# ────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ────────────────────────────────────────────────────────────────

tkoc_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# bash 4's ${x,,} is unavailable on the bash 3.2 that macOS still ships, and the
# structural test suite is meant to run on the development machine as well as on
# Fedora. tr is in coreutils and present on both.
tkoc_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim_line() {
  local s="$1"
  s="${s%%#*}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

tkoc_bool_value() {
  local name="$1" default="${2:-disabled}" value
  value="${!name:-}"
  [[ -n "$value" ]] || value="$default"
  value="$(tkoc_lower "$value")"

  case "$value" in
    enabled|enable|yes|y|true|on|1) printf 'enabled' ;;
    disabled|disable|no|n|false|off|0) printf 'disabled' ;;
    *) die "$name must be set to 'enabled' or 'disabled' (got '$value')." ;;
  esac
}

tkoc_bool_enabled() {
  local name="$1" default="${2:-disabled}" value
  # Deliberately not `[[ "$(tkoc_bool_value ...)" == enabled ]]`. Command
  # substitution runs in a subshell, so tkoc_bool_value's die() killed only that
  # subshell: the error was printed, the substitution came back empty, and this
  # function quietly returned "not enabled". Every invalid value therefore fell
  # through to the *disabled* branch of its caller — and for TKOC_DRY_RUN that
  # meant a typo such as TKOC_DRY_RUN=ture silently turned a preview into a real
  # run. Propagate the failure instead so bad configuration stops the program.
  value="$(tkoc_bool_value "$name" "$default")" || exit 1
  [[ "$value" == "enabled" ]]
}

tkoc_parse_safety_flag() {
  case "$1" in
    --dry-run|-n) TKOC_DRY_RUN=enabled ;;
    --yes|-y) TKOC_UPDATE_YES=enabled ;;
    --allow-unsupported) TKOC_ALLOW_UNSUPPORTED=enabled ;;
    *) return 1 ;;
  esac
  export TKOC_DRY_RUN TKOC_UPDATE_YES TKOC_ALLOW_UNSUPPORTED
}

# The SSH carve-out vocabulary, in one place.
#
# Call as: tkoc_parse_ssh_flag "$@"
# Returns 0 when "$1" was an SSH flag, 1 otherwise. Because --ssh-source takes a
# separate argument, the number of arguments consumed is reported in
# TKOC_FLAG_SHIFT so callers can `shift "$TKOC_FLAG_SHIFT"`.
tkoc_parse_ssh_flag() {
  TKOC_FLAG_SHIFT=1
  case "$1" in
    --ssh)
      TKOC_ALLOW_SSH=enabled
      ;;
    --ssh=*)
      TKOC_ALLOW_SSH=enabled
      TKOC_SSH_SOURCE="${1#--ssh=}"
      [[ -n "$TKOC_SSH_SOURCE" ]] || die "--ssh=<source> requires a source IP or CIDR"
      ;;
    --ssh-source=*)
      TKOC_ALLOW_SSH=enabled
      TKOC_SSH_SOURCE="${1#--ssh-source=}"
      [[ -n "$TKOC_SSH_SOURCE" ]] || die "--ssh-source=<source> requires a source IP or CIDR"
      ;;
    --ssh-source)
      [[ $# -ge 2 ]] || die "--ssh-source requires a source IP or CIDR"
      TKOC_ALLOW_SSH=enabled
      TKOC_SSH_SOURCE="$2"
      TKOC_FLAG_SHIFT=2
      ;;
    --no-ssh)
      TKOC_ALLOW_SSH=disabled
      TKOC_SSH_SOURCE=""
      ;;
    *) return 1 ;;
  esac

  # Validate here so a malformed source is rejected at parse time by every
  # caller, instead of surviving until a stage tries to write an nftables rule.
  [[ -z "${TKOC_SSH_SOURCE:-}" ]] || tkoc_valid_ipv4_source "$TKOC_SSH_SOURCE" \
    || die "SSH source must be an IPv4 address or CIDR, for example 192.168.8.0/24"

  # Provenance token. TKOC_ALLOW_SSH alone cannot distinguish "the operator
  # typed --ssh" from "a variable happened to be exported in this shell", and
  # those must not carry the same authority. Only this parser sets the token,
  # so a stray environment variable can never forge explicit intent. It is
  # exported so a parent that saw a real flag (tkoc harden) can pass that fact
  # to the stages it invokes.
  TKOC_SSH_FROM_FLAG=enabled

  export TKOC_ALLOW_SSH TKOC_SSH_SOURCE TKOC_SSH_FROM_FLAG
}

# Remote access is treated as opt-in-by-explicit-intent only: the environment
# may make the posture safer, never more dangerous. At the lockdown tier an
# ambient TKOC_ALLOW_SSH is a hard error rather than a silent carve-out, because
# enabling SSH there also opens an inbound hole in a default-deny policy — so the
# same command line would produce a materially weaker machine with nothing on it
# to show why.
tkoc_guard_ambient_ssh() {
  local tier="${1:-strong}"

  tkoc_bool_enabled TKOC_ALLOW_SSH disabled || return 0
  tkoc_bool_enabled TKOC_SSH_FROM_FLAG disabled && return 0

  if [[ "$tier" == lockdown ]]; then
    die "Refusing to enable SSH at the lockdown tier from the environment.

  TKOC_ALLOW_SSH=${TKOC_ALLOW_SSH} is set in this environment, but no --ssh flag
  was given. Enabling SSH here would punch an inbound hole through a policy you
  asked to lock down, quietly weakening the run.

  To allow SSH, say so explicitly:
      tkoc firewall lockdown --ssh
      tkoc firewall lockdown --ssh-source <ip-or-cidr>
  To keep it off, clear the variable:
      unset TKOC_ALLOW_SSH"
  fi

  warn "SSH is being enabled by TKOC_ALLOW_SSH in the environment, not by a --ssh flag."
  warn "Run 'unset TKOC_ALLOW_SSH' to keep remote access off."
}

tkoc_confirm() {
  local prompt="$1"
  tkoc_bool_enabled TKOC_DRY_RUN disabled && return 0
  tkoc_bool_enabled TKOC_UPDATE_YES disabled && return 0
  [[ -t 0 ]] || die "Refusing a noninteractive change without --yes."
  printf '%s [y/N] ' "$prompt"
  local answer=""; read -r answer || true
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}

tkoc_valid_ipv4_source() {
  local input="$1" address mask="" component number
  local -a components
  address="${input%%/*}"
  if [[ "$input" == */* ]]; then
    mask="${input#*/}"
    # A trailing slash with no prefix length ("10.0.0.5/") is malformed.
    [[ -n "$mask" ]] || return 1
  fi
  IFS=. read -r -a components <<<"$address"
  (( ${#components[@]} == 4 )) || return 1
  for component in "${components[@]}"; do
    [[ "$component" =~ ^[0-9]{1,3}$ ]] || return 1
    number=$((10#$component))
    (( number >= 0 && number <= 255 )) || return 1
  done
  if [[ -n "$mask" ]]; then
    [[ "$mask" =~ ^[0-9]{1,2}$ ]] || return 1
    number=$((10#$mask))
    (( number >= 0 && number <= 32 )) || return 1
  fi
}

tkoc_valid_ipv4() { [[ "$1" != */* ]] && tkoc_valid_ipv4_source "$1"; }
tkoc_valid_interface() { [[ "$1" =~ ^[A-Za-z0-9_.@-]+$ ]]; }
tkoc_valid_absolute_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

# Reduce a git remote URL to a comparable host/owner/repo identity, so the same
# repository reached over SSH and over HTTPS compares equal.
#
#   git@github.com:owner/repo.git       -> github.com/owner/repo
#   https://github.com/owner/repo.git   -> github.com/owner/repo
tkoc_git_remote_identity() {
  local url="${1:-}"
  [[ -n "$url" ]] || { printf ''; return 0; }
  url="${url%/}"
  url="${url%.git}"
  url="${url#git+ssh://}"
  url="${url#ssh://}"
  url="${url#https://}"
  url="${url#http://}"
  url="${url#git://}"
  url="${url#*@}"                       # drop any user[:password]@ prefix
  if [[ "$url" == *:* ]]; then          # scp-style host:path, or an explicit port
    local host="${url%%:*}" rest="${url#*:}"
    [[ "$rest" =~ ^[0-9]+/ ]] && rest="${rest#*/}"
    url="$host/$rest"
  fi
  printf '%s' "$(tkoc_lower "$url")"
}

tkoc_same_git_remote() {
  local left right
  left="$(tkoc_git_remote_identity "${1:-}")"
  right="$(tkoc_git_remote_identity "${2:-}")"
  [[ -n "$left" && "$left" == "$right" ]]
}

read_package_file() {
  local file="$1" line
  [[ -f "$file" ]] || die "Package list missing: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_line "$line")"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$file"
}

# ────────────────────────────────────────────────────────────────
# REMOTE ACCESS SURFACE
# ────────────────────────────────────────────────────────────────
#
# The canonical lists of packages and units that let something reach this
# machine from elsewhere. The privacy remote-access category, `tkoc gut`, and
# the audit all read these, so detection and removal cannot drift apart.
#
# Fedora names, not Arch names: `tigervnc-server`, `zerotier-one` from their
# own repo, `cockpit` (Fedora Server/Workstation ships the socket), and
# `sshd.socket` (socket activation is how Fedora starts sshd).
tkoc_remote_access_packages() {
  printf '%s\n' \
    teamviewer anydesk rustdesk tailscale zerotier-one \
    tigervnc-server x11vnc wayvnc realvnc-vnc-server \
    cockpit cockpit-ws
}

tkoc_remote_access_units() {
  printf '%s\n' \
    teamviewerd.service anydesk.service rustdesk.service \
    tailscaled.service zerotier-one.service \
    vncserver.service x11vnc.service wayvnc.service \
    'vncserver@.service' xrdp.service \
    cockpit.socket cockpit.service \
    sshd.service sshd.socket
}

# ────────────────────────────────────────────────────────────────
# OPTION DOCUMENTATION
# ────────────────────────────────────────────────────────────────
#
# The option text lives here because each stage's usage() and the matching
# `tkoc <cmd> --help` are otherwise separate hand-written copies that drift.
# Both callers print from this one source.

# "$1" = full (default), or toggle-only for stages that write no firewall rules
# and therefore cannot honour a source CIDR.
tkoc_print_ssh_options() {
  # --no-ssh is accepted but not listed: remote access is off at every tier
  # unless --ssh is typed, so the flag only ever restates the default.
  if [[ "${1:-full}" == toggle-only ]]; then
    cat <<'HELP'
  --ssh                             Keep sshd/Remote Login on (off by default)
HELP
  else
    cat <<'HELP'
  --ssh[=<source-ip-or-cidr>]       Keep sshd on, scoped by an nftables allow
  --ssh-source <source-ip-or-cidr>  Same, with an explicit source
HELP
  fi
}

# The one paragraph that says what the lockdown tier guarantees. Printed by both
# `tkoc firewall --help` and `tkoc privacy --help` so the promise is stated once.
tkoc_print_lockdown_note() {
  cat <<'HELP'
Lockdown locks down remote access. sshd, Cockpit, VNC/RDP, file sharing
(Samba/NFS/rpcbind), Avahi/mDNS discovery, cups-browsed and Bluetooth are all
turned off, inbound is default-deny, and DNS is pinned to one resolver with
DoT/DoQ dropped. That is the tier, not a set of defaults: --block-all and
--no-ssh do not apply here. The only way through is one explicit, scoped
exception:  --ssh-source <ip-or-cidr>
HELP
}

tkoc_print_safety_options() {
  cat <<'HELP'
  --dry-run, -n                     Preview; makes no writes and no sudo calls
  --yes, -y                         Confirm noninteractive application
  --allow-unsupported               Permit reviewed use outside supported Fedora
HELP
}

tkoc_print_firewall_options() {
  cat <<'HELP'
  --ipv6 enabled|disabled           IPv6 posture, firewall and kernel together
  --ipv6-enabled, --ipv6-disabled   Shorthand for the above
  --interface <name>                Override the detected external interface
  --dns <resolver-ip>               Pin DNS to ONLY this resolver (forced at lockdown)
  --no-dns                          Do not pin DNS (ignored at lockdown)
  --keep-firewalld                  Do not disable/mask firewalld (see below)
  --wireguard                       Accept inbound WireGuard on UDP/51820
HELP
  tkoc_print_ssh_options full
  tkoc_print_safety_options
}

tkoc_print_privacy_options() {
  cat <<'HELP'
  --categories <a,b,c>              Run only the named privacy categories
  --list-categories                 List every category with its level
HELP
  tkoc_print_ssh_options toggle-only
  tkoc_print_safety_options
}

# ────────────────────────────────────────────────────────────────
# DRY-RUN / EXECUTION WRAPPER
# ────────────────────────────────────────────────────────────────

run_or_print() {
  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    printf '[tkoc][dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# Run as root, but only through sudo when we are not already root. Every
# privileged call in this repo goes through here so --dry-run covers them all.
#
# TKOC_TEST_ROOT is a user-owned sandbox by construction, so escalating inside
# one is both unnecessary and hostile: it turns `./tests/test-tkoc.sh` into a
# password prompt, and in CI into a hang.
run_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 || -n "${TKOC_TEST_ROOT:-}" ]]; then
    run_or_print "$@"
  else
    run_or_print sudo "$@"
  fi
}

# Same, but decided by the target path rather than assumed. Writing to a file
# the invoking user already owns does not need root, and asking for it anyway
# trains people to type a password for operations that never required one.
run_root_path() {
  local target="$1"; shift
  if [[ ${EUID:-$(id -u)} -eq 0 || -n "${TKOC_TEST_ROOT:-}" ]]; then
    run_or_print "$@"
  elif [[ -w "$target" ]] || { [[ ! -e "$target" ]] && [[ -w "$(dirname -- "$target")" ]]; }; then
    run_or_print "$@"
  else
    run_or_print sudo "$@"
  fi
}

# ────────────────────────────────────────────────────────────────
# DNF INSTALL — no empty-arg bugs
# ────────────────────────────────────────────────────────────────

dnf_install() {
  local -a wanted=( "$@" ) missing=()
  local pkg
  (( ${#wanted[@]} > 0 )) || return 0
  for pkg in "${wanted[@]}"; do
    rpm_installed "$pkg" || missing+=( "$pkg" )
  done
  if (( ${#missing[@]} == 0 )); then
    log "already installed: ${wanted[*]}"
    return 0
  fi
  log "dnf install ${missing[*]}"
  if ! run_root dnf install -y "${missing[@]}"; then
    tkoc_bool_enabled TKOC_KEEP_GOING disabled && { warn "Package install failed: ${missing[*]}"; return 0; }
    die "Package install failed: ${missing[*]}"
  fi
}

install_package_file() {
  local file="$1" line
  local -a packages=()
  log "Package list: $file"
  while IFS= read -r line; do
    packages+=( "$line" )
  done < <(read_package_file "$file")
  (( ${#packages[@]} > 0 )) || { log "nothing to install"; return 0; }
  dnf_install "${packages[@]}"
}

show_package_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Package list missing: $file"
  read_package_file "$file" | sed 's/^/  - /'
}

# ────────────────────────────────────────────────────────────────
# FILE INSTALL HELPERS
# ────────────────────────────────────────────────────────────────

_tkoc_lib_dir() { printf '%s' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; }

copy_file_root() {
  local source="$1" target="$2" mode="${3:-0644}"
  if [[ -n "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
    # shellcheck source=/dev/null
    source "$(_tkoc_lib_dir)/state.sh"
    tkoc_state_capture_file "$target"
  fi
  run_root_path "$target" mkdir -p -- "$(dirname -- "$target")"
  run_root_path "$target" install -m "$mode" -- "$source" "$target"
  log "Installed $target"
}

copy_file() {
  local source="$1" target="$2" mode="${3:-0644}"
  if [[ -n "${TKOC_ACTIVE_SNAPSHOT:-}" ]]; then
    # shellcheck source=/dev/null
    source "$(_tkoc_lib_dir)/state.sh"
    tkoc_state_capture_file "$target"
  fi
  run_or_print mkdir -p -- "$(dirname -- "$target")"
  run_or_print install -m "$mode" -- "$source" "$target"
  log "Installed $target"
}

# ────────────────────────────────────────────────────────────────
# SYSTEMD HELPERS
# ────────────────────────────────────────────────────────────────
# Each of these snapshots the unit's prior state first when a transaction is
# open, so `tkoc state restore` can put it back exactly as it was.

_tkoc_snapshot_unit() {
  [[ -n "${TKOC_ACTIVE_SNAPSHOT:-}" ]] || return 0
  # shellcheck source=/dev/null
  source "$(_tkoc_lib_dir)/state.sh"
  tkoc_state_capture_systemd "$1"
}

unit_exists() {
  systemctl list-unit-files -- "$1" --no-legend 2>/dev/null | grep -q .
}

unit_enabled() { systemctl is-enabled --quiet -- "$1" 2>/dev/null; }
unit_active()  { systemctl is-active --quiet -- "$1" 2>/dev/null; }

# Disabling a unit that is not installed is a no-op, not an error: a Fedora
# install without Samba should not fail the network-services category.
systemd_disable() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    log "skipped $unit: not installed on this system"
    return 0
  fi
  _tkoc_snapshot_unit "$unit"
  run_root systemctl disable --now -- "$unit" || warn "systemctl disable failed: $unit"
  log "Disabled: $unit"
}

systemd_mask() {
  local unit="$1"
  unit_exists "$unit" || { log "skipped $unit: not installed on this system"; return 0; }
  _tkoc_snapshot_unit "$unit"
  run_root systemctl mask --now -- "$unit" || warn "systemctl mask failed: $unit"
  log "Masked: $unit"
}

systemd_enable() {
  local unit="$1"
  unit_exists "$unit" || { warn "cannot enable $unit: not installed"; return 0; }
  _tkoc_snapshot_unit "$unit"
  run_root systemctl enable --now -- "$unit" || warn "systemctl enable failed: $unit"
  log "Enabled: $unit"
}

selinux_enforcing() {
  command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]
}

# ────────────────────────────────────────────────────────────────
# TIER MARKER RENDERING
# ────────────────────────────────────────────────────────────────
#
# config/firewall/tkoc.nft and config/sysctl.d/60-tkoc-hardening.conf are one
# template each, not one file per tier. A line of the form
#
#     # TKOC_NAME: <real content>
#
# is an inert comment until NAME is listed as enabled, at which point the
# "# TKOC_NAME: " prefix is stripped and the content becomes live. Any marker
# not enabled stays a comment, so the rendered file still documents the full
# policy surface including the parts this tier left off.
#
# Usage: tkoc_render_markers <source> <target> <marker> [marker ...]
tkoc_render_markers() {
  local source="$1" target="$2"; shift 2
  local enabled=""
  local marker
  [[ -r "$source" ]] || die "missing template: $source"
  for marker in "$@"; do
    [[ "$marker" =~ ^TKOC_[A-Z0-9_]+$ ]] || die "invalid marker name: $marker"
    enabled+="${marker} "
  done
  awk -v enabled=" $enabled" '
    /^[[:space:]]*# TKOC_[A-Z0-9_]+:/ {
      line = $0
      name = line
      sub(/^[[:space:]]*# /, "", name)
      sub(/:.*$/, "", name)
      if (index(enabled, " " name " ") > 0) {
        sub(/^[[:space:]]*# [A-Z0-9_]+:[[:space:]]?/, "", line)
        print line
        next
      }
      print
      next
    }
    { print }
  ' "$source" > "$target" || die "could not render $source"
}

# Replace a `define NAME = { ... }` line in a rendered nftables file. Kept
# separate from marker rendering because the value comes from a flag, not a
# tier, and because a missing define must be a hard error rather than a
# silently unconfigured firewall.
tkoc_render_define() {
  local file="$1" name="$2" value="$3" tmp
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid define name: $name"
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-define.XXXXXX")"
  awk -v name="$name" -v value="$value" '
    $0 ~ "^define[[:space:]]+" name "[[:space:]]*=" {
      printf "define %s = { %s }\n", name, value
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) exit 1 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "could not configure $name in $file"; }
  mv "$tmp" "$file"
}

# Validate a rendered nftables file. `nft --check` is the real validator; where
# it is unavailable (a non-Linux development machine) say so plainly rather
# than reporting a pass nothing actually checked.
tkoc_validate_nft() {
  local file="$1"
  [[ -r "$file" ]] || die "missing nftables policy: $file"
  grep -Fq 'table inet tkoc_host' "$file" || die "nftables policy does not define tkoc_host"
  grep -Fq 'chain input' "$file" || die "nftables policy has no input chain"
  grep -Fq 'chain forward' "$file" || die "nftables policy has no forward chain"
  grep -Fq 'chain output' "$file" || die "nftables policy has no output chain"
  grep -Fq 'policy drop;' "$file" || die "nftables policy has no default-drop chain"

  if command -v nft >/dev/null 2>&1; then
    nft --check --file "$file" || die "nftables policy failed native validation"
    log "nftables syntax: valid"
  else
    log "nftables syntax: native check skipped (nft unavailable in this environment)"
  fi
}

tkoc_validate_sysctl() {
  local file="$1"
  [[ -r "$file" ]] || die "missing sysctl policy: $file"
  awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*[A-Za-z0-9_.*-]+[[:space:]]*=[[:space:]]*[^[:space:]].*$/ { next }
    { printf "%s:%d: invalid sysctl assignment\n", FILENAME, FNR > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || die "sysctl policy failed structural validation"
}
