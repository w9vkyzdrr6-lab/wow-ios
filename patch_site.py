# -*- coding: utf-8 -*-
"""Patch the freshly downloaded site for the iOS offline app (runs in CI after download_site.py).

1. rogue.js: the world-entry pipeline warm pass (~2000 shader pipelines compiled in one go
   behind the loading screen) kills mobile GPU drivers — the site disables it only for
   Android. iPhone has the same problem (the loading bar never finishes), so force the
   Android mitigations: pipe_warm=0, pbr_lite=1.
"""
import os
import sys

WWW = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "www")

ROGUE = os.path.join(WWW, "rogue.js")
src = open(ROGUE, encoding="utf-8").read()

PATCHES = [
    ("/Android/.test(navigator.userAgent) ? '0' : null", "'0'"),
    ("/Android/.test(navigator.userAgent) ? '1' : null", "'1'"),
]
for old, new in PATCHES:
    if old not in src:
        print(f"FATAL: pattern not found in rogue.js: {old}", flush=True)
        sys.exit(1)
    src = src.replace(old, new, 1)
open(ROGUE, "w", encoding="utf-8").write(src)
print("patched rogue.js: pipe_warm=0, pbr_lite=1 forced", flush=True)
