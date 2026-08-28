# Nord Context

A small app that keeps a documentation store current on your machine and serves
it to your browser. It appears in the Dock and in the menu bar.

The thing it is really for is **staying current**. The content is generated
elsewhere and published to a repository; this keeps your copy level with it,
quietly, without anyone having to think about git.

## Keeping the content current

It checks a few seconds after launch and every five minutes after that. There is
nothing to press.

Two branches, and the app moves between them:

| | |
|---|---|
| **`main`** | the published content, held at exactly what was published |
| **`local`** | anything you edited here, carried on its own branch |

`main` is a mirror, so it is **set** to the published copy rather than merged
with it. That is what makes updates seamless: there is never a conflict to
resolve, because your side of a conflict is never on this branch.

**Your edits are not discarded and not merged.** The first time you change
something, that change moves onto `local`, `main` is brought level with what was
published, and the menu offers *Switch to My Changes*. You can move between the
two whenever you like:

```
Switch to Latest Content   ← what everyone else is reading
Switch to My Changes       ← what you edited, kept intact
```

| It finds | It does |
|---|---|
| Nothing new | says *Latest content* |
| New content, nothing edited here | brings you level, silently |
| New content, and you have edited | moves your edits to `local`, then brings `main` level |
| You are reading `local` | leaves it alone, says how far the published copy has moved |
| Remote unreachable | says so, keeps serving the copy you have |
| It is the **authoring** copy | reports what is new and changes nothing |

### The machine content is written on

A store carries the reading runtime only. A copy that also has the authoring
layer (`_edit/shim.js`) is where content is *made*, and parking its work on a
branch or resetting it to the published copy would be reaching into someone's
desk. Such a copy is reported on and never modified — the sync is read-only
there.

Git runs with `GIT_TERMINAL_PROMPT=0` and `ssh -o BatchMode=yes`, so a missing
credential fails in seconds rather than hanging on a prompt nobody can see.

### What is never touched

Comments and anything else made on your machine sit **outside git** — a store
ships a `.gitignore` naming them. No pull, reset or branch change can reach
them, so a comment written this morning is still there after an update.

```
_edit/comments.json      your comments
_edit/stamps.json        local page dates
```

## What it does otherwise

On launch it starts `python3 _edit/server.py --port 8137 --reader` with the store as its
working directory, waits for the port to answer, and opens the index. Clicking
the Dock icon reopens the site — the app shows no window of its own, so without
that a click would appear to do nothing.

| Menu | |
|---|---|
| **Open Context** | opens `localhost:8137` |
| **Check for Content Now** | the same check that runs on its own |
| **Switch to Latest Content / My Changes** | appears when there is something to switch to |
| **Start / Restart Server** | label follows the current state |
| **Reveal Store in Finder** | when someone needs the files themselves |
| **Open Server Log** | the child's output, for troubleshooting |
| **Choose Store Folder…** | point it at a different checkout |
| **Quit** | stops the server it started |

A dot shows whether the server is answering, re-checked every five seconds.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Nord-Quantique/context-installer/main/install.sh | bash
```

Or from a checkout, `./app/build.sh`. It needs only the Swift toolchain from the
Xcode command line tools — no packages, no Electron, no runtime dependencies.

## The three ways it can end

The middle one is the one that bites:

- **Quit, or SIGTERM** — the server stops with the app.
- **Force quit** — SIGKILL cannot be caught, so the server outlives the app. The
  next launch finds it through a PID file and clears it, so you get one server
  rather than two.
- **A server already running** — if something is answering on the port already,
  the app uses it rather than starting a competitor.

## Updating the app itself

Secondary, and deliberately so — the content moves daily, the launcher rarely.

If a pull brings a newer `NordContext.swift` than the binary running, a **Rebuild
Launcher** item appears at the bottom of the menu. It runs `build.sh` and hands
off to a detached shell that waits for the process to exit before reopening, since
an app cannot replace itself in place. There is no signed release channel, so
"update" means rebuild from the source you already have.

## The icon

`app/icon/icon.html` is the source. `build.sh` renders it at 1024px with headless
Chrome, then `sips` and `iconutil` produce `AppIcon.icns`. Edit the SVG and
rebuild; there is no binary asset to keep in step.
