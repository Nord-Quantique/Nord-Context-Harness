#!/usr/bin/env python3
"""Edit-mode server for the Nord HTML bundle.

Serves the bundle on localhost, injects _edit/shim.js into every HTML page, and
accepts text-only edits back. Source files on disk keep their original
formatting: each change is applied as a surgical string replacement, never as a
DOM re-serialisation.

    python3 _edit/server.py [--port 8137] [--no-render]
"""
from __future__ import annotations

import argparse
import html as htmllib
import json
import re
import shutil
import subprocess
import sys
import threading
from datetime import datetime
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# The runtime lives in its own repository now, so it can no longer infer the store
# from its own location. RUNTIME is where this file and shim.js sit; ROOT is the
# store being served, given by --store and defaulting to the working directory.
RUNTIME = Path(__file__).resolve().parent
ROOT = Path.cwd()
READER = False        # --reader; gates the write endpoints and the shim UI
PORT_IN_USE = 0       # filled in at startup; reported to the page and /_mode


def locally_made(page: str) -> bool:
    """True if this page was made here rather than arriving in the store.

    A reader may change what they built and nothing else. "Built here" means git
    does not track it: everything that came down with the clone is tracked, so
    anything untracked was created on this machine. Fails closed — if the answer
    cannot be established, the page counts as not theirs.
    """
    if not page:
        return False
    try:
        r = subprocess.run(["git", "ls-files", "--error-unmatch", page],
                           cwd=ROOT, capture_output=True, timeout=5)
        return r.returncode != 0          # not tracked -> made here
    except Exception:
        return False
BACKUPS = ROOT / "_edit" / "versions"
COMMENTS = ROOT / "_edit" / "comments.json"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
ENTITIES = {"—": "&mdash;", "–": "&ndash;", "’": "&rsquo;",
            "‘": "&lsquo;", "“": "&ldquo;", "”": "&rdquo;"}
ENTITY_RE = re.compile(r"&(#\d+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")
RENDER = True


# ---------------------------------------------------------------- entity map
def decode_with_map(src: str) -> tuple[str, list[int]]:
    """Return src with entities decoded, plus decoded-index -> source-index map."""
    out: list[str] = []
    idx: list[int] = []
    i = 0
    while i < len(src):
        m = ENTITY_RE.match(src, i)
        if m:
            for ch in htmllib.unescape(m.group(0)):
                out.append(ch)
                idx.append(i)
            i = m.end()
        else:
            out.append(src[i])
            idx.append(i)
            i += 1
    idx.append(len(src))
    return "".join(out), idx


def reencode(text: str) -> str:
    for ch, ent in ENTITIES.items():
        text = text.replace(ch, ent)
    return text


def apply_changes(src: str, changes: list[dict]) -> tuple[str, list[int], list[dict]]:
    """Apply each change to src by locating its Nth decoded occurrence."""
    applied, failed = [], []
    # Work back-to-front so earlier spans keep their offsets.
    ordered = sorted(enumerate(changes), key=lambda kv: -len(kv[1]["old"]))
    edits = []
    for pos, ch in ordered:
        def _plain(v: str) -> str:
            return re.sub(r"<[^>]*>", "", v or "").replace("&nbsp;", " ").strip()
        if _plain(ch["old"]) and not _plain(ch["now"]):
            failed.append({"index": pos, "reason": "refused: would blank a non-empty block"})
            continue
        old_dec = htmllib.unescape(ch["old"]).strip()
        old_dec = re.sub(r"\s+", " ", old_dec)
        decoded, imap = decode_with_map(src)
        flat = re.sub(r"\s+", " ", decoded)
        # index map from flattened -> decoded
        fmap, j = [], 0
        prev_ws = False
        for k, c in enumerate(decoded):
            if c.isspace():
                if prev_ws:
                    continue
                prev_ws = True
            else:
                prev_ws = False
            fmap.append(k)
        hits = [m.start() for m in re.finditer(re.escape(old_dec), flat)]
        if ch["occurrence"] >= len(hits):
            failed.append({"index": pos, "reason": f"found {len(hits)} match(es) in file, needed #{ch['occurrence'] + 1}"})
            continue
        f_start = hits[ch["occurrence"]]
        f_end = f_start + len(old_dec)
        d_start = fmap[f_start]
        d_end = fmap[f_end - 1] + 1
        edits.append((imap[d_start], imap[d_end], reencode(ch["now"]), pos))
    for start, end, new, pos in sorted(edits, key=lambda e: -e[0]):
        src = src[:start] + new + src[end:]
        applied.append(pos)
    return src, sorted(applied), failed


# ---------------------------------------------------------------- comments
def load_comments() -> list[dict]:
    if not COMMENTS.exists():
        return []
    try:
        return json.loads(COMMENTS.read_text(encoding="utf-8"))
    except Exception:
        return []


def store_comments(items: list[dict]) -> None:
    COMMENTS.write_text(json.dumps(items, indent=2, ensure_ascii=False), encoding="utf-8")


def comments_page(items: list[dict]) -> bytes:
    by: dict[str, list[dict]] = {}
    for c in items:
        by.setdefault(c.get("page", "?"), []).append(c)
    rows = []
    for page in sorted(by):
        open_n = sum(1 for c in by[page] if c.get("status") == "open")
        rows.append(f'<h2>{htmllib.escape(page)} <span class="c">{open_n} open / {len(by[page])}</span></h2>')
        for c in sorted(by[page], key=lambda x: x.get("created", "")):
            quoted = c.get("selection") or c.get("text") or ""
            cls = "done" if c.get("status") != "open" else ""
            rows.append(
                f'<div class="cm {cls}"><div class="q">{htmllib.escape(quoted[:300])}</div>'
                f'<div class="b">{htmllib.escape(c.get("comment",""))}</div>'
                f'<div class="m">{htmllib.escape(c.get("created",""))} &middot; '
                f'{htmllib.escape(c.get("status","open"))} &middot; '
                f'<code>{htmllib.escape((c.get("target") or {}).get("classes") or "")}</code></div></div>')
    body = "\n".join(rows) or "<p class=e>No comments yet.</p>"
    return (f"""<!doctype html><meta charset=utf-8><title>Comments ({len(items)})</title><style>
body{{font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
max-width:900px;margin:0 auto;padding:32px 20px 80px;color:#16283d;background:#f7f8fa}}
h1{{font-size:25px;color:#12376b}}h2{{font-size:14px;text-transform:uppercase;letter-spacing:.07em;
color:#6b7d8f;margin:30px 0 10px;border-top:1px solid #dde3ea;padding-top:9px}}
h2 .c{{float:right;text-transform:none;letter-spacing:0;font-weight:600}}
.cm{{background:#fff;border:1px solid #dbe3ec;border-left:3px solid #c07d16;border-radius:8px;
padding:11px 14px;margin-bottom:9px}}.cm.done{{border-left-color:#7fbf7f;opacity:.6}}
.q{{font-size:12.6px;color:#6b7d8f;font-style:italic;border-left:2px solid #e0e5eb;padding-left:9px;margin-bottom:6px}}
.b{{font-size:14.4px;font-weight:600}}.m{{font-size:11.4px;color:#8b98a6;margin-top:6px}}
code{{background:#eef1f5;padding:1px 5px;border-radius:4px;font-size:11px}}.e{{color:#8b98a6}}
</style><h1>Comments</h1>{body}""").encode("utf-8")


def structure(text: str) -> tuple:
    """Counts a text-only edit must never change."""
    return (text.count("<div"), text.count("</div>"), text.count("class="),
            text.count("<style"), text.count("<script"), text.count("<svg"))


# ---------------------------------------------------------------- rendering
def render_png(page: Path) -> bool:
    png = page.with_suffix(".png")
    if not png.exists() or not CHROME.exists():
        return False
    try:
        subprocess.run(
            [str(CHROME), "--headless", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=2", "--window-size=1660,950",
             "--virtual-time-budget=2500", f"--screenshot={png}", page.as_uri()],
            capture_output=True, timeout=90, check=False)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------- handler
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT), **kw)

    def log_message(self, fmt, *args):
        # args[0] is the request line for a normal log, but an HTTPStatus when the
        # base class reports an error — so coerce before testing membership. A HEAD
        # probe against / was enough to raise TypeError here on every poll.
        first = str(args[0]) if args else ""
        if "_save" in first:
            sys.stderr.write("  %s\n" % (fmt % args))

    def _safe(self, rel: str) -> Path | None:
        try:
            p = (ROOT / rel).resolve()
        except Exception:
            return None
        return p if ROOT in p.parents and p.suffix == ".html" and p.is_file() else None

    def send_head(self):
        # shim.js is runtime now, not content: it does not live under the store.
        # send_head must return a readable, so hand back the bytes rather than
        # writing them here.
        if self.path.split("?")[0] == "/_edit/shim.js":
            f = RUNTIME / "shim.js"
            if not f.is_file():
                self.send_error(404)
                return None
            raw = f.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            import io
            return io.BytesIO(raw)

        """Inject the shim into HTML responses."""
        if self.path.split("?")[0] == "/_mode":
            return self._json({"ok": True, "mode": "reader" if READER else "admin",
                               "store": ROOT.name, "path": str(ROOT), "port": PORT_IN_USE})

        if self.path.startswith("/_meta"):
            # everything the page-level bar needs in one call: the audience groups,
            # this page's group, and its tags
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            page = (q.get("page") or [""])[0]
            A = ROOT / "_edit" / "audience.json"
            T = ROOT / "_edit" / "tags.json"
            aud = json.loads(A.read_text(encoding="utf-8")) if A.exists() else {"groups": {}, "pages": {}}
            tg = json.loads(T.read_text(encoding="utf-8")) if T.exists() else {"labels": {}, "pages": {}}
            group = aud.get("pages", {}).get(page, "private")
            if group not in aud.get("groups", {}):
                group = "private"
            return self._json({"ok": True,
                               "page": page,
                               "groups": aud.get("groups", {}),
                               "group": group,
                               "labels": tg.get("labels", {}),
                               "tags": sorted(tg.get("pages", {}).get(page, []))})

        if self.path.startswith("/_mtime"):
            import io
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(self.path).query)
            page = self._safe((q.get("file") or [""])[0])
            out = {"html": 0, "png": 0}
            if page:
                out["html"] = int(page.stat().st_mtime * 1000)
                png = page.with_suffix(".png")
                out["png"] = int(png.stat().st_mtime * 1000) if png.exists() else 0
            raw = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return io.BytesIO(raw)
        if self.path.split("?")[0] == "/_regen.status":
            return self._regen_status()

        if self.path.split("?")[0] in ("/_comments.json", "/_comments.html"):
            import io
            items = load_comments()
            if self.path.startswith("/_comments.json"):
                raw = json.dumps(items, ensure_ascii=False).encode("utf-8")
                ctype = "application/json"
            else:
                raw = comments_page(items)
                ctype = "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return io.BytesIO(raw)
        path = self.translate_path(self.path)
        p = Path(path)
        if p.is_dir():
            p = p / "index.html"
        if p.suffix != ".html" or not p.is_file():
            resp = super().send_head()
            return resp
        body = p.read_text(encoding="utf-8")
        # A published store ships the reading runtime but not the authoring one.
        # Injecting the tag anyway gives every reader a 404 per page load. Skip the
        # injection rather than returning early: send_head() must hand back a
        # file-like object, and a str here makes do_HEAD fail on f.close().
        if (RUNTIME / "shim.js").exists():
            tag = '<script src="/_edit/shim.js"></script>'
            body = body.replace("</body>", tag + "\n</body>", 1) if "</body>" in body else body + tag
        # Before any page script: index.html reads this in its own inline script,
        # which is parsed long before the shim tag at </body>.
        decl = ("<script>window.__NQ_MODE=" + json.dumps({
            "mode": "reader" if READER else "admin",
            "store": ROOT.name,
            "port": PORT_IN_USE,
        }) + (";window.__NQ_READER=1" if READER else "") + "</script>")
        body = re.sub(r"<head[^>]*>", lambda m: m.group(0) + decl, body, count=1)

        def stamp(m):
            asset = ROOT / "_edit" / m.group(1)
            v = int(asset.stat().st_mtime) if asset.exists() else 0
            return f'src="{m.group(0).split(chr(34))[1].split("?")[0]}?v={v}"'
        body = re.sub(r'src="/?_edit/([A-Za-z0-9_.-]+\.js)(?:\?[^"]*)?"', stamp, body)
        raw = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        import io
        return io.BytesIO(raw)

    def end_headers(self):
        if self.path.startswith("/_edit/"):
            self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    # In reader mode a comment is always allowed. Editing or tagging is allowed to
    # reach its handler, which refuses unless the page was made here — see
    # locally_made(). Audience is a publishing decision and a reader publishes
    # nothing, so it is refused outright, along with everything that is not
    # per-page and no business of a reader.
    READER_ALLOWED_POST = {"/_comments", "/_save", "/_tags"}

    def do_POST(self):
        if READER and self.path.split("?")[0] not in self.READER_ALLOWED_POST:
            return self._json({"ok": False, "error": "reader mode: this bundle is read-only"}, code=403)

        if self.path.split("?")[0] == "/_regen.status":
            return self._regen_status()

        if self.path == "/_regen":
            return self._regen()

        if self.path == "/_comments":
            return self._comments()
        if self.path == "/_save":
            return self._save_page()
        if self.path == "/_render":
            return self._render()
        if self.path == "/_tags":
            return self._tags()
        if self.path == "/_audience":
            return self._audience()
        self.send_error(404)

    def _regen_status(self):
        """What the page needs to tell the reader what is going on: whether anything
        is watching, whether a run is in flight, and the tail of its output."""
        import time as _t
        E = ROOT / "_edit"
        beat = E / "regen.heartbeat"
        lock = E / "regen.lock"
        alive, every = False, 30
        if beat.exists():
            try:
                ts, every = beat.read_text(encoding="utf-8").split()
                alive = (_t.time() - float(ts)) < (float(every) * 3)
            except Exception:
                pass
        # A run blocks the poll loop, so the heartbeat goes stale for exactly as
        # long as the work takes. A held lock is the other proof of life, and
        # without it the panel reports "not watching" while it is busiest.
        running = False
        if lock.exists():
            try:
                import os as _os
                _os.kill(int(lock.read_text(encoding="utf-8").strip().split()[0]), 0)
                running = alive = True
            except Exception:
                running = False
        cmts = json.loads((E / "comments.json").read_text(encoding="utf-8")) if (E / "comments.json").exists() else []
        res = {}
        rp = E / "regen.result.json"
        if rp.exists():
            try:
                res = json.loads(rp.read_text(encoding="utf-8"))
            except Exception:
                res = {}
        by_page = {}
        for c in cmts:
            if c.get("status") == "open":
                by_page[c.get("page", "?")] = by_page.get(c.get("page", "?"), 0) + 1
        st = {
            "result": res,
            "pending": [{"page": k, "comments": v} for k, v in sorted(by_page.items())],
            "watching": alive,
            "every": int(float(every)),
            "requested": (E / "regen.flag").exists(),
            "running": running,
            "open": sum(1 for c in cmts if c.get("status") == "open"),
        }
        body = json.dumps(st).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _regen(self):
        """Set the flag _edit/watch.py polls for. Deliberately just a file: the
        server does not run anything, so a stuck or absent watcher cannot leave a
        half-applied edit behind."""
        (ROOT / "_edit" / "regen.flag").write_text(
            __import__("datetime").datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            encoding="utf-8")
        body = __import__("json").dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _comments(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            act = req.get("action")
            items = load_comments()
            if act == "add":
                cid = f"c{int(datetime.now().timestamp() * 1000)}"
                items.append({
                    "id": cid,
                    "page": req.get("page", ""),
                    "created": datetime.now().strftime("%Y-%m-%d %H:%M"),
                    "target": req.get("target") or {},
                    "text": (req.get("text") or "")[:800],
                    "selection": req.get("selection") or None,
                    "comment": req.get("comment", ""),
                    "status": "open",
                })
                print(f"  + comment on {req.get('page')}: {req.get('comment','')[:70]}", flush=True)
            elif act in ("edit", "status", "delete"):
                keep = []
                for c in items:
                    if c.get("id") == req.get("id"):
                        if act == "delete":
                            continue
                        if act == "edit":
                            c["comment"] = req.get("comment", c["comment"])
                        else:
                            c["status"] = req.get("status", "open")
                    keep.append(c)
                items = keep
            else:
                return self._json({"ok": False, "error": f"unknown action {act!r}"})
            store_comments(items)
            page = req.get("page", "")
            return self._json({"ok": True, "comments": [c for c in items if c.get("page") == page],
                               "total": len(items)})
        except Exception as e:  # noqa: BLE001
            return self._json({"ok": False, "error": f"{type(e).__name__}: {e}"})
    def _save_page(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            page = self._safe(req.get("file", ""))
            if READER and (page is None or not locally_made(page.name)):
                return self._json({"ok": False, "error":
                                   "this page came from the store — edit a page you made instead"},
                                  code=403)
            if page is None:
                return self._json({"ok": False, "error": "file not under bundle root, or not .html"})
            changes = req.get("changes") or []
            if not changes:
                return self._json({"ok": False, "error": "no changes sent"})

            src = page.read_text(encoding="utf-8")
            BACKUPS.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            shutil.copy2(page, BACKUPS / f"{page.stem}.{stamp}.html")

            out, applied, failed = apply_changes(src, changes)
            if applied:
                page.write_text(out, encoding="utf-8")
            print(f"  {page.name}: {len(applied)} applied, {len(failed)} failed", flush=True)
            for f in failed:
                print(f"     ! change #{f['index']}: {f['reason']}", flush=True)

            png = False
            if applied and RENDER:
                t = threading.Thread(target=render_png, args=(page,), daemon=True)
                t.start()
                t.join(90)
                png = page.with_suffix(".png").exists()
            self._json({"ok": True, "applied": applied, "failed": failed, "png": png})
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "error": f"{type(e).__name__}: {e}"})

    def _audience(self):
        """Who a page is for. Unlisted means private, so this only ever records a
        decision to widen; clearing one narrows it back to private."""
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        act = body.get("action", "set")
        if READER:
            return self._json({"ok": False, "error":
                               "reader mode: audience is a publishing decision"}, code=403)
        A = ROOT / "_edit" / "audience.json"
        d = json.loads(A.read_text(encoding="utf-8"))
        d.setdefault("groups", {})
        d.setdefault("pages", {})

        if act == "set":
            page, group = body.get("page"), body.get("group")
            if not page or group not in d["groups"]:
                return self._json({"ok": False, "error": "unknown page or group"})
            # Nowhere to publish to is not a state a page can be moved into: the
            # assignment would look done and never reach anyone.
            if group != "private" and not d["groups"][group].get("repo"):
                return self._json({"ok": False,
                                   "error": f"{group!r} has no repository set"}, code=400)
            if group == "private":
                d["pages"].pop(page, None)
            else:
                d["pages"][page] = group
        elif act == "group-new":
            slug = (body.get("slug") or "").strip().lower()
            slug = re.sub(r"[^a-z0-9-]+", "-", slug).strip("-")
            if not slug:
                return self._json({"ok": False, "error": "a group needs a name"})
            if slug in d["groups"]:
                return self._json({"ok": False, "error": "that group already exists"})
            d["groups"][slug] = {"label": body.get("label") or slug,
                                 "repo": body.get("repo") or None}
        elif act == "group-rm":
            slug = body.get("slug")
            if slug in ("private", None) or slug not in d["groups"]:
                return self._json({"ok": False, "error": "cannot remove that group"})
            d["groups"].pop(slug)
            for pg in [k for k, v in d["pages"].items() if v == slug]:
                d["pages"].pop(pg)          # its pages fall back to private
        elif act == "group-repo":
            slug, repo = body.get("slug"), body.get("repo")
            if slug not in d["groups"]:
                return self._json({"ok": False, "error": "no such group"})
            d["groups"][slug]["repo"] = repo or None
        else:
            return self._json({"ok": False, "error": "unknown action"})

        d["pages"] = {k: v for k, v in sorted(d["pages"].items())}
        A.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        subprocess.run([sys.executable, str(ROOT / "_edit" / "audience.py")],
                       capture_output=True)
        return self._json({"ok": True,
                                "groups": d["groups"],
                                "page": body.get("page"),
                                "group": d["pages"].get(body.get("page"), "private")})

    def _tags(self):
        """Edit a page's tags from the browser, then rebuild the index."""
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            act, page = req.get("action"), (req.get("page") or "").strip()
            tag = (req.get("tag") or "").strip()
            if READER and page and not locally_made(page):
                return self._json({"ok": False, "error":
                                   "this page came from the store — its tags are not yours to change"},
                                  code=403)
            data = ROOT / "_edit" / "tags.json"
            d = json.loads(data.read_text(encoding="utf-8"))
            labels, pages = d["labels"], d["pages"]
            hidden = d.setdefault("hidden", [])
            order = d.setdefault("order", {})

            if act == "bar":
                # the shipped arrangement of the tag bar; a reader's own ordering
                # stays in their browser and never arrives here
                order = [t for t in (req.get("order") or []) if t in labels]
                more = [t for t in (req.get("more") or []) if t in order]
                d["bar"] = {"order": order, "more": more}
                data.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                subprocess.run([sys.executable, str(ROOT / "_edit" / "tags.py")], capture_output=True)
                return self._json({"ok": True, "bar": d["bar"]})

            if act == "new":
                if not re.fullmatch(r"[a-z0-9-]{1,24}", tag):
                    return self._json({"ok": False, "error": "slug must be a-z 0-9 -"})
                labels[tag] = (req.get("label") or tag).strip()[:40]
            elif act in ("add", "rm"):
                if tag not in labels:
                    return self._json({"ok": False, "error": "unknown tag"})
                cur = set(pages.get(page, []))
                cur.add(tag) if act == "add" else cur.discard(tag)
                if cur:
                    pages[page] = sorted(cur)
                else:
                    pages.pop(page, None)
            elif act == "del":
                if tag not in labels:
                    return self._json({"ok": False, "error": "unknown tag"})
                labels.pop(tag, None)
                for k in list(pages):
                    left = [t for t in pages[k] if t != tag]
                    if left:
                        pages[k] = left
                    else:
                        pages.pop(k, None)
            elif act == "label":
                if tag not in labels:
                    return self._json({"ok": False, "error": "unknown tag"})
                labels[tag] = (req.get("label") or tag).strip()[:40]
            elif act == "order":
                seq = req.get("pages") or []
                if not isinstance(seq, list) or not all(isinstance(x, str) for x in seq):
                    return self._json({"ok": False, "error": "pages must be a list"})
                if tag not in labels:
                    return self._json({"ok": False, "error": "unknown tag"})
                order[tag] = seq
            elif act in ("hide", "show"):
                if act == "hide" and page not in hidden:
                    hidden.append(page)
                if act == "show" and page in hidden:
                    hidden.remove(page)
            else:
                return self._json({"ok": False, "error": "bad action"})

            data.write_text(json.dumps({"labels": labels, "pages": pages,
                                        "hidden": sorted(hidden), "order": order},
                                       indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            subprocess.run([sys.executable, str(ROOT / "_edit" / "tags.py")],
                           capture_output=True, timeout=60, check=False)
            print(f"  tags {act} {tag} on {page or '-'}", flush=True)
            return self._json({"ok": True, "labels": labels, "tags": pages.get(page, []),
                               "hidden": page in hidden, "nhidden": len(hidden),
                               "order": order.get(tag, [])})
        except Exception as e:  # noqa: BLE001
            return self._json({"ok": False, "error": f"{type(e).__name__}: {e}"})

    def _render(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            page = self._safe(req.get("file", ""))
            if page is None:
                return self._json({"ok": False, "error": "unknown page"})
            if not page.with_suffix(".png").exists():
                return self._json({"ok": False, "error": "no PNG alongside this page"})
            ok = render_png(page)
            print(f"  rendered {page.with_suffix('.png').name}", flush=True)
            return self._json({"ok": ok, "png": ok})
        except Exception as e:  # noqa: BLE001
            return self._json({"ok": False, "error": f"{type(e).__name__}: {e}"})

    def _json(self, obj, code=200):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    global RENDER
    ap = argparse.ArgumentParser()
    # The port names the mode. Admin reads the working bundle and is one person's
    # tool; reader serves a clone and is what other people run. Colliding on one
    # port meant whichever bound first won, with nothing on screen to say which.
    ap.add_argument("--port", type=int, default=None,
                    help="default 8136 for admin, 8137 for --reader")
    ap.add_argument("--no-render", action="store_true", help="skip PNG re-render after save")
    ap.add_argument("--store", default=None,
                    help="the context store to serve (default: the working directory)")
    ap.add_argument("--reader", action="store_true",
                    help="reader mode: comments and zoom only, every other write refused")
    args = ap.parse_args()
    RENDER = not args.no_render
    global READER, ROOT, BACKUPS, COMMENTS
    READER = args.reader
    if args.store:
        ROOT = Path(args.store).expanduser().resolve()
    # these are derived from ROOT at import, before --store has been read
    BACKUPS = ROOT / "_edit" / "versions"
    COMMENTS = ROOT / "_edit" / "comments.json"
    if not (ROOT / "index.html").is_file():
        print(f"  no index.html in {ROOT} — is that a context store?", file=sys.stderr)
        return 1
    if args.port is None:
        args.port = 8137 if READER else 8136
    global PORT_IN_USE
    PORT_IN_USE = args.port
    print(f"  {'reader' if READER else 'admin'} mode on port {args.port}")
    print(f"  store: {ROOT}")
    if READER:
        print("  editing, tags and audience refused except on pages made here")

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    pages = len(list(ROOT.glob("*.html")))
    print(f"edit server  →  http://localhost:{args.port}/index.html")
    print(f"  bundle   {ROOT}")
    print(f"  pages    {pages}   versions  {BACKUPS.relative_to(ROOT)}/")
    print(f"  render   {'on (PNG rebuilt after save)' if RENDER else 'off'}")
    print(f"  comments {len(load_comments())} stored   →  http://localhost:{args.port}/_comments.html")
    print("  ⌘E edit · ⌘K comment · ⌘S save · ⌥± zoom · ctrl-C to stop\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    raise SystemExit(main() or 0)
