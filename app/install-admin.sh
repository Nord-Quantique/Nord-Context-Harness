#!/bin/bash
# Install Nord Context Admin — the authoring half.
#
#   cd <your working bundle> && bash install-admin.sh
#   bash install-admin.sh /path/to/working/bundle
#
# The reader is installed by install.sh: it clones the published stores from
# GitHub, and anyone at Nord runs it. This is the other half, and it is
# deliberately a separate script because nothing about it is the same job:
#
#   reader   many people   store cloned from GitHub   read-only   port 8137
#   admin    one person    store is a local checkout  editable    port 8136
#
# There is nothing to clone. The store is wherever documents are authored, so it
# is named here rather than discovered, and the two apps carry different bundle
# identifiers so both can be installed at once.
#
# Overridable:
#   RUNTIME_DIR   where server.py lives   (this repository's runtime/)
#   APP_DIR       where the .app goes     (~/Applications)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STORE="${1:-$PWD}"
RUNTIME_DIR="${RUNTIME_DIR:-$(cd "$HERE/../runtime" 2>/dev/null && pwd || true)}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
APP_NAME="Nord Context Admin.app"

bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
step() { printf "\n%s▸ %s%s\n" "$bold" "$*" "$off"; }
say()  { printf "    %s\n" "$*"; }
die()  { printf "\n    %serror:%s %s\n\n" "$bold" "$off" "$*" >&2; exit 1; }

printf "\n%sNord Context Admin%s\n%s  the authoring half, on the working bundle%s\n" \
       "$bold" "$off" "$dim" "$off"

step "Checking"
[ "$(uname -s)" = "Darwin" ] || die "macOS only"
command -v python3 >/dev/null || die "python3 not found"
command -v swiftc  >/dev/null || die "swiftc not found — run: xcode-select --install"

STORE="$(cd "$STORE" 2>/dev/null && pwd || true)"
[ -n "$STORE" ] && [ -f "$STORE/index.html" ] \
  || die "no index.html in ${1:-$PWD}.
    Run this from inside the working bundle, or name it:
      bash install-admin.sh /path/to/bundle"
[ -n "$RUNTIME_DIR" ] && [ -f "$RUNTIME_DIR/server.py" ] \
  || die "no server.py found — set RUNTIME_DIR to the harness runtime/"
say "store   $STORE"
say "runtime $RUNTIME_DIR"

step "Building"
bash "$HERE/build.sh" "$STORE" "$RUNTIME_DIR" admin >/dev/null 2>&1 \
  || die "build failed — run: bash $HERE/build.sh \"$STORE\" \"$RUNTIME_DIR\" admin"
say "built"

step "Installing"
mkdir -p "$APP_DIR"
if [ -d "$APP_DIR/$APP_NAME" ]; then
  osascript -e 'tell application "Nord Context Admin" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$APP_DIR/$APP_NAME"
fi
cp -R "$HERE/build/admin/$APP_NAME" "$APP_DIR/" || die "could not install"
say "installed to $APP_DIR/$APP_NAME"

step "Opening"
open "$APP_DIR/$APP_NAME"
printf "\n"
say "Authoring    $STORE"
say "In a browser http://localhost:8136/   (the admin port)"
printf "\n    %sThe reader, if installed, keeps 8137. Both can run at once.%s\n\n" "$dim" "$off"
