#!/usr/bin/env bash
# 99-postcheck.sh -- thin wrapper. The real logic lives in tools/postcheck.sh.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/../tools/postcheck.sh" "$@"
