#!/usr/bin/env bash
# Install and remove the root-owned persistence this repo uses.
#
# Fedora needs far less of this than macOS did. The firewall is restored at boot
# by nftables.service, and the sysctl policy by systemd-sysctl.service, both of
# which are part of the OS. So there is no pf-restore daemon, no drift timer by
# default, and nothing that re-applies policy behind your back.
#
# What remains is the NetworkManager dispatcher used by `tkoc firewall watch`,
# and the optional ClamAV timer. Both are opt-in and both are removed by
# `tkoc uninstall`.

[[ -n "${TKOC_PERSISTENCE_LIB_LOADED:-}" ]] && return 0
TKOC_PERSISTENCE_LIB_LOADED=1

TKOC_PERSISTENCE_DIR="${TKOC_TEST_ROOT:-}/usr/local/libexec/tkoc"
TKOC_SYSTEMD_DIR="${TKOC_TEST_ROOT:-}/etc/systemd/system"
TKOC_DISPATCHER_DIR="${TKOC_TEST_ROOT:-}/etc/NetworkManager/dispatcher.d"

tkoc_validate_persistence_name() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]+$ ]] \
    || die "Unsafe persistence name: $1"
}

# A privileged path that is a symlink is a redirect: root writes through it to
# wherever it points, which may be somewhere an unprivileged account controls.
tkoc_refuse_persistence_symlink() {
  local target_path="$1"
  tkoc_bool_enabled TKOC_DRY_RUN disabled && return 0
  if [[ -L "$target_path" ]]; then
    die "Refusing symlinked privileged persistence path: $target_path"
  fi
}

tkoc_install_privileged_file() {
  local source="$1" target="$2" mode="${3:-0755}"
  tkoc_refuse_persistence_symlink "$target"
  run_root_path "$target" mkdir -p -- "$(dirname -- "$target")"
  run_root_path "$target" install -o root -g root -m "$mode" -- "$source" "$target" 2>/dev/null \
    || run_root_path "$target" install -m "$mode" -- "$source" "$target"
  log "installed $target"
}

tkoc_remove_privileged_file() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  run_root_path "$target" rm -f -- "$target"
  log "removed $target"
}

tkoc_install_systemd_unit() {
  local name="$1" content="$2" tmp
  tkoc_validate_persistence_name "$name"
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-unit.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  tkoc_install_privileged_file "$tmp" "$TKOC_SYSTEMD_DIR/$name" 0644
  rm -f -- "$tmp"
  [[ -n "${TKOC_TEST_ROOT:-}" ]] || run_root systemctl daemon-reload
  return 0
}

tkoc_remove_systemd_unit() {
  local name="$1"
  tkoc_validate_persistence_name "$name"
  if [[ -z "${TKOC_TEST_ROOT:-}" ]] && command -v systemctl >/dev/null 2>&1; then
    run_root systemctl disable --now -- "$name" >/dev/null 2>&1 || true
  fi
  tkoc_remove_privileged_file "$TKOC_SYSTEMD_DIR/$name"
  [[ -n "${TKOC_TEST_ROOT:-}" ]] || run_root systemctl daemon-reload || true
}
