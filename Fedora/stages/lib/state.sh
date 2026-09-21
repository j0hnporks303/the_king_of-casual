#!/usr/bin/env bash
# Versioned, local recovery snapshots for TKOC-managed state.
#
# Ported from the_king_of_maCasual/stages/lib/state.zsh. The transaction model,
# the manifest format, and the safety gates in tkoc_state_restore are unchanged;
# the capture kinds are Fedora's (systemd, nmcli, kconfig, nftables, firewalld)
# instead of macOS's (launchd, networksetup, defaults, pf, socketfilterfw).

[[ -n "${TKOC_STATE_LIB_LOADED:-}" ]] && return 0
TKOC_STATE_LIB_LOADED=1

# Schema 2, not 1. This edition uses the same $XDG_STATE_HOME/tkoc/snapshots
# path as the macOS edition (the_king_of_maCasual) -- which is right, because
# "tkoc state" should mean one thing -- but the capture kinds are different
# (systemd/nmcli/kconfig/nftables rather than launchd/networksetup/defaults/pf).
# A schema bump makes a snapshot from the other edition fail cleanly as
# "unsupported schema" instead of being walked with the wrong restorers.
TKOC_STATE_SCHEMA=2
TKOC_STATE_HOME="${TKOC_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/tkoc}"
TKOC_SNAPSHOT_ROOT="${TKOC_STATE_HOME}/snapshots"
TKOC_ACTIVE_SNAPSHOT="${TKOC_ACTIVE_SNAPSHOT:-}"

# GNU base64 wraps at 76 columns by default; the manifest is one record per
# line, so wrapping would corrupt every field.
tkoc_b64_encode() { printf '%s' "$1" | base64 -w0; }
tkoc_b64_decode() { printf '%s' "$1" | base64 -d; }

tkoc_host_id() {
  local id=""
  [[ -r /etc/machine-id ]] && id="$(< /etc/machine-id)"
  [[ -n "$id" ]] || id="$(hostname 2>/dev/null || printf unknown)"
  printf '%s' "$id"
}

# Whether this operation needs root is decided by what we can actually do to
# the path, not by how the path is spelled. Classifying by prefix looked right
# -- /etc, /usr, /var are system directories -- but it is wrong in both
# directions: it escalates for a file under /var/tmp that the invoking user owns
# outright, and it would not escalate for a root-owned file somewhere else.
# Asking the filesystem is both more accurate and quieter: no password prompt
# appears for work that never needed one.
tkoc_state_needs_root() {
  local target_path="$1" mode="${2:-write}"
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return 1
  [[ -n "${TKOC_TEST_ROOT:-}" ]] && return 1
  case "$mode" in
    read)
      [[ -r "$target_path" ]] && return 1
      ;;
    write)
      if [[ -e "$target_path" || -L "$target_path" ]]; then
        [[ -w "$target_path" ]] && return 1
      else
        [[ -w "$(_tkoc_dirname "$target_path")" ]] && return 1
      fi
      ;;
  esac
  return 0
}

# tkoc_state_run_path <path> [--read] <command...>
tkoc_state_run_path() {
  local target_path="$1"; shift
  local mode=write
  if [[ "${1:-}" == --read ]]; then mode=read; shift; fi
  if tkoc_state_needs_root "$target_path" "$mode"; then
    sudo "$@"
  else
    "$@"
  fi
}

# stat(1) is not portable: coreutils takes -c '%a', BSD takes -f '%Lp'. Fedora
# is the target, but this library is also exercised by the test suite on a
# macOS development machine, and a capture that silently recorded "-" for every
# mode would make a later restore write the wrong permissions.
tkoc_stat() {
  local what="$1" target="$2"
  case "$what" in
    mode) stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null ;;
    uid)  stat -c '%u' "$target" 2>/dev/null || stat -f '%u'  "$target" 2>/dev/null ;;
    gid)  stat -c '%g' "$target" 2>/dev/null || stat -f '%g'  "$target" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# Dirname that does not collapse to "." for a bare name and does not lose the
# root slash. zsh's ${x:h} handled both; bash's ${x%/*} does not.
_tkoc_dirname() {
  local p="${1%/}"
  case "$p" in
    */*) printf '%s' "${p%/*}" ;;
    *)   printf '.' ;;
  esac
}
_tkoc_basename() { local p="${1%/}"; printf '%s' "${p##*/}"; }

tkoc_state_begin() {
  local command="$1"; shift || true
  [[ -z "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  umask 077
  mkdir -p "$TKOC_SNAPSHOT_ROOT" || return 1
  chmod 700 "$TKOC_STATE_HOME" "$TKOC_SNAPSHOT_ROOT" 2>/dev/null || true

  local stamp id tmp final temp_name arguments
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  tmp="$(mktemp -d "${TKOC_SNAPSHOT_ROOT}/.${stamp}-$$.XXXXXX")" || return 1
  temp_name="$(_tkoc_basename "$tmp")"
  id="${temp_name#.}"
  final="${TKOC_SNAPSHOT_ROOT}/${id}"
  chmod 700 "$tmp" || return 1
  mkdir -m 700 "$tmp/blobs" || return 1
  : > "$tmp/manifest.tsv"
  # printf '%q ' with no arguments still emits "'' ", which would record a
  # phantom empty argument for every command invoked without flags.
  arguments=""
  (( $# )) && arguments="$(printf '%q ' "$@")"
  {
    printf 'schema=%s\n' "$TKOC_STATE_SCHEMA"
    printf 'id=%s\n' "$id"
    printf 'status=capturing\n'
    printf 'command_b64=%s\n' "$(tkoc_b64_encode "$command")"
    printf 'arguments_b64=%s\n' "$(tkoc_b64_encode "${arguments% }")"
    printf 'created_utc=%s\n' "$stamp"
    printf 'uid=%s\n' "${EUID:-$(id -u)}"
    printf 'host_b64=%s\n' "$(tkoc_b64_encode "$(tkoc_host_id)")"
    printf 'os=%s\n' "$(tkoc_os_release PRETTY_NAME 2>/dev/null || printf unknown)"
    printf 'kernel=%s\n' "$(uname -r 2>/dev/null || printf unknown)"
  } > "$tmp/meta"
  mv "$tmp" "$final" || return 1
  TKOC_ACTIVE_SNAPSHOT="$final"
  export TKOC_ACTIVE_SNAPSHOT
  tkoc_state_set_status capturing
  printf '%s\n' "$final"
}

tkoc_state_set_status() {
  local state_value="$1" meta="${TKOC_ACTIVE_SNAPSHOT}/meta" tmp
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" && -f "$meta" ]] || return 0
  tmp="${meta}.tmp.$$"
  awk -v state_value="$state_value" 'BEGIN{done=0} /^status=/{print "status=" state_value; done=1; next} {print} END{if(!done) print "status=" state_value}' \
    "$meta" > "$tmp" && mv "$tmp" "$meta"
}

tkoc_state_finish() {
  tkoc_state_set_status complete
  TKOC_ACTIVE_SNAPSHOT=""
  export TKOC_ACTIVE_SNAPSHOT
}
tkoc_state_fail() { tkoc_state_set_status failed; }

tkoc_state_manifest_append() {
  local format="$1" manifest="${TKOC_ACTIVE_SNAPSHOT}/manifest.tsv" tmp
  shift
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" && -f "$manifest" ]] || return 0
  tmp="${manifest}.tmp.$$"
  cp "$manifest" "$tmp" || return 1
  # shellcheck disable=SC2059
  printf "$format" "$@" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$manifest"
}

# A transaction records the first observed value of a managed key. Capturing
# the same key again after an earlier mutation would otherwise make rollback
# restore an intermediate value instead of the pre-transaction value.
tkoc_state_manifest_has() {
  local kind="$1" first="$2" second="${3:-}" third="${4:-}"
  local manifest="${TKOC_ACTIVE_SNAPSHOT}/manifest.tsv"
  [[ -f "$manifest" ]] || return 1
  awk -F '\t' -v kind="$kind" -v first="$first" -v second="$second" -v third="$third" '
    $1 == kind && $2 == first &&
      (second == "" || $3 == second) &&
      (third == "" || $4 == third) { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$manifest"
}

tkoc_state_valid_target() {
  local target_path="$1"
  [[ "$target_path" == /* && "$target_path" != / ]] || return 1
  [[ "$target_path" != *$'\n'* && "$target_path" != *$'\r'* ]] || return 1
  [[ "/${target_path#/}/" != */../* && "/${target_path#/}/" != */./* ]] || return 1
}

tkoc_state_capture_file() {
  local target_path="$1"
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  tkoc_state_valid_target "$target_path" || return 1
  local key encoded kind=missing mode=- uid=- gid=- link=- blob=- parent
  encoded="$(tkoc_b64_encode "$target_path")"
  tkoc_state_manifest_has file "$encoded" && return 0
  key="$(printf '%s' "$target_path" | sha256sum | awk '{print $1}')"
  parent="$(_tkoc_dirname "$target_path")"
  if [[ -L "$target_path" ]]; then
    kind=symlink
    link="$(tkoc_b64_encode "$(readlink "$target_path")")"
    mode="$(tkoc_stat mode "$target_path" || printf -- -)"
    uid="$(tkoc_stat uid "$target_path" || printf -- -)"
    gid="$(tkoc_stat gid "$target_path" || printf -- -)"
  elif [[ -f "$target_path" ]]; then
    kind=file; blob="blobs/${key}.file"
    tkoc_state_run_path "$target_path" --read cp -p "$target_path" "$TKOC_ACTIVE_SNAPSHOT/$blob" || return 1
    if tkoc_state_needs_root "$target_path" read; then
      sudo chown "${EUID:-$(id -u)}" "$TKOC_ACTIVE_SNAPSHOT/$blob" || return 1
    fi
    chmod 600 "$TKOC_ACTIVE_SNAPSHOT/$blob" 2>/dev/null || true
    mode="$(tkoc_stat mode "$target_path")"; uid="$(tkoc_stat uid "$target_path")"; gid="$(tkoc_stat gid "$target_path")"
  elif [[ -d "$target_path" ]]; then
    kind=directory; blob="blobs/${key}.tar"
    if tkoc_state_needs_root "$target_path" read; then
      sudo tar -cf "$TKOC_ACTIVE_SNAPSHOT/$blob" -C "$parent" "$(_tkoc_basename "$target_path")" || return 1
      sudo chown "${EUID:-$(id -u)}" "$TKOC_ACTIVE_SNAPSHOT/$blob" || return 1
    else
      tar -cf "$TKOC_ACTIVE_SNAPSHOT/$blob" -C "$parent" "$(_tkoc_basename "$target_path")" || return 1
    fi
    chmod 600 "$TKOC_ACTIVE_SNAPSHOT/$blob" 2>/dev/null || true
    mode="$(tkoc_stat mode "$target_path")"; uid="$(tkoc_stat uid "$target_path")"; gid="$(tkoc_stat gid "$target_path")"
  fi
  tkoc_state_manifest_append 'file\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$encoded" "$kind" "$mode" "$uid" "$gid" "$link" "$blob" \
    || return 1
}

tkoc_state_capture_permission() {
  local target_path="$1"
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" && -e "$target_path" ]] || return 0
  tkoc_state_valid_target "$target_path" || return 1
  local encoded; encoded="$(tkoc_b64_encode "$target_path")"
  tkoc_state_manifest_has permission "$encoded" && return 0
  tkoc_state_manifest_append 'permission\t%s\t%s\t%s\t%s\n' "$encoded" \
    "$(tkoc_stat mode "$target_path")" "$(tkoc_stat uid "$target_path")" "$(tkoc_stat gid "$target_path")" \
    || return 1
}

# ── Fedora capture kinds ────────────────────────────────────────

# systemd replaces launchd. Three facts matter for a faithful restore: whether
# the unit was masked, whether it was enabled, and whether it was running. A
# masked unit reports "masked" from is-enabled, which is why that is recorded
# separately rather than folded into the enabled flag.
tkoc_state_capture_systemd() {
  local unit="$1" enabled=unknown active=inactive masked=no encoded
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  encoded="$(tkoc_b64_encode "$unit")"
  tkoc_state_manifest_has systemd "$encoded" && return 0
  enabled="$(systemctl is-enabled -- "$unit" 2>/dev/null || true)"
  [[ -n "$enabled" ]] || enabled=unknown
  [[ "$enabled" == masked || "$enabled" == masked-runtime ]] && masked=yes
  systemctl is-active --quiet -- "$unit" 2>/dev/null && active=active
  tkoc_state_manifest_append 'systemd\t%s\t%s\t%s\t%s\n' "$encoded" "$enabled" "$active" "$masked"
}

tkoc_state_capture_sysctl() {
  local name="$1" value
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  local encoded_name; encoded_name="$(tkoc_b64_encode "$name")"
  tkoc_state_manifest_has sysctl "$encoded_name" && return 0
  value="$(sysctl -n "$name" 2>/dev/null || printf __unavailable__)"
  tkoc_state_manifest_append 'sysctl\t%s\t%s\n' "$encoded_name" "$(tkoc_b64_encode "$value")"
}

# KDE settings live in kconfig files, not a defaults database. Capture the
# current value (or the fact that the key was unset) so restore can put back
# exactly what was there, including "nothing".
tkoc_state_capture_kconfig() {
  local file="$1" group="$2" key="$3" value="" present=no encoded_file encoded_group encoded_key
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  command -v kreadconfig6 >/dev/null 2>&1 || return 0
  encoded_file="$(tkoc_b64_encode "$file")"
  encoded_group="$(tkoc_b64_encode "$group")"
  encoded_key="$(tkoc_b64_encode "$key")"
  tkoc_state_manifest_has kconfig "$encoded_file" "$encoded_group" "$encoded_key" && return 0
  if value="$(kreadconfig6 --file "$file" --group "$group" --key "$key" 2>/dev/null)" \
    && [[ -n "$value" ]]; then
    present=yes
  fi
  tkoc_state_manifest_append 'kconfig\t%s\t%s\t%s\t%s\t%s\n' \
    "$encoded_file" "$encoded_group" "$encoded_key" "$present" "$(tkoc_b64_encode "$value")"
}

# NetworkManager connection DNS. `nmcli -g` prints the raw value, which is what
# `nmcli con mod` takes back, so this round-trips without parsing prose.
tkoc_state_capture_nm_dns() {
  local connection="$1" value encoded
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  encoded="$(tkoc_b64_encode "$connection")"
  tkoc_state_manifest_has nmdns "$encoded" && return 0
  value="$(nmcli -g ipv4.dns,ipv4.ignore-auto-dns connection show -- "$connection" 2>/dev/null | paste -sd'|' -)"
  tkoc_state_manifest_append 'nmdns\t%s\t%s\n' "$encoded" "$(tkoc_b64_encode "$value")"
}

tkoc_state_capture_nm_ipv6() {
  local connection="$1" value encoded
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || return 0
  encoded="$(tkoc_b64_encode "$connection")"
  tkoc_state_manifest_has nmipv6 "$encoded" && return 0
  value="$(nmcli -g ipv6.method connection show -- "$connection" 2>/dev/null | head -1)"
  tkoc_state_manifest_append 'nmipv6\t%s\t%s\n' "$encoded" "$(tkoc_b64_encode "$value")"
}

# The live nftables ruleset for our own table. `nft -f` on the dump restores it
# atomically; an absent table is recorded as such so restore deletes ours.
tkoc_state_capture_nftables() {
  local table="${1:-inet tkoc_host}" value="" present=no encoded
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  command -v nft >/dev/null 2>&1 || return 0
  encoded="$(tkoc_b64_encode "$table")"
  tkoc_state_manifest_has nftables "$encoded" && return 0
  # shellcheck disable=SC2086
  if value="$(sudo -n nft list table $table 2>/dev/null)" && [[ -n "$value" ]]; then
    present=yes
  fi
  tkoc_state_manifest_append 'nftables\t%s\t%s\t%s\n' "$encoded" "$present" "$(tkoc_b64_encode "$value")"
}

# firewalld owns nftables on a stock Fedora install. Displacing it is the single
# most disruptive thing this repo does, so its prior state is captured
# explicitly rather than relying on the generic systemd capture alone.
tkoc_state_capture_firewalld() {
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  tkoc_state_manifest_has firewalld firewalld && return 0
  local enabled active=inactive masked=no
  enabled="$(systemctl is-enabled firewalld.service 2>/dev/null || printf unknown)"
  [[ "$enabled" == masked || "$enabled" == masked-runtime ]] && masked=yes
  systemctl is-active --quiet firewalld.service 2>/dev/null && active=active
  tkoc_state_manifest_append 'firewalld\t%s\t%s\t%s\t%s\n' firewalld "$enabled" "$active" "$masked"
}

tkoc_state_capture_command() {
  local id="$1" restore_command="$2" value=""
  shift 2
  [[ -n "$TKOC_ACTIVE_SNAPSHOT" ]] || return 0
  local encoded_id; encoded_id="$(tkoc_b64_encode "$id")"
  tkoc_state_manifest_has command "$encoded_id" && return 0
  value="$("$@" 2>/dev/null || true)"
  tkoc_state_manifest_append 'command\t%s\t%s\t%s\n' "$encoded_id" \
    "$(tkoc_b64_encode "$restore_command")" "$(tkoc_b64_encode "$value")" \
    || return 1
}

# ── Inspection and restore ──────────────────────────────────────

tkoc_state_meta() {
  local snapshot="$1" key="$2"
  awk -F= -v key="$key" '$1==key {sub(/^[^=]*=/, ""); print; exit}' "$snapshot/meta" 2>/dev/null
}

# Snapshot ids begin with a UTC timestamp (YYYYmmddTHHMMSSZ-pid.suffix), so a
# lexical sort of the names is already chronological. That is deliberate:
# `find -printf` is GNU-only and mtime lies after any copy or restore, whereas
# the name records when the transaction actually began.
tkoc_state_snapshots() {
  local entry
  [[ -d "$TKOC_SNAPSHOT_ROOT" ]] || return 0
  for entry in "$TKOC_SNAPSHOT_ROOT"/*; do
    [[ -d "$entry" && -f "$entry/meta" ]] || continue
    printf '%s\n' "$entry"
  done | LC_ALL=C sort -r
}

tkoc_state_resolve() {
  local requested="${1:-latest}" resolved
  if [[ "$requested" == latest ]]; then
    resolved="$(tkoc_state_snapshots | head -1)"
    [[ -n "$resolved" ]] || return 1
    printf '%s' "$resolved"
  elif [[ "$requested" == /* ]]; then
    resolved="$(readlink -f -- "$requested" 2>/dev/null || true)"
    [[ -n "$resolved" && -d "$resolved" ]] || return 1
    [[ "$(_tkoc_dirname "$resolved")" == "$(readlink -f -- "$TKOC_SNAPSHOT_ROOT")" ]] || return 1
    printf '%s' "$resolved"
  else
    [[ "$requested" != */* && "$requested" != .* ]] || return 1
    [[ -d "$TKOC_SNAPSHOT_ROOT/$requested" ]] || return 1
    printf '%s' "$TKOC_SNAPSHOT_ROOT/$requested"
  fi
}

_tkoc_state_dry() { [[ "${TKOC_DRY_RUN:-disabled}" == enabled ]]; }

tkoc_state_restore_file() {
  local snapshot="$1" encoded="$2" kind="$3" mode="$4" uid="$5" gid="$6" link="$7" blob="$8"
  local target_path parent
  target_path="$(tkoc_b64_decode "$encoded")"
  tkoc_state_valid_target "$target_path" || return 1
  parent="$(_tkoc_dirname "$target_path")"
  if _tkoc_state_dry; then
    printf '[tkoc][dry-run] restore %q (%s)\n' "$target_path" "$kind"
    return 0
  fi
  case "$kind" in
    missing)
      [[ ! -e "$target_path" && ! -L "$target_path" ]] || tkoc_state_run_path "$target_path" rm -rf -- "$target_path"
      ;;
    symlink)
      local target; target="$(tkoc_b64_decode "$link")"
      tkoc_state_run_path "$target_path" rm -rf -- "$target_path"
      tkoc_state_run_path "$target_path" mkdir -p -- "$parent"
      tkoc_state_run_path "$target_path" ln -s -- "$target" "$target_path"
      tkoc_state_run_path "$target_path" chown -h "$uid:$gid" "$target_path" 2>/dev/null || true
      ;;
    file)
      tkoc_state_run_path "$target_path" mkdir -p -- "$parent"
      tkoc_state_run_path "$target_path" install -m "$mode" -- "$snapshot/$blob" "$target_path"
      tkoc_state_run_path "$target_path" chown "$uid:$gid" "$target_path" 2>/dev/null || true
      # A restored file under /etc needs its SELinux label back, or the service
      # that reads it may be denied access on a system in enforcing mode.
      command -v restorecon >/dev/null 2>&1 \
        && tkoc_state_run_path "$target_path" restorecon -F -- "$target_path" 2>/dev/null || true
      ;;
    directory)
      tkoc_state_run_path "$target_path" rm -rf -- "$target_path"
      tkoc_state_run_path "$target_path" mkdir -p -- "$parent"
      if tkoc_state_needs_root "$parent" write; then
        sudo tar -xf "$snapshot/$blob" -C "$parent"
      else
        tar -xf "$snapshot/$blob" -C "$parent"
      fi
      command -v restorecon >/dev/null 2>&1 \
        && tkoc_state_run_path "$target_path" restorecon -RF -- "$target_path" 2>/dev/null || true
      ;;
  esac
}

tkoc_state_restore_systemd() {
  local unit enabled="$2" active="$3" masked="$4"
  unit="$(tkoc_b64_decode "$1")"
  if _tkoc_state_dry; then
    printf '[tkoc][dry-run] restore unit %q enabled=%s active=%s masked=%s\n' \
      "$unit" "$enabled" "$active" "$masked"
    return 0
  fi
  # Unmask first: every other verb is refused while a unit is masked.
  sudo systemctl unmask -- "$unit" >/dev/null 2>&1 || true
  case "$enabled" in
    enabled|enabled-runtime) sudo systemctl enable -- "$unit" >/dev/null 2>&1 || true ;;
    disabled) sudo systemctl disable -- "$unit" >/dev/null 2>&1 || true ;;
    masked|masked-runtime) sudo systemctl mask -- "$unit" >/dev/null 2>&1 || true ;;
    *) : ;;  # static, indirect, generated, unknown — not ours to set
  esac
  [[ "$masked" == yes ]] && sudo systemctl mask -- "$unit" >/dev/null 2>&1 || true
  if [[ "$active" == active && "$masked" != yes ]]; then
    sudo systemctl start -- "$unit" >/dev/null 2>&1 || true
  elif [[ "$active" != active ]]; then
    sudo systemctl stop -- "$unit" >/dev/null 2>&1 || true
  fi
}

tkoc_state_restore() {
  local snapshot="$1" force="${2:-disabled}"
  snapshot="$(readlink -f -- "$snapshot" 2>/dev/null || printf '%s' "$snapshot")"
  local snapshot_root snapshot_mode snapshot_owner
  snapshot_root="$(readlink -f -- "$TKOC_SNAPSHOT_ROOT" 2>/dev/null || printf '%s' "$TKOC_SNAPSHOT_ROOT")"
  [[ "$(_tkoc_dirname "$snapshot")" == "$snapshot_root" ]] || return 4
  [[ -f "$snapshot/meta" && -f "$snapshot/manifest.tsv" ]] || return 1
  snapshot_mode="$(tkoc_stat mode "$snapshot" || printf 777)"
  snapshot_owner="$(tkoc_stat uid "$snapshot" || printf -- -1)"
  [[ "$snapshot_owner" == "${EUID:-$(id -u)}" ]] || return 4
  (( (8#$snapshot_mode & 8#022) == 0 )) || return 4
  [[ "$(tkoc_state_meta "$snapshot" schema)" == "$TKOC_STATE_SCHEMA" ]] || return 1
  if [[ "$force" != enabled ]]; then
    [[ "$(tkoc_state_meta "$snapshot" uid)" == "${EUID:-$(id -u)}" ]] || return 2
    [[ "$(tkoc_b64_decode "$(tkoc_state_meta "$snapshot" host_b64)")" == "$(tkoc_host_id)" ]] || return 3
  fi

  local kind a b c d e f g
  while IFS=$'\t' read -r kind a b c d e f g; do
    case "$kind" in
      file) tkoc_state_restore_file "$snapshot" "$a" "$b" "$c" "$d" "$e" "$f" "$g" || return 1 ;;
      systemd) tkoc_state_restore_systemd "$a" "$b" "$c" "$d" || return 1 ;;
      permission)
        local target_path; target_path="$(tkoc_b64_decode "$a")"
        tkoc_state_valid_target "$target_path" || return 1
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] chmod %s %q\n' "$b" "$target_path"
        elif [[ -e "$target_path" ]]; then
          tkoc_state_run_path "$target_path" chmod "$b" "$target_path" || return 1
          tkoc_state_run_path "$target_path" chown "$c:$d" "$target_path" 2>/dev/null || true
        fi
        ;;
      sysctl)
        local sysctl_name sysctl_value
        sysctl_name="$(tkoc_b64_decode "$a")"; sysctl_value="$(tkoc_b64_decode "$b")"
        [[ "$sysctl_value" == __unavailable__ ]] && continue
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] sudo sysctl -w %q=%q\n' "$sysctl_name" "$sysctl_value"
        else
          sudo sysctl -q -w "${sysctl_name}=${sysctl_value}" >/dev/null || return 1
        fi
        ;;
      kconfig)
        local kfile kgroup kkey kpresent="$d" kvalue
        kfile="$(tkoc_b64_decode "$a")"; kgroup="$(tkoc_b64_decode "$b")"
        kkey="$(tkoc_b64_decode "$c")"; kvalue="$(tkoc_b64_decode "$e")"
        command -v kwriteconfig6 >/dev/null 2>&1 || continue
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] restore kconfig %q/%q/%q (present=%s)\n' "$kfile" "$kgroup" "$kkey" "$kpresent"
        elif [[ "$kpresent" == yes ]]; then
          kwriteconfig6 --file "$kfile" --group "$kgroup" --key "$kkey" "$kvalue" || true
        else
          kwriteconfig6 --file "$kfile" --group "$kgroup" --key "$kkey" --delete || true
        fi
        ;;
      nmdns)
        local connection raw dns ignore
        connection="$(tkoc_b64_decode "$a")"; raw="$(tkoc_b64_decode "$b")"
        dns="${raw%%|*}"; ignore="${raw#*|}"
        [[ "$ignore" == "$raw" ]] && ignore=""
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] restore DNS %q -> %q\n' "$connection" "$dns"
        else
          sudo nmcli connection modify -- "$connection" ipv4.dns "$dns" >/dev/null 2>&1 || true
          [[ -n "$ignore" ]] && sudo nmcli connection modify -- "$connection" \
            ipv4.ignore-auto-dns "$ignore" >/dev/null 2>&1 || true
        fi
        ;;
      nmipv6)
        local connection method
        connection="$(tkoc_b64_decode "$a")"; method="$(tkoc_b64_decode "$b")"
        [[ -n "$method" ]] || continue
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] restore IPv6 %q -> %q\n' "$connection" "$method"
        else
          sudo nmcli connection modify -- "$connection" ipv6.method "$method" >/dev/null 2>&1 || true
        fi
        ;;
      nftables)
        local table present="$b" ruleset
        table="$(tkoc_b64_decode "$a")"; ruleset="$(tkoc_b64_decode "$c")"
        command -v nft >/dev/null 2>&1 || continue
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] restore nftables table %q (present=%s)\n' "$table" "$present"
        elif [[ "$present" == yes ]]; then
          printf '%s\n' "$ruleset" | sudo nft -f - || return 1
        else
          # shellcheck disable=SC2086
          sudo nft delete table $table >/dev/null 2>&1 || true
        fi
        ;;
      firewalld)
        # $a is the literal key "firewalld"; the state is in b/c/d.
        if _tkoc_state_dry; then
          printf '[tkoc][dry-run] restore firewalld enabled=%s active=%s masked=%s\n' "$b" "$c" "$d"
        else
          tkoc_state_restore_systemd "$(tkoc_b64_encode firewalld.service)" "$b" "$c" "$d"
        fi
        ;;
      command)
        # Command records are advisory until a subsystem provides a typed restorer.
        ;;
    esac
  done < "$snapshot/manifest.tsv"
}
