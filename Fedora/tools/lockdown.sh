#!/usr/bin/env bash
# tools/lockdown.sh -- the root-owned counterpart of downlock.
#
# Must run as root, defaults to /root, matches owner root, and skips directory
# modes unless --include-dirs is given: tightening directory modes under /etc or
# /usr is how a system stops booting.
#
# `make root-tools` installs a root-owned COPY of this at
# /usr/local/libexec/tkoc, reachable as `sudo tkoc-lockdown`. That is a copy and
# not a symlink on purpose: root must never execute a file your user account can
# rewrite.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

usage() {
  cat <<'HELP'
lockdown -- report and tighten root-owned file permissions

Usage:
  sudo "$(command -v tkoc)" fs lockdown [path] [options]
  sudo tkoc-lockdown [path] [options]

Options:
  --apply          Actually change modes (default is report only)
  --list           List matching paths, change nothing
  --include-dirs   Also adjust directory modes (off by default)
  --owner <user>   Owner to match (default: root)
  --verbose        Show every differing path
  --yes            Skip the confirmation prompt

Defaults to /root. Directory modes are skipped unless you ask for them, because
tightening a directory under /etc or /usr can make the system unbootable.
HELP
}

[[ "${1:-}" == help || "${1:-}" == --help || "${1:-}" == -h ]] && { usage; exit 0; }

need_root

# Reuse downlock's engine rather than maintaining a second copy of the walk,
# the rule matching, and the reporting. The differences are all defaults.
include_dirs=disabled
declare -a forward=()
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-dirs) include_dirs=enabled; shift ;;
    --owner|--owner=*) forward[${#forward[@]}]="$1"; [[ "$1" == --owner ]] && { forward[${#forward[@]}]="${2:-}"; shift; }; shift ;;
    -*) forward[${#forward[@]}]="$1"; shift ;;
    *) target="$1"; shift ;;
  esac
done

[[ -n "$target" ]] || target=/root
printf '%s\n' "$target" | grep -q '^/' || die "lockdown needs an absolute path"

set -- "$target" --anywhere --owner "${TKOC_LOCKDOWN_OWNER:-root}" ${forward[@]+"${forward[@]}"}
[[ "$include_dirs" == enabled ]] || set -- "$@" --files-only

exec bash "$SCRIPT_DIR/downlock.sh" "$@"
