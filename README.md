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

## Two builds, one source

The launcher is built in one of two modes. The mode is fixed at compile time, so
an installed app is one thing and cannot be switched at runtime.

| | reader | admin |
|---|---|---|
| who runs it | anyone at Nord | whoever authors the context |
| store | a published store, cloned from GitHub | a local working bundle |
| port | 8137 | 8136 |
| writes | comments, and pages made locally | everything |
| app | `Nord Context.app` | `Nord Context Admin.app` |
| bundle id | `ca.nordquantique.context` | `…context.admin` |

Different bundle identifiers, pidfiles and logs, so both can be installed and
running at once without contending for a port or a menu bar item.

**Reader** — defined by `install.sh`, the one-liner at the top of this file. It
passes no mode, and `reader` is the default.

**Admin** — defined by `app/install-admin.sh`. There is nothing to clone, so it
names the store instead of discovering it:

```bash
cd <your working bundle> && bash app/install-admin.sh
# or
bash app/install-admin.sh /path/to/working/bundle
```

Underneath both is one script:

```bash
app/build.sh <store-dir> [runtime-dir] [reader|admin]
```

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
