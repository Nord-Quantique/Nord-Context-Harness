#!/bin/bash
# Install Nord Context.
#
#   curl -fsSL https://raw.githubusercontent.com/Nord-Quantique/Nord-Context-Harness/main/install.sh | bash
#
# Run on a machine that has never seen this before. It checks what is missing,
# signs you in to GitHub if you are not already, works out which context stores
# your account can reach, clones them, and installs the reader app.
#
# The stores are cumulative: the leadership store contains everything the
# all-of-Nord store has, plus what is only for leadership. So the app opens the
# most privileged store you hold and there is nothing to choose.
#
# Overridable, for a fork or a second checkout:
#   HARNESS_DIR   where the stores are kept      (~/Nord-Harness)
#   APP_DIR       where the .app is installed    (~/Applications)
#
# Safe to re-run. An existing clone is fast-forwarded, never merged and never
# reset, so anything local — including comments you have left — is left alone.
set -uo pipefail

HARNESS_DIR="${HARNESS_DIR:-$HOME/Nord-Harness}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
APP_NAME="Nord Context.app"
ORG="Nord-Quantique"
HARNESS_REPO="Nord-Context-Harness"     # the app and the runtime, one copy for everyone

# least privileged first; the last one you can reach is the one that opens
STORES=("Nord-Context" "Nord-Context-Leadership")

bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
step() { printf "\n%s▸ %s%s\n" "$bold" "$*" "$off"; }
say()  { printf "    %s\n" "$*"; }
dimm() { printf "    %s%s%s\n" "$dim" "$*" "$off"; }
die()  { printf "\n    %serror:%s %s\n\n" "$bold" "$off" "$*" >&2; exit 1; }

printf "\n%sNord Context%s\n%s  the context stores, on your machine%s\n" \
       "$bold" "$off" "$dim" "$off"

# ---------------------------------------------------------------- what is needed
step "Checking what is here"
[ "$(uname -s)" = "Darwin" ] || die "macOS only — the reader is a .app"
for c in git python3; do
  command -v "$c" >/dev/null || die "$c not found"
  dimm "$c $(command -v $c >/dev/null && echo ✓)"
done
command -v swiftc >/dev/null || die "swiftc not found — run: xcode-select --install"
dimm "swiftc ✓"

if ! command -v gh >/dev/null; then
  say "GitHub CLI not found."
  if command -v brew >/dev/null; then
    step "Installing the GitHub CLI"
    brew install gh || die "could not install gh — install it and re-run"
  else
    die "install the GitHub CLI first: https://cli.github.com"
  fi
fi
dimm "gh ✓"

# ---------------------------------------------------------------- who you are
step "Signing in to GitHub"
if gh auth status >/dev/null 2>&1; then
  who=$(gh api user --jq .login 2>/dev/null || echo "?")
  say "already signed in as $who"
else
  say "A browser will open. Authorise the Nord Quantique organisation."
  say ""
  gh auth login --hostname github.com --git-protocol https --web \
    || die "sign-in did not complete — re-run when you are ready"
  who=$(gh api user --jq .login 2>/dev/null || echo "?")
  say "signed in as $who"
fi

# ---------------------------------------------------------------- what you can read
step "Finding the stores your account can reach"
reachable=()
for s in "${STORES[@]}"; do
  if gh api "repos/$ORG/$s" --silent >/dev/null 2>&1; then
    say "$s  ✓"
    reachable+=("$s")
  else
    dimm "$s  — no access"
  fi
done
[ ${#reachable[@]} -gt 0 ] || die "your account cannot reach any context store yet.
    Ask whoever set this up to add you, then re-run."

# ---------------------------------------------------------------- fetch
mkdir -p "$HARNESS_DIR"
step "Fetching into $HARNESS_DIR"
for s in "${reachable[@]}"; do
  dir="$HARNESS_DIR/$s"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --quiet origin 2>/dev/null || { say "$s — cannot reach the remote, keeping what is here"; continue; }
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      say "$s — local changes, left alone"
    elif git -C "$dir" merge --ff-only '@{u}' --quiet 2>/dev/null; then
      say "$s — updated"
    else
      say "$s — cannot fast-forward, left as it is"
    fi
  else
    gh repo clone "$ORG/$s" "$dir" -- --quiet 2>/dev/null \
      || die "could not clone $s"
    say "$s — cloned"
  fi
done

# the most privileged store you hold is the last reachable one
STORE="${reachable[${#reachable[@]}-1]}"
STORE_DIR="$HARNESS_DIR/$STORE"
[ -f "$STORE_DIR/index.html" ] || die "$STORE_DIR does not look like a context store"

# ---------------------------------------------------------------- the harness
# The app and the runtime are the same for everyone, so they come from here rather
# than being duplicated into every store.
step "Fetching the app and runtime"
H_DIR="$HARNESS_DIR/$HARNESS_REPO"
if [ -d "$H_DIR/.git" ]; then
  git -C "$H_DIR" fetch --quiet origin 2>/dev/null && \
    git -C "$H_DIR" merge --ff-only '@{u}' --quiet 2>/dev/null
  say "$HARNESS_REPO — updated"
else
  gh repo clone "$ORG/$HARNESS_REPO" "$H_DIR" -- --quiet 2>/dev/null \
    || die "could not clone $HARNESS_REPO"
  say "$HARNESS_REPO — cloned"
fi
[ -f "$H_DIR/runtime/server.py" ] || die "$HARNESS_REPO has no runtime/server.py"
[ -f "$H_DIR/app/build.sh" ]      || die "$HARNESS_REPO has no app/build.sh"

# ---------------------------------------------------------------- build and install
step "Building the reader"
bash "$H_DIR/app/build.sh" "$STORE_DIR" "$H_DIR/runtime" >/dev/null 2>&1 \
  || die "build failed — run: bash $H_DIR/app/build.sh $STORE_DIR $H_DIR/runtime"
say "built against $STORE"

mkdir -p "$APP_DIR"
if [ -d "$APP_DIR/$APP_NAME" ]; then
  osascript -e 'tell application "Nord Context" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$APP_DIR/$APP_NAME"
fi
cp -R "$H_DIR/app/build/$APP_NAME" "$APP_DIR/" || die "could not install the app"
say "installed to $APP_DIR/$APP_NAME"

# ---------------------------------------------------------------- go
step "Opening"
open "$APP_DIR/$APP_NAME"
printf "\n"
say "Reading      $STORE"
say "Stores       $HARNESS_DIR"
say "App+runtime  $H_DIR"
say "In a browser http://localhost:8137/   (the reader port)"
printf "\n    %sIt is in the menu bar. Press ⌘K on any page to leave a comment.%s\n\n" "$dim" "$off"
