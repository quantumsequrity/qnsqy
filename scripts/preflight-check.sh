#!/usr/bin/env bash
#
# preflight-check.sh
#
# Hard gate that runs INSIDE the same invocation as `publish-release.sh
# --publish` (and on dry-runs). Exists because 7.2.23 shipped without the
# SECURITY.md it was supposed to add: the tree changed between the dry-run
# invocation and the live publish invocation, and npm silently skips
# `files` entries that have no file on disk.
#
# Checks (all hard failures):
#   1. Exact tarball file list per package (npm pack --dry-run --json).
#   2. Every `files` entry resolves to a non-empty file on disk.
#   3. Metadata lint: repository / bugs / homepage / license / author /
#      keywords / description / engines on all three packages.
#   4. Staged binary SHA-256 byte-compared against bin/integrity.json
#      VALUES (not just the 64-hex format).
#   5. LICENSE files match pinned hashes (Socket's fuzzy license matcher
#      misread earlier wordings as CC-BY-SA-3.0 / Saxpath and tanked the
#      License score; any drift must be deliberate).
#   6. SECURITY.md present and non-empty in all three packages.
#   7. README.md >= 3000 bytes in all three packages (readme length is
#      Socket's heaviest Quality metric; this catches accidental stubs).
#   8. npm-wrapper git tree is clean (override: PREFLIGHT_ALLOW_DIRTY=1).
#
# To re-pin LICENSE hashes after an APPROVED license wording change:
#   sha256sum LICENSE platform-packages/*/LICENSE   # then update below
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"
LINUX_PKG="$WRAPPER_DIR/platform-packages/qnsqy-linux-x64"
WIN_PKG="$WRAPPER_DIR/platform-packages/qnsqy-win32-x64"

FAIL=0
err() { printf 'preflight FAIL: %s\n' "$1" >&2; FAIL=1; }
ok()  { printf 'preflight ok:   %s\n' "$1"; }

# ---------------------------------------------------------------- 1 + 2
# Exact tarball contents per package. npm pack honors the files array and
# silently drops entries with no on-disk file, so we assert the EXACT
# resulting list, not just "no errors".
check_pack() {
  local dir="$1" label="$2"; shift 2
  local expected=("$@")
  local actual
  if ! actual="$(cd "$dir" && npm pack --dry-run --json 2>/dev/null \
      | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log(j[0].files.map(f=>f.path).sort().join("\n"))})')"; then
    err "$label: npm pack --dry-run failed"
    return
  fi
  local exp_sorted
  exp_sorted="$(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)"
  if [ "$actual" != "$exp_sorted" ]; then
    err "$label: tarball file list mismatch.
  expected:
$(printf '%s\n' "$exp_sorted" | sed 's/^/    /')
  actual:
$(printf '%s\n' "$actual" | sed 's/^/    /')"
  else
    ok "$label tarball contains exactly: $(printf '%s ' "${expected[@]}")"
  fi
}

check_pack "$WRAPPER_DIR" "qnsqy" \
  "LICENSE" "README.md" "SECURITY.md" "bin/integrity.json" "bin/qnsqy.js" "package.json"
check_pack "$LINUX_PKG" "@quantumsequrity/qnsqy-linux-x64" \
  "LICENSE" "README.md" "SECURITY.md" "package.json" "qnsqy"
check_pack "$WIN_PKG" "@quantumsequrity/qnsqy-win32-x64" \
  "LICENSE" "README.md" "SECURITY.md" "package.json" "qnsqy.exe"

# ------------------------------------------------------------------- 3
node -e '
  const fs = require("fs");
  const root = process.argv[1];
  const REPO_URL = "git+https://github.com/quantumsequrity/qnsqy.git";
  const BUGS_URL = "https://github.com/quantumsequrity/qnsqy/issues";
  const errs = [];
  const pkgs = [
    { p: "/package.json", dir: null },
    { p: "/platform-packages/qnsqy-linux-x64/package.json", dir: "platform-packages/qnsqy-linux-x64" },
    { p: "/platform-packages/qnsqy-win32-x64/package.json", dir: "platform-packages/qnsqy-win32-x64" },
  ];
  for (const { p, dir } of pkgs) {
    const j = JSON.parse(fs.readFileSync(root + p, "utf8"));
    const w = m => errs.push(`${j.name || p}: ${m}`);
    if (!j.repository || j.repository.type !== "git" || j.repository.url !== REPO_URL)
      w(`repository must be {type:"git", url:"${REPO_URL}"}`);
    if (dir && j.repository && j.repository.directory !== dir)
      w(`repository.directory must be "${dir}"`);
    if (j.bugs !== BUGS_URL) w(`bugs must be "${BUGS_URL}"`);
    if (j.homepage !== "https://quantumsequrity.com") w("homepage missing/wrong");
    if (j.license !== "SEE LICENSE IN LICENSE") w("license must be exactly \"SEE LICENSE IN LICENSE\" (UNLICENSED triggers a high-severity Socket alert)");
    if (!j.author) w("author missing");
    if (!Array.isArray(j.keywords) || j.keywords.length === 0) w("keywords missing");
    if (!j.description) w("description missing");
    if (!j.engines || !j.engines.node) w("engines.node missing");
    if (!Array.isArray(j.files) || j.files.length === 0) w("files array missing");
    for (const f of j.files || []) {
      const full = root + p.replace(/package\.json$/, "") + f;
      if (!fs.existsSync(full)) w(`files entry "${f}" does not exist on disk (npm would silently skip it)`);
      else if (fs.statSync(full).isFile() && fs.statSync(full).size === 0) w(`files entry "${f}" is empty`);
    }
  }
  const main = JSON.parse(fs.readFileSync(root + "/package.json", "utf8"));
  if (main.scripts) errs.push("main package must NOT have a scripts block");
  if (errs.length) { console.error(" - " + errs.join("\n - ")); process.exit(1); }
' "$WRAPPER_DIR" && ok "metadata lint passed on all three packages" \
  || err "metadata lint failed (see above)"

# ------------------------------------------------------------------- 4
check_binary_hash() {
  local file="$1" key="$2"
  [ -f "$file" ] || { err "staged binary missing: $file"; return; }
  local actual pinned
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  pinned="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]]||""))' "$WRAPPER_DIR/bin/integrity.json" "$key")"
  if [ "$actual" != "$pinned" ]; then
    err "integrity.json[$key] = $pinned but staged binary hashes to $actual. A stale stamp would fail-close EVERY install. Re-run stage-platform-packages.sh."
  else
    ok "integrity.json[$key] matches staged binary bytes"
  fi
}
check_binary_hash "$LINUX_PKG/qnsqy" "linux-x64"
check_binary_hash "$WIN_PKG/qnsqy.exe" "win32-x64"

# ------------------------------------------------------------------- 5
check_license_hash() {
  local file="$1" pinned="$2"
  local actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$pinned" ]; then
    err "LICENSE drift: $file hashes to $actual, pinned $pinned. Wording changes risk re-triggering Socket's CC-BY-SA/Saxpath misdetection. If the change is approved, re-pin the hash in preflight-check.sh."
  else
    ok "LICENSE pinned: $(basename "$(dirname "$file")")"
  fi
}
check_license_hash "$WRAPPER_DIR/LICENSE"  "4c722d6ab57b26d8886a659ed268049eaf410fdc10cabe091335f6d0da2a99f5"
check_license_hash "$LINUX_PKG/LICENSE"    "9f019867c47d0b9ca93671927930a34f58db7594791eebc7ccbfbdba3c3204e9"
check_license_hash "$WIN_PKG/LICENSE"      "6fbe4fd310033d8f02f8e1fa5ef2c32f39f41fb3f0bbf00d1786f27f93225c02"

# --------------------------------------------------------------- 6 + 7
for d in "$WRAPPER_DIR" "$LINUX_PKG" "$WIN_PKG"; do
  [ -s "$d/SECURITY.md" ] || err "SECURITY.md missing or empty in $d"
  if [ -f "$d/README.md" ]; then
    sz="$(wc -c < "$d/README.md")"
    [ "$sz" -ge 3000 ] || err "README.md in $d is only $sz bytes (< 3000); looks like a stub"
  else
    err "README.md missing in $d"
  fi
done
ok "SECURITY.md + README floors checked"

# ------------------------------------------------------------------- 8
if [ "${PREFLIGHT_ALLOW_DIRTY:-0}" != "1" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$WRAPPER_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    DIRTY="$(git -C "$WRAPPER_DIR" status --porcelain -- . 2>/dev/null || true)"
    if [ -n "$DIRTY" ]; then
      err "npm-wrapper git tree is dirty; the published tarball may not match review. Commit first, or set PREFLIGHT_ALLOW_DIRTY=1 deliberately.
$(printf '%s\n' "$DIRTY" | sed 's/^/    /')"
    else
      ok "git tree clean over npm-wrapper/"
    fi
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\npreflight: FAILED. Nothing was published.\n' >&2
  exit 1
fi
printf '\npreflight: ALL CHECKS PASSED.\n'
