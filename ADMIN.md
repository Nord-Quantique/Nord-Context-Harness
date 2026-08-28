# Nord Context — authoring

This is the other half of the installer, and it is not what most people want. If
you are here to *read* the context, use the one-liner in [README.md](README.md)
and stop.

Authoring means the documents are generated on your own machine and only what is
generated there becomes a published store. The admin app serves that working
bundle directly, so what you see is the ground truth rather than a copy of it.

## The two builds

The launcher is compiled in one of two modes. The mode is fixed at build time, so
an installed app is one thing and cannot be switched at runtime.

| | reader | admin |
|---|---|---|
| who runs it | anyone at Nord | whoever authors the context |
| store | a published store, cloned from GitHub | a local working bundle |
| port | 8137 | 8136 |
| writes | comments, and pages made locally | everything |
| app | `Nord Context.app` | `Nord Context Admin.app` |
| bundle id | `ca.nordquantique.context` | `ca.nordquantique.context.admin` |

Different bundle identifiers, pidfiles and logs, so both can be installed and
running at once without contending for a port or a menu bar item. Sharing any of
those three is how one app silently kills the other's server.

## Installing the admin app

There is nothing to clone: the store is wherever documents are authored, so it is
named rather than discovered.

```bash
cd <your working bundle> && bash app/install-admin.sh
```

Or name it explicitly:

```bash
bash app/install-admin.sh /path/to/working/bundle
```

It refuses to build against a directory with no `index.html`, rather than
producing an app pointed at nothing.

## Underneath

Both installers call one script:

```bash
app/build.sh <store-dir> [runtime-dir] [reader|admin]
```

`reader` is the default, which is why `install.sh` passes no mode. Output goes to
`app/build/<mode>/` so the two builds never overwrite each other.

## Telling them apart while running

- the menu bar header reads **Nord Context** or **Nord Context — Admin**
- the toolbar in the page carries a blue **READER** or amber **ADMIN** badge, with
  the store and port in its tooltip
- `GET /_mode` on either port answers `{mode, store, path, port}`

Amber for admin deliberately: that is the one where an edit is real.
