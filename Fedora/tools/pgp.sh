#!/usr/bin/env bash
# tools/pgp.sh -- encrypt and decrypt files or folders with GnuPG.
#
# GnuPG is identical on Fedora and macOS, so this is the one tool that needed no
# translation beyond the package name (gnupg2) and the shell.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"

RECIPIENTS=()
SYMMETRIC=0
ARMOR=0
SIGN=0
FORCE=0
OUTPUT=""

usage() {
  cat <<'HELP'
pgp -- encrypt/decrypt files and folders with GnuPG

Usage:
  tkoc pgp encrypt <path> [-r <recipient>]... [--symmetric] [--armor] [--sign]
  tkoc pgp decrypt <file.gpg> [--output <path>]
  tkoc pgp keys                       List your secret keys
  tkoc pgp fingerprint <key-id>       Show a key's full fingerprint

Options:
  -r, --recipient <id>   Encrypt to this key; repeatable
  --symmetric            Encrypt with a passphrase instead of a key
  --armor, -a            ASCII-armor the output (.asc)
  --sign, -s             Sign as well as encrypt
  --output, -o <path>    Where to write the result
  --force                Overwrite an existing output file

A directory is packed into a tar archive first, then encrypted; decrypting such
an archive unpacks it into the current directory. Original files are never
deleted -- removing the plaintext is your decision, not this tool's.
HELP
}

need_gpg() {
  command -v gpg >/dev/null 2>&1 \
    || die "gpg is required. Install it with: sudo dnf install gnupg2"
}

output_for() {
  local source="$1" suffix
  if [[ -n "$OUTPUT" ]]; then printf '%s' "$OUTPUT"; return; fi
  suffix=".gpg"; (( ARMOR )) && suffix=".asc"
  if [[ -d "$source" ]]; then
    printf '%s' "${source%/}.tar$suffix"
  else
    printf '%s' "$source$suffix"
  fi
}

cmd_encrypt() {
  local source="$1" dest archive="" rc=0
  [[ -e "$source" ]] || die "no such file or directory: $source"
  (( SYMMETRIC )) || (( ${#RECIPIENTS[@]} > 0 )) \
    || die "encrypt needs either -r <recipient> or --symmetric"

  dest="$(output_for "$source")"
  [[ -e "$dest" ]] && (( ! FORCE )) \
    && die "$dest already exists. Use --force to overwrite."

  local -a flags=(--yes)
  (( ARMOR )) && flags+=(--armor)
  (( SIGN )) && flags+=(--sign)
  if (( SYMMETRIC )); then
    flags+=(--symmetric --cipher-algo AES256)
  else
    local recipient
    for recipient in "${RECIPIENTS[@]}"; do flags+=(--recipient "$recipient"); done
    flags+=(--encrypt)
  fi

  if [[ -d "$source" ]]; then
    archive="$(mktemp "${TMPDIR:-/tmp}/tkoc-pgp.XXXXXX.tar")"
    # shellcheck disable=SC2064
    trap "rm -f -- '$archive'" EXIT
    log "packing $source"
    tar -cf "$archive" -C "$(dirname -- "${source%/}")" "$(basename -- "${source%/}")"
    run_or_print gpg "${flags[@]}" --output "$dest" "$archive" || rc=$?
    rm -f -- "$archive"
    trap - EXIT
  else
    run_or_print gpg "${flags[@]}" --output "$dest" "$source" || rc=$?
  fi
  (( rc == 0 )) || die "gpg failed with status $rc"
  log "encrypted to $dest"
  log "the original is untouched; remove it yourself if that is what you want"
}

cmd_decrypt() {
  local source="$1" dest rc=0
  [[ -f "$source" ]] || die "no such file: $source"
  dest="${OUTPUT:-}"
  if [[ -z "$dest" ]]; then
    dest="${source%.gpg}"; dest="${dest%.asc}"
    [[ "$dest" == "$source" ]] && dest="$source.decrypted"
  fi
  [[ -e "$dest" ]] && (( ! FORCE )) \
    && die "$dest already exists. Use --force to overwrite."

  run_or_print gpg --yes --output "$dest" --decrypt "$source" || rc=$?
  (( rc == 0 )) || die "gpg failed with status $rc"
  log "decrypted to $dest"

  if [[ "$dest" == *.tar ]] && tar -tf "$dest" >/dev/null 2>&1; then
    log "$dest is a tar archive; unpack it with: tar -xf $(printf '%q' "$dest")"
  fi
}

main() {
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--recipient)
        [[ $# -ge 2 ]] || die "-r requires a recipient"
        RECIPIENTS[${#RECIPIENTS[@]}]="$2"; shift 2 ;;
      --recipient=*) RECIPIENTS[${#RECIPIENTS[@]}]="${1#*=}"; shift ;;
      --symmetric|-c) SYMMETRIC=1; shift ;;
      --armor|-a) ARMOR=1; shift ;;
      --sign|-s) SIGN=1; shift ;;
      --force) FORCE=1; shift ;;
      -o|--output) [[ $# -ge 2 ]] || die "--output requires a path"; OUTPUT="$2"; shift 2 ;;
      --output=*) OUTPUT="${1#*=}"; shift ;;
      help|--help|-h) usage; exit 0 ;;
      -*) tkoc_parse_safety_flag "$1" || die "pgp: unknown option: $1"; shift ;;
      *) rest[${#rest[@]}]="$1"; shift ;;
    esac
  done

  case "${rest[0]:-help}" in
    encrypt|enc|e)
      need_gpg; [[ -n "${rest[1]:-}" ]] || die "encrypt requires a path"
      cmd_encrypt "${rest[1]}" ;;
    decrypt|dec|d)
      need_gpg; [[ -n "${rest[1]:-}" ]] || die "decrypt requires a file"
      cmd_decrypt "${rest[1]}" ;;
    keys) need_gpg; gpg --list-secret-keys --keyid-format=long ;;
    fingerprint)
      need_gpg; [[ -n "${rest[1]:-}" ]] || die "fingerprint requires a key id"
      gpg --fingerprint "${rest[1]}" ;;
    help) usage ;;
    *) die "pgp: unknown subcommand '${rest[0]}'. Run: tkoc pgp help" ;;
  esac
}

main "$@"
