#!/usr/bin/env bash
# Assemble the manual from src/ fragments and render to PDF with headless Brave.
set -euo pipefail
cd "$(dirname "$0")"

OUT_HTML="macos-apfs-forensics-parrot.html"
OUT_PDF="macos-apfs-forensics-parrot.pdf"
BRAVE="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"

cat src/*.html > "$OUT_HTML"
printf '\n</div>\n</body>\n</html>\n' >> "$OUT_HTML"

"$BRAVE" --headless --disable-gpu \
  --no-pdf-header-footer \
  --generate-pdf-document-outline \
  --print-to-pdf="$OUT_PDF" \
  "file://$(pwd)/$OUT_HTML" 2>&1 | grep -Ei 'written|error' || true

python3 - "$OUT_PDF" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
pages = len(re.findall(rb'/Type\s*/Page[^s]', d))
print(f"{sys.argv[1]}: {len(d)/1048576:.2f} MB, ~{pages} pages")
PY
