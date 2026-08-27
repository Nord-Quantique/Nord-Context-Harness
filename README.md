# Nord Context — installer

Installs the Nord Context reader on a Mac. One line, on a machine that has never
seen it before:

```bash
curl -fsSL https://raw.githubusercontent.com/Nord-Quantique/Nord-Context-Harness/main/install.sh | bash
```

It checks what is missing, signs you in to GitHub if you are not already, works
out which context stores your account can reach, clones them into
`~/Nord-Harness/`, and installs the reader.

The stores are private. Access is decided by GitHub organisation membership, so
if the installer finds none, your account has not been added yet.

## What you need

macOS, `git`, `python3`, and the Swift toolchain (`xcode-select --install`). The
GitHub CLI is installed for you if Homebrew is present.

## What it does with what it finds

The stores are cumulative — a narrower store contains everything a broader one
has, plus what is only for that audience. The installer opens the most
privileged store you hold, so there is nothing to choose.

Re-running is safe. An existing clone is fast-forwarded, never merged and never
reset: anything local, including comments you have left, stays.

## Reading

The reader runs a local server and opens a browser. Nothing leaves your machine.
Press <kbd>⌘K</kbd> on any page and click a block to leave a comment.

## Overrides

```bash
HARNESS_DIR=~/somewhere APP_DIR=~/Applications bash install.sh
```
