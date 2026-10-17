#!/usr/bin/env bash
# tools/killall.sh -- quit every open graphical app, minus what you protect.
#
# Asks each app to close, waits a grace period, then force-kills what is left.
# The Plasma session itself is always protected: killing plasmashell, kwin or
# the session manager logs you out, which is not "closing your apps".
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

GRACE_SECONDS=5
EXTRA_PROTECTED=()

# Killing any of these ends the session rather than closing an application.
# sddm and systemd are here because a stray match would log the user out or
# take the machine down.
protected_names() {
  printf '%s\n' \
    plasmashell kwin_wayland kwin_x11 kwin \
    ksmserver kded6 kded5 krunner plasma-shell \
    xdg-desktop-portal xdg-desktop-portal-kde \
    sddm sddm-helper systemd systemd-logind dbus-daemon dbus-broker \
    pipewire wireplumber pulseaudio \
    Xorg Xwayland gnome-keyring-daemon kwalletd6 kwalletd5 \
    ssh-agent gpg-agent
}

usage() {
  cat <<'HELP'
killall -- close every open graphical application

Usage:
  tkoc killall [--protect name]... [--grace <seconds>] [--list] [--yes]

Options:
  --list            Show what would be closed, close nothing
  --protect <name>  Also protect this process name; repeatable
  --grace <secs>    Seconds to wait before force-killing (default: 5)
  --dry-run         Same as --list
  --yes             Skip the confirmation prompt

The Plasma session (plasmashell, kwin, ksmserver, sddm), the audio stack, the
portals and the keyring are always protected: ending any of them logs you out
instead of closing an app. Your own terminal is protected too.
HELP
}

is_protected() {
  local name="$1" protected
  while read -r protected; do
    [[ "$name" == "$protected" ]] && return 0
  done < <(protected_names)
  local extra
  for extra in ${EXTRA_PROTECTED[@]+"${EXTRA_PROTECTED[@]}"}; do
    [[ "$name" == "$extra" ]] && return 0
  done
  return 1
}

# The terminal this is running in, resolved by walking up the process tree
# rather than trusting $TERM or $TERM_PROGRAM -- those name the emulator's
# branding, not the process the kernel knows about.
current_terminal_pid() {
  local pid=$$ ppid comm
  while (( pid > 1 )); do
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || break
    [[ "$ppid" =~ ^[0-9]+$ ]] || break
    comm="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d '[:space:]')" || break
    case "$comm" in
      konsole|yakuake|alacritty|kitty|foot|gnome-terminal-server|xterm|wezterm*|ghostty)
        printf '%s' "$ppid"; return 0 ;;
    esac
    pid="$ppid"
  done
  return 1
}

# Graphical applications, from the window manager's own list where possible.
# Falling back to "every process with a controlling display" would sweep in
# session infrastructure, which is exactly what must not be killed.
graphical_pids() {
  if command -v wmctrl >/dev/null 2>&1; then
    wmctrl -lp 2>/dev/null | awk '{ print $3 }' | sort -un
    return 0
  fi
  if command -v kdotool >/dev/null 2>&1; then
    kdotool search --name '.*' 2>/dev/null | while read -r win; do
      kdotool getwindowpid "$win" 2>/dev/null
    done | sort -un
    return 0
  fi
  return 1
}

main() {
  local list_only=disabled
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list) list_only=enabled; shift ;;
      --protect) [[ $# -ge 2 ]] || die "--protect requires a process name"
                 EXTRA_PROTECTED[${#EXTRA_PROTECTED[@]}]="$2"; shift 2 ;;
      --protect=*) EXTRA_PROTECTED[${#EXTRA_PROTECTED[@]}]="${1#*=}"; shift ;;
      --grace) [[ $# -ge 2 ]] || die "--grace requires a number of seconds"
               GRACE_SECONDS="$2"; shift 2 ;;
      help|--help|-h) usage; exit 0 ;;
      -*) tkoc_parse_safety_flag "$1" || die "killall: unknown option: $1"; shift ;;
      *) die "killall: unexpected argument: $1" ;;
    esac
  done
  [[ "$GRACE_SECONDS" =~ ^[0-9]+$ ]] || die "--grace requires a whole number of seconds"
  tkoc_bool_enabled TKOC_DRY_RUN disabled && list_only=enabled

  need_not_root

  local terminal_pid=""
  terminal_pid="$(current_terminal_pid || true)"

  local -a targets=()
  local pid name
  if ! graphical_pids >/dev/null 2>&1; then
    die "neither wmctrl nor kdotool is installed, so the open windows cannot be
enumerated safely. Install one with: sudo dnf install wmctrl"
  fi
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    (( pid > 1 )) || continue
    name="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || continue
    [[ -n "$name" ]] || continue
    is_protected "$name" && continue
    [[ -n "$terminal_pid" && "$pid" == "$terminal_pid" ]] && continue
    targets[${#targets[@]}]="$pid $name"
  done < <(graphical_pids)

  if (( ${#targets[@]} == 0 )); then
    log "nothing to close"
    return 0
  fi

  log "${#targets[@]} application(s) would be closed:"
  local entry
  for entry in "${targets[@]}"; do printf '  %s\n' "$entry"; done
  [[ -n "$terminal_pid" ]] && log "protecting this terminal (pid $terminal_pid)"

  if [[ "$list_only" == enabled ]]; then
    log "nothing was closed"
    return 0
  fi

  tkoc_confirm "Close these ${#targets[@]} application(s)?" \
    || { log "Aborted. Nothing closed."; return 0; }

  for entry in "${targets[@]}"; do
    kill -TERM "${entry%% *}" 2>/dev/null || true
  done
  log "asked each application to quit; waiting ${GRACE_SECONDS}s"
  sleep "$GRACE_SECONDS"

  local remaining=0
  for entry in "${targets[@]}"; do
    pid="${entry%% *}"
    if kill -0 "$pid" 2>/dev/null; then
      warn "force-killing ${entry}"
      kill -KILL "$pid" 2>/dev/null || true
      remaining=$((remaining+1))
    fi
  done
  log "done; $remaining needed a force-kill"
}

main "$@"
