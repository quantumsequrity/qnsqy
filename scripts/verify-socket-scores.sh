#!/usr/bin/env bash
#
# verify-socket-scores.sh <version>
#
# Post-publish Socket.dev score verification for the three qnsqy packages.
# Run ~1-2 hours after publishing (Socket scans lag the registry).
#
# What it asserts, per package@version:
#   1. Socket has ACTUALLY scanned it: state != 'revalidate' and size > 0.
#      (Unscanned packages show placeholder all-100 scores. 7.2.21 fooled
#      us this way; never trust a score until the scan state is real.)
#   2. The detected license is not a known fuzzy-match misfire (the
#      'Saxpath' / 'CC-BY-SA-3.0' detections that tanked License to 80/70).
#   3. No alerts beyond the accepted baseline (qnsqy carries one accepted
#      low-severity 'urlStrings' alert for the support URLs in the shim;
#      everything else is a regression).
#   4. Prints the five category scores for the release notes.
#
# Exit codes: 0 = pass, 2 = not scanned yet (retry later), 1 = regression.
#
# Requires python3 + playwright (chromium). The Socket API is behind
# Cloudflare for bare curl; a real browser context passes.
#
set -euo pipefail
VERSION="${1:?usage: verify-socket-scores.sh <version>}"

python3 - "$VERSION" << 'PYEOF'
import json, sys
from playwright.sync_api import sync_playwright

VERSION = sys.argv[1]
PACKAGES = ["qnsqy", "@quantumsequrity/qnsqy-win32-x64", "@quantumsequrity/qnsqy-linux-x64"]
BAD_LICENSES = {"Saxpath", "CC-BY-SA-3.0", "CC-BY-SA-4.0"}
# Accepted baseline alerts: (package, alertKey) pairs that are known and deliberate.
ACCEPTED = {("qnsqy", "urlStrings")}

failures, pending = [], []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    ctx = browser.new_context(
        user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0")
    page = ctx.new_page()
    captured = {}

    def on_response(resp):
        u = resp.url
        if "/api/" in u and ("artifact" in u or "alert" in u):
            try:
                captured.setdefault(u.split("socket.dev")[-1][:80], resp.json())
            except Exception:
                pass

    page.on("response", on_response)

    for pkg in PACKAGES:
        captured.clear()
        url = f"https://socket.dev/npm/package/{pkg}/overview/{VERSION}"
        page.goto(url, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(4000)

        artifact = None
        for body in captured.values():
            items = body if isinstance(body, list) else [body]
            for it in items:
                if not isinstance(it, dict):
                    continue
                if it.get("version") == VERSION and (it.get("score") or it.get("scores")):
                    artifact = it
                for k in ("artifacts", "rows", "data"):
                    for sub in (it.get(k) or []):
                        if isinstance(sub, dict) and sub.get("version") == VERSION and (sub.get("score") or sub.get("scores")):
                            artifact = sub
        if artifact is None:
            pending.append(f"{pkg}@{VERSION}: no artifact data captured (page may have changed, or not yet indexed)")
            continue

        state = artifact.get("state", "")
        size = artifact.get("size", 0) or 0
        if state == "revalidate" or size == 0:
            pending.append(f"{pkg}@{VERSION}: state={state!r} size={size} -> NOT SCANNED YET (scores are placeholders, retry later)")
            continue

        lic = artifact.get("license") or ""
        if lic in BAD_LICENSES:
            failures.append(f"{pkg}@{VERSION}: license misdetected as {lic!r} (fuzzy-matcher misfire is back; LICENSE wording drifted?)")

        scores = artifact.get("score") or artifact.get("scores") or {}
        if scores:
            disp = {k: round(float(v) * 100) if isinstance(v, (int, float)) and v <= 1 else v
                    for k, v in scores.items() if isinstance(v, (int, float))}
            print(f"{pkg}@{VERSION}: scores {disp} | detected license: {lic or 'n/a'} | size {size}")

        alerts = artifact.get("alerts") or []
        for a in alerts:
            key = a.get("type") or a.get("key") or str(a)
            if (pkg, key) not in ACCEPTED:
                failures.append(f"{pkg}@{VERSION}: unexpected alert {key!r} (severity {a.get('severity')})")

    browser.close()

if pending:
    print("\nNOT SCANNED YET:")
    [print("  " + m) for m in pending]
if failures:
    print("\nREGRESSIONS:")
    [print("  " + m) for m in failures]

sys.exit(1 if failures else (2 if pending else 0))
PYEOF
