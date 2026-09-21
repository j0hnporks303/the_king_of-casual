#!/usr/bin/env bash
# tools/ice.sh -- the opt-in customization package layer.
#
# One manifest, config/ice/packages.conf, installed with dnf. It never runs as
# part of check, install, apply, harden, or audit: pulling packages onto a
# machine is a separate decision from hardening one.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

MANIFEST="$REPO_ROOT/config/ice/packages.conf"

usage() {
  cat <<'HELP'
Usage: tkoc ice [--dry-run] [--yes]
       tkoc ice list

Installs the package list in config/ice/packages.conf with dnf, skipping
packages that are already present. Package names are validated before dnf is
invoked, so a typo in the manifest is a clear error rather than a confusing
dnf resolution failure.

--dry-run lists the configured packages and reports which are missing, without
installing anything.
HELP
}

# rpm package names allow letters, digits and - _ + . ; a leading dash or a
# shell metacharacter in this file would otherwise reach dnf's command line.
validate_manifest() {
  local file="$1" package
  [[ -r "$file" ]] || die "missing ice package manifest: $file"
  while IFS= read -r package || [[ -n "$package" ]]; do
    package="$(trim_line "$package")"
    [[ -z "$package" ]] && continue
    [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
      || die "invalid package name in $file: $package"
  done <"$file"
}

read_manifest() {
  local package
  while IFS= read -r package || [[ -n "$package" ]]; do
    package="$(trim_line "$package")"
    [[ -n "$package" ]] && printf '%s\n' "$package"
  done <"$MANIFEST"
}

main() {
  local list_only=disabled
  while [[ $# -gt 0 ]]; do
    case "$1" in
      list) list_only=enabled; shift ;;
      help|--help|-h) usage; exit 0 ;;
      *) tkoc_parse_safety_flag "$1" || die "ice: unknown option: $1"; shift ;;
    esac
  done

  validate_manifest "$MANIFEST"

  local -a packages=() missing=()
  local package
  while read -r package; do
    packages[${#packages[@]}]="$package"
  done < <(read_manifest | awk '!seen[$0]++')
  (( ${#packages[@]} > 0 )) || die "ice package manifest is empty"

  if [[ "$list_only" == enabled ]]; then
    log "ice customization packages:"
    printf '  %s\n' "${packages[@]}"
    return 0
  fi

  need_fedora
  need_dnf
  for package in "${packages[@]}"; do
    rpm_installed "$package" || missing[${#missing[@]}]="$package"
  done

  if (( ${#missing[@]} == 0 )); then
    log "ice customization is already installed"
    return 0
  fi

  log "missing packages: ${missing[*]}"
  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "dry run: no packages were installed"
    return 0
  fi

  tkoc_confirm "Install ${#missing[@]} package(s) with dnf?" \
    || { log "Aborted. No packages installed."; return 0; }
  dnf_install "${missing[@]}"
  log "ice customization applied"
}

main "$@"
