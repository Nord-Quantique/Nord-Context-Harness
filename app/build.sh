#!/bin/bash
# Build Nord Context.app — the V1 launcher.
#
# No dependencies beyond the Swift toolchain that ships with the Xcode command
# line tools. The bundle path is compiled in as a default and can be changed
# later from the app's own menu, so the .app can be moved anywhere afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# The app lives in the harness repository now, not inside a store, so the store
# has to be named rather than inferred from where this script sits.
#   build.sh <store-dir> [runtime-dir]
REPO="${1:-}"
RUNTIME="${2:-$(cd "$HERE/../runtime" 2>/dev/null && pwd)}"
if [ -z "$REPO" ]; then
  echo "usage: build.sh <store-dir> [runtime-dir]" >&2
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
OUT="$HERE/build"
APP="$OUT/Nord Context.app"

if [ ! -f "$REPO/index.html" ]; then
  echo "error: $REPO has no index.html — is that a context store?" >&2
  exit 1
fi
if [ ! -f "$RUNTIME/server.py" ]; then
  echo "error: no server.py in $RUNTIME — pass the runtime directory as arg 2" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# the one value that has to be known at compile time
SRC="$OUT/NordContext.gen.swift"
python3 - "$HERE/NordContext.swift" "$SRC" "$REPO" "$RUNTIME" <<'PY'
import sys, json
src, dst, repo, runtime = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
s = s.replace("COMPILED_REPO_PATH", json.dumps(repo), 1)
s = s.replace("COMPILED_RUNTIME_PATH", json.dumps(runtime), 1)
open(dst, "w", encoding="utf-8").write(s)
PY

# ---- app icon, if the 1024 render is present
ICON_SRC="$HERE/icon/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
  ISET="$OUT/AppIcon.iconset"
  mkdir -p "$ISET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz        "$ICON_SRC" --out "$ISET/icon_${sz}x${sz}.png"      >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ISET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  cp "$ICON_SRC" "$ISET/icon_512x512@2x.png"
  iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ISET"
  echo "icon built"
fi

echo "compiling…"
swiftc -swift-version 5 -O \
  -o "$APP/Contents/MacOS/NordContext" \
  "$SRC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nord Context</string>
  <key>CFBundleDisplayName</key><string>Nord Context</string>
  <key>CFBundleIdentifier</key><string>ca.nordquantique.context</string>
  <key>CFBundleExecutable</key><string>NordContext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <!-- Dock icon AND menu bar item. It still opens no window; clicking the Dock
       icon reopens the site, which is what makes that sensible. -->
</dict>
</plist>
PLIST

# ad-hoc signature, so Gatekeeper treats it as a local build rather than
# an unidentified download
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (unsigned — fine for local use)"

echo "built: $APP"
echo "bundle: $REPO"
