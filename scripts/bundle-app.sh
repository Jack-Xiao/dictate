#!/bin/bash
# Build dictate and wrap it as Dictate.app so TCC permissions stick to a stable bundle id.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

if [[ "$CONFIG" == "debug" ]]; then
  swift build --package-path "$ROOT"
  BIN="$ROOT/.build/debug/dictate"
else
  swift build -c release --package-path "$ROOT"
  BIN="$ROOT/.build/release/dictate"
fi

APP="$ROOT/Dictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/dictate"
chmod +x "$APP/Contents/MacOS/dictate"
# Keep a stable bundle id so TCC permissions survive rebuilds.
codesign --force --sign - --identifier com.xiaojiang.dictate --timestamp=none "$APP" >/dev/null
echo "built $APP"
