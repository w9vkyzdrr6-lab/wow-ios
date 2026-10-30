# -*- coding: utf-8 -*-
"""Download the full wow.aethus.pl site into ./www for offline bundling.
- Re-fetches the root modules every run (cheap, always current)
- Recursively discovers relative imports inside JS modules (e.g. snippets/)
- Data files are immutable server-side: skipped when already present (cache)
Usage: python3 download_site.py [outdir]   (default ./www)
"""
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://wow.aethus.pl"
OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "www")
WORKERS = 16

ROOT_FILES = [
    "rogue.css", "rogue.js", "wasi_stubs.js", "addons.js", "saves.js",
    "ime.js", "wenilla.js", "boot.js", "boot-manifest.json",
    "world-manifest.json", "wenilla_bg.wasm",
]

IMPORT_PAT = re.compile(r"""(?:from\s+|import\s+)['"](\.{1,2}/[^'"]+)['"]""")

def get(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def save(rel, body):
    dst = os.path.join(OUT, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(dst) or OUT, exist_ok=True)
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, dst)
    return dst

# 1. index page — and learn the build stamp from it
index = get(BASE + "/").decode("utf-8")
m = re.search(r"\?v=([0-9a-f]{8,})", index)
stamp = "?v=" + m.group(1) if m else ""
print("build stamp:", stamp or "(none)", flush=True)
save("index.html", index.encode("utf-8"))

# 2. root modules + recursively discovered relative imports
seen = set()
queue = list(ROOT_FILES)
while queue:
    name = queue.pop(0)
    if name in seen:
        continue
    seen.add(name)
    body = None
    for attempt in range(5):
        try:
            body = get(f"{BASE}/{name}{stamp}")
            break
        except Exception as e:
            if attempt == 4:
                raise RuntimeError(f"{name}: {e}")
            time.sleep(3 * (attempt + 1))
    dst = save(name, body)
    print("ok", name, flush=True)
    if name.endswith(".js"):
        text = body.decode("utf-8", errors="ignore")
        base_dir = os.path.dirname(name)
        for match in IMPORT_PAT.finditer(text):
            ref = match.group(1).split("?")[0]
            p = os.path.normpath(os.path.join(base_dir, ref)).replace("\\", "/")
            if p not in seen and not p.startswith(".."):
                queue.append(p)

# 3. data index + every file it lists (skip files already cached)
save("data/__index", get(f"{BASE}/data/__index{stamp}"))
names = json.loads(get(f"{BASE}/data/__index{stamp}").decode("utf-8"))
print("data files:", len(names), flush=True)

def static_path(name):
    segs = [s for s in name.lower().replace("\\", "/").split("/") if s]
    return "/".join(urllib.parse.quote(s) for s in segs)

lock = threading.Lock()
done = [0]
skipped = [0]
fails = []
start = time.time()

def fetch_data(name):
    rel = static_path(name)
    dst = os.path.join(OUT, "data", rel.replace("/", os.sep))
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        with lock:
            skipped[0] += 1
        return
    for attempt in range(5):
        try:
            save("data/" + rel, get(f"{BASE}/data/{rel}", timeout=60))
            with lock:
                done[0] += 1
                if done[0] % 1000 == 0:
                    print(f"data {done[0]}/{len(names)}", flush=True)
            return
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(5 * (attempt + 1)); continue
            if e.code in (500, 502, 503, 504) and attempt < 4:
                time.sleep(2 * (attempt + 1)); continue
            with lock: fails.append((name, str(e)))
            return
        except Exception as e:
            if attempt < 4:
                time.sleep(2 * (attempt + 1)); continue
            with lock: fails.append((name, str(e)))
            return

with ThreadPoolExecutor(max_workers=WORKERS) as ex:
    list(ex.map(fetch_data, names))

print(f"DONE fetched={done[0]} cached={skipped[0]} fail={len(fails)} "
      f"elapsed={time.time()-start:.0f}s", flush=True)
if fails:
    for n, e in fails[:50]:
        print("FAIL", n, e, flush=True)
    sys.exit(1)
