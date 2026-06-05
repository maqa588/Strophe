#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${1:-$ROOT_DIR/build/Strophe-macOS-arm64.xcarchive}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$ROOT_DIR/Strophe.xcodeproj" \
  -scheme Strophe \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES
