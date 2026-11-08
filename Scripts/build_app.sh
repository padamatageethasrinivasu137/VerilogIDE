#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="VerilogIDE.xcodeproj"
SCHEME="VerilogIDE"
DERIVED="$ROOT/build/DerivedData"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SOURCE="$DERIVED/Build/Products/Release/VerilogIDE.app"
APP_DEST="$ROOT/build/VerilogIDE.app"
mkdir -p "$ROOT/build"
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"
echo "Built: $APP_DEST"
