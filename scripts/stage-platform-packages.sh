#!/usr/bin/env bash
#
# stage-platform-packages.sh
#
# Prepares the per-platform npm packages (@quantumsequrity/qnsqy-linux-x64,
# @quantumsequrity/qnsqy-win32-x64)
# for publishing. The binary bytes are NOT committed to git; they are
# fetched from cdn.quantumsequrity.com, SHA-256-verified against the values
# pinned in lib/manifest.json (the SAME hashes the website download page
# publishes), and dropped into each platform package's root.
#
# Single source of truth for the npm release version is the "version" field
# of the MAIN package.json. This script stamps that version into both
# platform packages AND into the main package's optionalDependencies, so the
# three packages can never drift out of lockstep.
#
# Idempotent: safe to re-run. Writes only inside npm-wrapper/.
#
# Usage:
#   ./scripts/stage-platform-packages.sh            # stage both platforms
#   ./scripts/stage-platform-packages.sh linux      # stage only linux
#   ./scripts/stage-platform-packages.sh windows    # stage only windows
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$WRAPPER_DIR/lib/manifest.json"
LINUX_PKG="$WRAPPER_DIR/platform-packages/qnsqy-linux-x64"
WIN_PKG="$WRAPPER_DIR/platform-packages/qnsqy-win32-x64"
SCRATCH="$WRAPPER_DIR/.stage-tmp"

CDN_HOST="cdn.quantumsequrity.com"

die() { printf 'stage error: %s\n' "$1" >&2; exit 1; }
info() { printf 'stage: %s\n' "$1"; }

command -v node >/dev/null 2>&1 || die "node is required (JSON parsing + version stamping)."
command -v curl >/dev/null 2>&1 || die "curl is required to download the binaries."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify downloads."
command -v ar >/dev/null 2>&1 || die "ar (binutils) is required to unpack the Linux .deb."
command -v tar >/dev/null 2>&1 || die "tar is required to unpack the Linux .deb data archive."
[ -f "$MANIFEST" ] || die "manifest not found at $MANIFEST"
[ -f "$WRAPPER_DIR/package.json" ] || die "main package.json not found at $WRAPPER_DIR/package.json"

WHICH="${1:-both}"
case "$WHICH" in
  both|linux|windows) ;;
  *) die "argument must be one of: both | linux | windows (got '$WHICH')." ;;
esac

# WRAPPER_VERSION is the npm release coordinate, read from the main package.
WRAPPER_VERSION="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$WRAPPER_DIR/package.json")"
[ -n "$WRAPPER_VERSION" ] || die "could not read version from main package.json"
info "npm release version (from main package.json): $WRAPPER_VERSION"

# Version alignment: the npm wrapper version should equal the binary version
# (manifest qnsqy_version) so `qnsqy --version` matches what users `npm install`.
# They are intentionally skewed today (the old postinstall model occupies
# qnsqy@7.2.20 on npm, so the wrapper had to move to 7.2.21+ while the binary
# stayed 7.2.20). To ALIGN: at the next real binary build, version that binary
# >= the npm latest and publish the npm packages at the SAME number.
# Default is a WARNING; set REQUIRE_VERSION_ALIGNMENT=1 to make a mismatch fatal
# (do this once the next aligned binary is built, to lock alignment in).
BIN_VERSION="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).qnsqy_version || "")' "$MANIFEST")"
if [ -n "$BIN_VERSION" ] && [ "$BIN_VERSION" != "$WRAPPER_VERSION" ]; then
  ALIGN_MSG="npm wrapper version ($WRAPPER_VERSION) != binary version ($BIN_VERSION). \`qnsqy --version\` will report $BIN_VERSION. To align, build the next binary at $WRAPPER_VERSION or higher and publish the npm packages at that same version."
  if [ "${REQUIRE_VERSION_ALIGNMENT:-0}" = "1" ]; then
    die "version alignment required but $ALIGN_MSG"
  fi
  printf 'stage: WARNING: %s\n' "$ALIGN_MSG" >&2
else
  info "version alignment OK: npm wrapper == binary == $WRAPPER_VERSION"
fi

# read_slot KEY -> prints "url<TAB>sha256<TAB>format" for that platform.
read_slot() {
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const s = m.platforms && m.platforms[process.argv[2]];
    if (!s) { process.stderr.write("no manifest slot for " + process.argv[2] + "\n"); process.exit(1); }
    for (const f of ["url","sha256","format"]) {
      if (typeof s[f] !== "string" || !s[f]) { process.stderr.write("manifest slot missing " + f + "\n"); process.exit(1); }
    }
    if (!/^https:\/\//.test(s.url) || new URL(s.url).hostname !== process.argv[3]) {
      process.stderr.write("manifest url not HTTPS on expected host: " + s.url + "\n"); process.exit(1);
    }
    if (!/^[0-9a-fA-F]{64}$/.test(s.sha256)) { process.stderr.write("manifest sha256 not 64 hex chars\n"); process.exit(1); }
    process.stdout.write(s.url + "\t" + s.sha256.toLowerCase() + "\t" + s.format);
  ' "$MANIFEST" "$1" "$CDN_HOST"
}

# download_and_verify URL EXPECTED_SHA OUTFILE
download_and_verify() {
  local url="$1" expected="$2" out="$3"
  info "downloading $url"
  curl -fsSL --proto '=https' --max-time 600 -o "$out" "$url" \
    || die "download failed for $url"
  local actual
  actual="$(sha256sum "$out" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    die "SHA-256 mismatch for $url
  expected: $expected
  actual:   $actual
The CDN artifact does not match lib/manifest.json. Refusing to stage a
binary whose hash is not the pinned, website-published value. Resolve the
drift (update manifest.json from https://quantumsequrity.com/download AND
re-verify) before staging."
  fi
  info "verified SHA-256 ($(wc -c < "$out") bytes)."
}

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

stage_linux() {
  info "=== staging qnsqy-linux-x64 ==="
  local slot url sha fmt
  slot="$(read_slot linux-x64)" || die "failed reading linux-x64 manifest slot"
  url="$(printf '%s' "$slot" | cut -f1)"
  sha="$(printf '%s' "$slot" | cut -f2)"
  fmt="$(printf '%s' "$slot" | cut -f3)"
  [ "$fmt" = "deb" ] || die "expected linux format 'deb' in manifest, got '$fmt'"

  local deb="$SCRATCH/qnsqy-linux.deb"
  download_and_verify "$url" "$sha" "$deb"

  # A .deb is a BSD `ar` archive containing data.tar.{gz,xz,zst}. Pull the
  # data member out, then extract usr/bin/qnsqy from it with system tar
  # (auto-detects the compression).
  local data_member
  data_member="$(ar t "$deb" | grep '^data\.tar' | head -n1 || true)"
  [ -n "$data_member" ] || die "no data.tar.* member found in $deb"
  info "deb data member: $data_member"
  ar p "$deb" "$data_member" > "$SCRATCH/$data_member" || die "ar p failed extracting $data_member"

  local debroot="$SCRATCH/debroot"
  mkdir -p "$debroot"
  tar -xf "$SCRATCH/$data_member" -C "$debroot" \
    || die "tar could not extract $data_member (zstd/xz support missing? install zstd / xz)."

  local extracted="$debroot/usr/bin/qnsqy"
  [ -f "$extracted" ] || die "usr/bin/qnsqy not found inside the deb data archive."

  mkdir -p "$LINUX_PKG"
  cp "$extracted" "$LINUX_PKG/qnsqy"
  chmod 755 "$LINUX_PKG/qnsqy"
  info "staged $LINUX_PKG/qnsqy ($(wc -c < "$LINUX_PKG/qnsqy") bytes)"
}

stage_windows() {
  info "=== staging qnsqy-win32-x64 ==="
  local slot url sha fmt
  slot="$(read_slot win32-x64)" || die "failed reading win32-x64 manifest slot"
  url="$(printf '%s' "$slot" | cut -f1)"
  sha="$(printf '%s' "$slot" | cut -f2)"
  fmt="$(printf '%s' "$slot" | cut -f3)"
  [ "$fmt" = "exe" ] || die "expected windows format 'exe' in manifest, got '$fmt'"

  local exe="$SCRATCH/qnsqy.exe"
  download_and_verify "$url" "$sha" "$exe"

  # The Windows artifact is the standalone portable .exe (passthrough): the
  # downloaded bytes ARE the binary.
  mkdir -p "$WIN_PKG"
  cp "$exe" "$WIN_PKG/qnsqy.exe"
  info "staged $WIN_PKG/qnsqy.exe ($(wc -c < "$WIN_PKG/qnsqy.exe") bytes)"
}

if [ "$WHICH" = "both" ] || [ "$WHICH" = "linux" ]; then
  stage_linux
fi
if [ "$WHICH" = "both" ] || [ "$WHICH" = "windows" ]; then
  stage_windows
fi

# Stamp WRAPPER_VERSION into both platform packages and the main package's
# optionalDependencies so all three are locked to the exact same version.
info "stamping version $WRAPPER_VERSION into platform packages + main optionalDependencies"
node -e '
  const fs = require("fs");
  const root = process.argv[1], ver = process.argv[2];
  const patch = (p, fn) => {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    fn(j);
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  };
  patch(root + "/platform-packages/qnsqy-linux-x64/package.json", j => { j.version = ver; });
  patch(root + "/platform-packages/qnsqy-win32-x64/package.json", j => { j.version = ver; });
  patch(root + "/package.json", j => {
    j.optionalDependencies = j.optionalDependencies || {};
    j.optionalDependencies["@quantumsequrity/qnsqy-linux-x64"] = ver;
    j.optionalDependencies["@quantumsequrity/qnsqy-win32-x64"] = ver;
  });
' "$WRAPPER_DIR" "$WRAPPER_VERSION"

# Stamp the inner-binary SHA-256 into bin/integrity.json for the platforms
# staged in this run. This is the hash the shim verifies before exec, and it
# ships inside the main package (the trust root). Only platforms staged now
# are updated; others keep their existing value.
INTEGRITY="$WRAPPER_DIR/bin/integrity.json"
[ -f "$INTEGRITY" ] || die "bin/integrity.json missing at $INTEGRITY"
LINUX_HASH=""
WIN_HASH=""
if { [ "$WHICH" = "both" ] || [ "$WHICH" = "linux" ]; } && [ -f "$LINUX_PKG/qnsqy" ]; then
  LINUX_HASH="$(sha256sum "$LINUX_PKG/qnsqy" | awk '{print $1}')"
fi
if { [ "$WHICH" = "both" ] || [ "$WHICH" = "windows" ]; } && [ -f "$WIN_PKG/qnsqy.exe" ]; then
  WIN_HASH="$(sha256sum "$WIN_PKG/qnsqy.exe" | awk '{print $1}')"
fi
node -e '
  const fs = require("fs");
  const p = process.argv[1], lh = process.argv[2], wh = process.argv[3];
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  if (lh) j["linux-x64"] = lh;
  if (wh) j["win32-x64"] = wh;
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
' "$INTEGRITY" "$LINUX_HASH" "$WIN_HASH"
info "stamped bin/integrity.json (linux-x64=${LINUX_HASH:-unchanged}, win32-x64=${WIN_HASH:-unchanged})"

info "done. Staged binaries are gitignored. Next: ./scripts/publish-release.sh (dry-run first)."
