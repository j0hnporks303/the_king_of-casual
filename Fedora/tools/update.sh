#!/usr/bin/env bash
# tools/update.sh -- one-shot "what is out of date" for Fedora.
#
# Two phases, like the macOS edition. First it queries every source and prints
# ONE combined list of what could change. Then one confirmation applies only the
# sources you selected.
#
#   1. this checkout            git pull --ff-only
#   2. RPM packages             dnf upgrade
#   3. Flatpaks                 flatpak update
#   4. Device firmware          fwupdmgr update
#
# Run as your normal user. dnf, flatpak --system and fwupd need sudo during the
# apply phase and will ask then, not during the query.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

DO_REPO=disabled
DO_DNF=disabled
DO_FLATPAK=disabled
DO_FIRMWARE=disabled
ANY_SELECTED=disabled

usage() {
  cat <<'HELP'
update -- report and apply updates from every source at once

Usage:
  tkoc update                Query everything, then offer to apply everything
  tkoc update --dnf          Apply only RPM package updates
  tkoc update --repo --dnf   Apply only these sources
  tkoc update --dry-run      Query only; change nothing
  tkoc update --yes          Skip the confirmation

Sources:
  --repo       This checkout (git pull --ff-only)
  --dnf        RPM packages (sudo dnf upgrade)
  --flatpak    Flatpak applications and runtimes
  --firmware   Device firmware via fwupd
  --all        All of the above (the default when none is named)

It refuses to pull over local uncommitted changes -- commit or stash first.
Firmware updates can require a reboot and, on some hardware, a power cycle; you
see the exact list before confirming.
HELP
}

section() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
none()    { printf '  nothing to do\n'; }

# ── Query ───────────────────────────────────────────────────────

REPO_BEHIND=0
REPO_DIRTY=disabled
DNF_COUNT=0
FLATPAK_COUNT=0
FIRMWARE_COUNT=0

query_repo() {
  section "This checkout ($REPO_ROOT)"
  if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf '  not a git checkout; skipped\n'
    return 0
  fi
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    REPO_DIRTY=enabled
    printf '  local uncommitted changes -- a pull would be refused\n'
    printf '  commit or stash them first if you want this updated\n'
  fi
  git -C "$REPO_ROOT" fetch --quiet 2>/dev/null || { printf '  could not reach the remote\n'; return 0; }
  REPO_BEHIND="$(git -C "$REPO_ROOT" rev-list --count HEAD..@{u} 2>/dev/null || printf 0)"
  if [[ "$REPO_BEHIND" =~ ^[0-9]+$ ]] && (( REPO_BEHIND > 0 )); then
    printf '  %s commit(s) behind %s\n' "$REPO_BEHIND" "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"
    git -C "$REPO_ROOT" log --oneline "HEAD..@{u}" 2>/dev/null | head -10 | sed 's/^/    /'
  else
    none
  fi
}

query_dnf() {
  section "RPM packages"
  if ! command -v dnf >/dev/null 2>&1; then printf '  dnf is unavailable\n'; return 0; fi
  local out
  # `dnf check-update` exits 100 when updates exist, 0 when none, >100 on error.
  out="$(dnf -q check-update 2>/dev/null)" && DNF_COUNT=0 || true
  out="$(printf '%s\n' "$out" | awk 'NF && $1 !~ /^(Last|Obsoleting|Security)/ { print }')"
  DNF_COUNT="$(printf '%s\n' "$out" | grep -c . || true)"
  if [[ "$DNF_COUNT" =~ ^[0-9]+$ ]] && (( DNF_COUNT > 0 )); then
    printf '  %s package(s) can be upgraded\n' "$DNF_COUNT"
    printf '%s\n' "$out" | head -15 | awk '{ printf "    %-42s %s\n", $1, $2 }'
    (( DNF_COUNT > 15 )) && printf '    ... and %d more\n' "$((DNF_COUNT - 15))"
  else
    none
  fi
}

query_flatpak() {
  section "Flatpak"
  if ! command -v flatpak >/dev/null 2>&1; then printf '  flatpak is not installed\n'; return 0; fi
  local out
  out="$(flatpak remote-ls --updates --columns=application,version 2>/dev/null || true)"
  FLATPAK_COUNT="$(printf '%s' "$out" | grep -c . || true)"
  if [[ "$FLATPAK_COUNT" =~ ^[0-9]+$ ]] && (( FLATPAK_COUNT > 0 )); then
    printf '  %s flatpak(s) can be updated\n' "$FLATPAK_COUNT"
    printf '%s\n' "$out" | head -15 | sed 's/^/    /'
  else
    none
  fi
}

query_firmware() {
  section "Device firmware"
  if ! command -v fwupdmgr >/dev/null 2>&1; then printf '  fwupd is not installed\n'; return 0; fi
  local out
  out="$(fwupdmgr get-updates --no-unreported-check 2>&1 || true)"
  if grep -Eqi 'No updates available|No releases found|Devices with no available firmware' <<<"$out"; then
    none
  else
    FIRMWARE_COUNT=1
    printf '%s\n' "$out" | sed 's/^/    /' | head -20
    printf '\n  Firmware updates can require a reboot, and some need a power cycle.\n'
  fi
}

# ── Apply ───────────────────────────────────────────────────────

apply_repo() {
  [[ "$REPO_DIRTY" == enabled ]] && { warn "skipping the repo: it has uncommitted changes"; return 0; }
  (( REPO_BEHIND > 0 )) || return 0
  section "Updating the checkout"
  run_or_print git -C "$REPO_ROOT" pull --ff-only
}

apply_dnf() {
  (( DNF_COUNT > 0 )) || return 0
  section "Upgrading RPM packages"
  run_root dnf upgrade -y
}

apply_flatpak() {
  (( FLATPAK_COUNT > 0 )) || return 0
  section "Updating flatpaks"
  run_or_print flatpak update -y
}

apply_firmware() {
  (( FIRMWARE_COUNT > 0 )) || return 0
  section "Updating device firmware"
  run_root fwupdmgr update -y
}

# ── Main ────────────────────────────────────────────────────────

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)     DO_REPO=enabled; ANY_SELECTED=enabled; shift ;;
      --dnf|--rpm) DO_DNF=enabled; ANY_SELECTED=enabled; shift ;;
      --flatpak)  DO_FLATPAK=enabled; ANY_SELECTED=enabled; shift ;;
      --firmware) DO_FIRMWARE=enabled; ANY_SELECTED=enabled; shift ;;
      --all)      DO_REPO=enabled; DO_DNF=enabled; DO_FLATPAK=enabled; DO_FIRMWARE=enabled
                  ANY_SELECTED=enabled; shift ;;
      help|--help|-h) usage; exit 0 ;;
      *) tkoc_parse_safety_flag "$1" || die "update: unknown option: $1"; shift ;;
    esac
  done

  need_not_root
  if [[ "$ANY_SELECTED" == disabled ]]; then
    DO_REPO=enabled; DO_DNF=enabled; DO_FLATPAK=enabled; DO_FIRMWARE=enabled
  fi

  log "Querying update sources (nothing is changed yet)"
  [[ "$DO_REPO" == enabled ]]     && query_repo
  [[ "$DO_DNF" == enabled ]]      && query_dnf
  [[ "$DO_FLATPAK" == enabled ]]  && query_flatpak
  [[ "$DO_FIRMWARE" == enabled ]] && query_firmware

  local total=$(( REPO_BEHIND + DNF_COUNT + FLATPAK_COUNT + FIRMWARE_COUNT ))
  printf '\n'
  if (( total == 0 )); then
    log "everything is up to date"
    return 0
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "dry run: nothing was applied"
    return 0
  fi

  tkoc_confirm "Apply the updates listed above?" \
    || { log "Aborted. Nothing was applied."; return 0; }

  [[ "$DO_REPO" == enabled ]]     && apply_repo
  [[ "$DO_DNF" == enabled ]]      && apply_dnf
  [[ "$DO_FLATPAK" == enabled ]]  && apply_flatpak
  [[ "$DO_FIRMWARE" == enabled ]] && apply_firmware

  printf '\n'
  log "updates applied"
  if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    local newest running
    newest="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2>/dev/null | sort -V | tail -1 || true)"
    running="$(uname -r)"
    [[ -n "$newest" && "$running" != "$newest" ]] \
      && log "a newer kernel ($newest) is installed; reboot to use it"
  fi
  log "check the result with: tkoc status"
}

main "$@"
