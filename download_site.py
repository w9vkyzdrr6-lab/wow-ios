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
    # 客户端运行时会额外读取、但不在 __index 清单里的文件（漏了会导致中文缺字/加载异常）
    "data/fonts/azs_sc.ttf",
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
    """磁盘相对路径：小写、反斜杠转斜杠、保持原始字符（不做 URL 编码）"""
    segs = [s for s in name.lower().replace("\\", "/").split("/") if s]
    return "/".join(segs)

def url_path(rel):
    """URL 路径：逐段 percent-encode（磁盘文件名不编码）"""
    return "/".join(urllib.parse.quote(s) for s in rel.split("/"))

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
        return True
    for attempt in range(10):
        try:
            save("data/" + rel, get(f"{BASE}/data/{url_path(rel)}", timeout=90))
            with lock:
                done[0] += 1
                if done[0] % 1000 == 0:
                    print(f"data {done[0]}/{len(names)}", flush=True)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(min(60, 8 * (attempt + 1))); continue
            if e.code in (500, 502, 503, 504) and attempt < 9:
                time.sleep(3 * (attempt + 1)); continue
            if e.code == 404:
                with lock: fails.append((name, "404"))
                return False
            time.sleep(3 * (attempt + 1))
        except Exception as e:
            if attempt < 9:
                time.sleep(3 * (attempt + 1)); continue
            with lock: fails.append((name, str(e)))
            return False
    # 重试全部耗尽（常见于持续 429）：必须记为失败，不能静默跳过
    with lock: fails.append((name, "retry-exhausted"))
    return False

with ThreadPoolExecutor(max_workers=WORKERS) as ex:
    list(ex.map(fetch_data, names))

print(f"DONE fetched={done[0]} cached={skipped[0]} fail={len(fails)} "
      f"elapsed={time.time()-start:.0f}s", flush=True)
if fails:
    for n, e in fails[:50]:
        print("FAIL", n, e, flush=True)
    sys.exit(1)

# 4. 清理历史缓存里带 %XX 编码名的旧文件（命名 bug 的残留）
removed = 0
for root, _, files in os.walk(os.path.join(OUT, "data")):
    for f in files:
        if "%" in f:
            os.remove(os.path.join(root, f))
            removed += 1
if removed:
    print("cleanup: removed", removed, "legacy %-named files", flush=True)

# 5. 完整性校验：boot/world 清单 + __index 全部必须在磁盘上（解码名），缺的串行补下
want = set("data/" + static_path(n) for n in names)
for mf in ("boot-manifest.json", "world-manifest.json"):
    try:
        d = json.load(open(os.path.join(OUT, mf), encoding="utf-8"))
        want.update("data/" + static_path(n) for n in d["names"])
    except Exception as e:
        print("WARN manifest check skipped:", mf, e, flush=True)

absent = [r for r in sorted(want)
          if not os.path.exists(os.path.join(OUT, r.replace("/", os.sep)))]
if absent:
    print("verify: patching", len(absent), "missing files serially", flush=True)
    still = []
    for rel in absent:
        ok = False
        for attempt in range(12):
            try:
                save(rel, get(f"{BASE}/{url_path(rel)}", timeout=90))
                ok = True
                break
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    break
                time.sleep(min(60, 6 * (attempt + 1)))
            except Exception:
                time.sleep(min(60, 5 * (attempt + 1)))
        if not ok:
            still.append(rel)
    if still:
        for rel in still[:50]:
            print("STILL-MISSING", rel, flush=True)
        print(f"verify FAILED: {len(still)} files unavailable", flush=True)
        sys.exit(1)
print("verify OK: all manifest files present", flush=True)
