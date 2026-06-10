#!/usr/bin/env bash
#
# publish-release.sh
#
# Publishes the QNSQY npm packages in the correct order:
#   1. @quantumsequrity/qnsqy-linux-x64   (platform binary package)
#   2. @quantumsequrity/qnsqy-win32-x64   (platform binary package)
#   3. qnsqy                              (main package, references the two above)
#
# The platform packages MUST be published before the main package, because
# the moment `qnsqy` goes live its optionalDependencies must already resolve
# on the registry. All three are version-locked (enforced below).
#
# DRY-RUN BY DEFAULT. Pass --publish to actually publish. npm will prompt for
# your 2FA OTP on each publish if the account/package requires it (it should).
#
# Usage:
#   ./scripts/publish-release.sh                 # dry-run: preview tarballs, no publish
#   ./scripts/publish-release.sh --publish       # publish all three, in order
#   ./scripts/publish-release.sh --publish --tag=next
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"
LINUX_PKG="$WRAPPER_DIR/platform-packages/qnsqy-linux-x64"
WIN_PKG="$WRAPPER_DIR/platform-packages/qnsqy-win32-x64"

die() { printf 'publish error: %s\n' "$1" >&2; exit 1; }
info() { printf 'publish: %s\n' "$1"; }

command -v npm >/dev/null 2>&1 || die "npm is required."
command -v node >/dev/null 2>&1 || die "node is required."

PUBLISH=0
NPM_TAG="latest"
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --tag=*) NPM_TAG="${arg#--tag=}" ;;
    *) die "unknown argument '$arg' (expected --publish and/or --tag=<dist-tag>)." ;;
  esac
done

# 1. Staged binaries must exist.
[ -f "$LINUX_PKG/qnsqy" ] || die "linux binary not staged at $LINUX_PKG/qnsqy. Run ./scripts/stage-platform-packages.sh first."
[ -f "$WIN_PKG/qnsqy.exe" ] || die "windows binary not staged at $WIN_PKG/qnsqy.exe. Run ./scripts/stage-platform-packages.sh first."

# 2. Version lockstep: main version == both platform versions == both
#    optionalDependencies pins, and every version is EXACT (no ^ / ~ / range).
info "checking version lockstep across all three packages..."
node -e '
  const fs = require("fs");
  const root = process.argv[1];
  const rd = p => JSON.parse(fs.readFileSync(root + p, "utf8"));
  const main = rd("/package.json");
  const lx = rd("/platform-packages/qnsqy-linux-x64/package.json");
  const win = rd("/platform-packages/qnsqy-win32-x64/package.json");
  const integ = rd("/bin/integrity.json");
  const shim = fs.readFileSync(root + "/bin/qnsqy.js", "utf8");
  const ver = main.version;
  const od = main.optionalDependencies || {};
  const LX = "@quantumsequrity/qnsqy-linux-x64";
  const WIN = "@quantumsequrity/qnsqy-win32-x64";
  const errs = [];
  const exact = v => typeof v === "string" && /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$/.test(v);
  if (!exact(ver)) errs.push(`main version is not an exact version: ${ver}`);
  if (lx.name !== LX) errs.push(`linux platform package name is ${lx.name}, expected ${LX}`);
  if (win.name !== WIN) errs.push(`win platform package name is ${win.name}, expected ${WIN}`);
  if (lx.version !== ver) errs.push(`${LX} version ${lx.version} != main ${ver}`);
  if (win.version !== ver) errs.push(`${WIN} version ${win.version} != main ${ver}`);
  if (od[LX] !== ver) errs.push(`optionalDependencies["${LX}"] = ${od[LX]} != ${ver} (must be the EXACT version, not a range)`);
  if (od[WIN] !== ver) errs.push(`optionalDependencies["${WIN}"] = ${od[WIN]} != ${ver} (must be the EXACT version, not a range)`);
  if (main.scripts) errs.push("main package must NOT have a scripts block (no install scripts).");
  if (main.os || main.cpu) errs.push("main package must NOT declare top-level os/cpu (platform filtering belongs on the platform packages).");
  if (JSON.stringify(lx.os) !== JSON.stringify(["linux"]) || JSON.stringify(lx.cpu) !== JSON.stringify(["x64"])) errs.push("linux platform package os/cpu must be [linux]/[x64].");
  if (JSON.stringify(win.os) !== JSON.stringify(["win32"]) || JSON.stringify(win.cpu) !== JSON.stringify(["x64"])) errs.push("win platform package os/cpu must be [win32]/[x64].");
  // Every optionalDependency name must have a matching entry in the shim.
  for (const name of Object.keys(od)) {
    if (!shim.includes(name)) errs.push(`optionalDependency ${name} has no matching PLATFORM_PACKAGES entry in bin/qnsqy.js`);
  }
  // Integrity hashes must be provisioned (the shim fails closed otherwise).
  for (const k of ["linux-x64", "win32-x64"]) {
    if (!/^[0-9a-f]{64}$/.test(String(integ[k] || ""))) {
      errs.push(`bin/integrity.json["${k}"] is not a 64-hex sha256 (run stage-platform-packages.sh for that platform)`);
    }
  }
  if (errs.length) { console.error("LOCKSTEP CHECK FAILED:\n - " + errs.join("\n - ")); process.exit(1); }
  console.log("lockstep OK: qnsqy + both platform packages at " + ver + ", integrity hashes provisioned, shim entries match.");
' "$WRAPPER_DIR" || die "version lockstep check failed (see above). Fix and re-run staging."

VERSION="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$WRAPPER_DIR/package.json")"

# Validate the dist-tag (full string, allowlisted), and refuse to push a
# semver prerelease to 'latest'. A typoed tag like 'lateest' would otherwise
# publish silently without touching latest.
case "$NPM_TAG" in
  latest|next|beta) : ;;
  *)
    printf '%s' "$NPM_TAG" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' \
      || die "invalid --tag '$NPM_TAG' (must match ^[a-z][a-z0-9-]{0,31}$)."
    die "dist-tag '$NPM_TAG' is not in the allowlist (latest, next, beta). Add it to publish-release.sh deliberately if intended." ;;
esac
case "$VERSION" in
  *-*)
    if [ "$NPM_TAG" = "latest" ]; then
      die "version $VERSION is a semver prerelease; refusing to publish it to the 'latest' dist-tag (range installs like ^$VERSION would not see it, and it sorts below the matching release). Use a clean patch version for 'latest', or pass --tag=next for an intentional prerelease."
    fi ;;
esac

# Version alignment: warn (or fail, under REQUIRE_VERSION_ALIGNMENT=1) if the
# npm version does not match the binary version reported by `qnsqy --version`
# (manifest qnsqy_version). See stage-platform-packages.sh for the policy.
BIN_VERSION="$(node -e 'process.stdout.write((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).qnsqy_version)||"")' "$WRAPPER_DIR/lib/manifest.json" 2>/dev/null || true)"
if [ -n "$BIN_VERSION" ] && [ "$BIN_VERSION" != "$VERSION" ]; then
  AMSG="npm version ($VERSION) != binary version ($BIN_VERSION); \`qnsqy --version\` will report $BIN_VERSION. Align at the next real binary build (version the binary >= the npm latest and publish both at the same number)."
  if [ "${REQUIRE_VERSION_ALIGNMENT:-0}" = "1" ]; then
    die "version alignment required but $AMSG"
  fi
  info "NOTE (version skew): $AMSG"
fi

# Preflight gate: runs in THIS invocation, immediately before publishing.
# 7.2.23 shipped without its intended SECURITY.md because the tree changed
# between the dry-run invocation and the --publish invocation; the gate
# closes that hole. See scripts/preflight-check.sh for the full check list.
info "running preflight gate..."
"$SCRIPT_DIR/preflight-check.sh" || die "preflight gate failed. Nothing was published."

# Clean-room install test (registry-free reconstruction of the npm tree).
# Mandatory for live publishes; skippable only with SKIP_CLEAN_ROOM=1.
if [ "$PUBLISH" -eq 1 ] && [ "${SKIP_CLEAN_ROOM:-0}" != "1" ]; then
  info "running local clean-room install test..."
  "$SCRIPT_DIR/local-clean-room-test.sh" || die "clean-room test failed. Nothing was published."
fi

publish_one() {
  local dir="$1" name="$2"
  if [ "$PUBLISH" -eq 1 ]; then
    info "PUBLISHING $name@$VERSION (tag: $NPM_TAG) ..."
    ( cd "$dir" && npm publish --access public --tag "$NPM_TAG" ) \
      || die "npm publish failed for $name. STOP. Do NOT publish later packages until this is resolved."
    info "published $name@$VERSION"
  else
    info "DRY-RUN $name@$VERSION (no publish; showing tarball contents):"
    ( cd "$dir" && npm publish --dry-run --access public ) \
      || die "dry-run failed for $name."
  fi
}

if [ "$PUBLISH" -eq 1 ]; then
  info "=================================================================="
  info " LIVE PUBLISH of qnsqy@$VERSION + platform packages (tag: $NPM_TAG)"
  info " Order: @quantumsequrity/qnsqy-linux-x64 -> @quantumsequrity/qnsqy-win32-x64 -> qnsqy"
  info " npm will prompt for your 2FA OTP per package if required."
  info "=================================================================="
else
  info "DRY-RUN mode. No packages will be published. Re-run with --publish to go live."
fi

# Platform packages FIRST, main LAST.
publish_one "$LINUX_PKG" "@quantumsequrity/qnsqy-linux-x64"
publish_one "$WIN_PKG" "@quantumsequrity/qnsqy-win32-x64"
publish_one "$WRAPPER_DIR" "qnsqy"

if [ "$PUBLISH" -eq 1 ]; then
  info "ALL THREE PUBLISHED at $VERSION. Running post-publish verification..."

  # Executed verification against the live registry (was advisory-only
  # before; nothing was actually checked after 7.2.22/7.2.23 published).
  sleep 10  # registry propagation
  node -e '
    const { execSync } = require("child_process");
    const ver = process.argv[1];
    const expect = {
      "qnsqy": 6,
      "@quantumsequrity/qnsqy-linux-x64": 5,
      "@quantumsequrity/qnsqy-win32-x64": 5,
    };
    const errs = [];
    for (const [name, fileCount] of Object.entries(expect)) {
      let v;
      try {
        v = JSON.parse(execSync(`npm view ${name}@${ver} dist.fileCount dist.shasum dist-tags --json`, { encoding: "utf8" }));
      } catch (e) { errs.push(`${name}@${ver}: npm view failed (${e.message.split("\n")[0]})`); continue; }
      const fc = v["dist.fileCount"];
      if (fc !== fileCount) errs.push(`${name}@${ver}: fileCount ${fc}, expected ${fileCount} (a files-array entry was silently dropped?)`);
      else console.log(`verified ${name}@${ver}: fileCount ${fc} OK`);
    }
    let od;
    try {
      od = JSON.parse(execSync(`npm view qnsqy@${ver} optionalDependencies --json`, { encoding: "utf8" }));
      for (const dep of ["@quantumsequrity/qnsqy-linux-x64", "@quantumsequrity/qnsqy-win32-x64"]) {
        if (od[dep] !== ver) errs.push(`qnsqy@${ver} optionalDependencies[${dep}] = ${od[dep]}, expected ${ver}`);
      }
    } catch (e) { errs.push(`optionalDependencies check failed: ${e.message.split("\n")[0]}`); }
    if (errs.length) { console.error("POST-PUBLISH VERIFICATION FAILED:\n - " + errs.join("\n - ")); process.exit(1); }
    console.log("post-publish verification passed.");
  ' "$VERSION" || die "POST-PUBLISH VERIFICATION FAILED. Investigate immediately; fix forward with a patch bump (never unpublish)."

  info "Deprecate the superseded version: npm deprecate qnsqy@<old> \"Superseded by $VERSION\" (and both platform packages)."
  info "Socket scores: run scripts/verify-socket-scores.sh $VERSION after ~1-2h (Socket scans lag publishes)."
  info "Smoke test a fresh global install on a clean machine: npm install -g qnsqy && qnsqy version"
else
  info "DRY-RUN complete. Review the file lists above (each platform package"
  info "should contain ONLY its binary + package.json + README + LICENSE; main"
  info "should contain ONLY bin/qnsqy.js + package.json + README + LICENSE)."
fi
