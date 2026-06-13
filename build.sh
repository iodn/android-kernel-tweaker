#!/usr/bin/env bash
set -euo pipefail

VERSION="v2.1"
OUT="AKTune-${VERSION}.zip"

chmod 0755 ./*.sh 2>/dev/null || true
chmod 0755 ./common/*.sh 2>/dev/null || true
chmod 0755 ./tweaks/*.sh 2>/dev/null || true

rm -f ./*.zip

zip -r9 "$OUT" . \
  -x "*.git*" \
  -x ".github/*" \
  -x "build.sh" \
  -x "changelog.txt" \
  -x "README.md" \
  -x "LICENSE" \
  -x "*.bak*"
