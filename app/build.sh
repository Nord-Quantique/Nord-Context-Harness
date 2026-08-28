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
MODE="${3:-reader}"
if [ -z "$REPO" ]; then
  echo "usage: build.sh <store-dir> [runtime-dir] [reader|admin]" >&2
  exit 1
fi
case "$MODE" in
  reader) NAME="Nord Context";       BUNDLE_ID="ca.nordquantique.context";       IS_READER="true"  ;;
  admin)  NAME="Nord Context Admin"; BUNDLE_ID="ca.nordquantique.context.admin"; IS_READER="false" ;;
  *) echo "error: mode must be reader or admin, not $MODE" >&2; exit 1 ;;
esac
REPO="$(cd "$REPO" && pwd)"
# Both paths are compiled into the app, so a relative one bakes in a path that is
# meaningless from wherever the app later runs.
RUNTIME="$(cd "$RUNTIME" 2>/dev/null && pwd || echo "$RUNTIME")"
# Two modes, two apps: a distinct bundle id keeps their preferences and menu bar
# items apart, so an admin build and a reader build coexist without interfering.
OUT="$HERE/build/$MODE"
APP="$OUT/$NAME.app"

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
python3 - "$HERE/NordContext.swift" "$SRC" "$REPO" "$RUNTIME" "$IS_READER" <<'PY'
import sys, json
src, dst, repo, runtime, is_reader = sys.argv[1:6]
s = open(src, encoding="utf-8").read()
s = s.replace("COMPILED_REPO_PATH", json.dumps(repo), 1)
s = s.replace("COMPILED_RUNTIME_PATH", json.dumps(runtime), 1)
s = s.replace("COMPILED_IS_READER", is_reader, 1)
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
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
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
