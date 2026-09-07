#!/usr/bin/env bash
set -euo pipefail

VERSION="v2.2"
OUT="AKTune-${VERSION}.zip"

chmod 0755 ./*.sh 2>/dev/null || true
chmod 0755 ./common/*.sh 2>/dev/null || true
chmod 0755 ./tweaks/*.sh 2>/dev/null || true

rm -f "$OUT"

zip -r9 "$OUT" . \
  -x "*.git*" \
  -x "*.zip" \
  -x ".github/*" \
  -x "build.sh" \
  -x "changelog.txt" \
  -x "README.md" \
  -x "LICENSE" \
  -x "tests/*" \
  -x "docs/*" \
  -x "*.bak*"
