#!/usr/bin/env bash
#
# local-clean-room-test.sh
#
# Registry-free verification of the optionalDependencies wrapper. It packs
# the three packages exactly as `npm publish` would, then reconstructs the
# node_modules tree that npm WOULD produce after resolving optional deps,
# and exercises the shim end to end. This isolates OUR code (the shim, the
# package manifests, the staged binary) from npm's registry-side optional
# dependency resolution, which is npm core behavior and separately tested.
#
# Subtests:
#   1. resolve + run    : sibling platform package found, real `qnsqy version` runs
#   2. escape hatch      : QNSQY_BINARY_PATH used, no platform package needed
#   3. symlink rejected  : QNSQY_BINARY_PATH pointing at a symlink fails closed
#   4. missing platform  : no platform pkg + no env var -> clear error, exit 1
#   5. no install script : published main package has no scripts block
#
# Requires the Linux platform binary to be staged (host is Linux x86_64).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(dirname "$SCRIPT_DIR")"
LINUX_PKG="$WRAPPER_DIR/platform-packages/qnsqy-linux-x64"
WIN_PKG="$WRAPPER_DIR/platform-packages/qnsqy-win32-x64"

die() { printf 'cleanroom error: %s\n' "$1" >&2; exit 1; }
PASS=0; FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v npm  >/dev/null 2>&1 || die "npm required."
command -v node >/dev/null 2>&1 || die "node required."
[ "$(uname -s)" = "Linux" ] || die "this host-run test expects Linux (to exec the linux binary)."
[ -f "$LINUX_PKG/qnsqy" ] || die "linux binary not staged. Run ./scripts/stage-platform-packages.sh linux first."

# Expected version string from the BINARY (not the npm version, which may be
# ahead when only packaging changes). Derived from the staging manifest so a
# binary rebuild does not silently break subtests 1-2 with a stale literal.
BIN_VERSION="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).qnsqy_version||""))' "$WRAPPER_DIR/lib/manifest.json")"
[ -n "$BIN_VERSION" ] || die "could not read qnsqy_version from lib/manifest.json."
BIN_VERSION_RE="$(printf '%s' "$BIN_VERSION" | sed 's/\./\\./g')"

TESTROOT="$(mktemp -d "${TMPDIR:-/tmp}/qnsqy-cleanroom.XXXXXX")"
trap 'rm -rf "$TESTROOT"' EXIT
TARBALLS="$TESTROOT/tarballs"
mkdir -p "$TARBALLS"

# pack PKG_DIR -> prints the packed tarball's full path (scope-agnostic:
# scoped packages pack to quantumsequrity-qnsqy-<plat>-<ver>.tgz).
pack() {
  local fn
  fn="$(cd "$1" && npm pack --pack-destination "$TARBALLS" 2>/dev/null | tail -n1)"
  printf '%s/%s' "$TARBALLS" "$fn"
}
echo "packing the three packages..."
MAIN_TGZ="$(pack "$WRAPPER_DIR")"
LINUX_TGZ="$(pack "$LINUX_PKG")"
WIN_TGZ="$(pack "$WIN_PKG")"
[ -f "$MAIN_TGZ" ]  || die "could not find packed main tarball ($MAIN_TGZ)."
[ -f "$LINUX_TGZ" ] || die "could not find packed linux platform tarball ($LINUX_TGZ)."
echo "main:  $(basename "$MAIN_TGZ")"
echo "linux: $(basename "$LINUX_TGZ")"
echo "win:   $(basename "$WIN_TGZ")"

# unpack a tarball's package/ contents into a destination dir
unpack_into() {
  local tgz="$1" dest="$2"
  mkdir -p "$dest"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
}

build_tree() {
  # build_tree DEST_NM <include_platform 0|1>
  local nm="$1" include_platform="$2"
  rm -rf "$nm"
  mkdir -p "$nm/.bin"
  unpack_into "$MAIN_TGZ" "$nm/qnsqy"
  if [ "$include_platform" -eq 1 ]; then
    unpack_into "$LINUX_TGZ" "$nm/@quantumsequrity/qnsqy-linux-x64"
    chmod 755 "$nm/@quantumsequrity/qnsqy-linux-x64/qnsqy"
  fi
  ln -sf ../qnsqy/bin/qnsqy.js "$nm/.bin/qnsqy"
  chmod +x "$nm/qnsqy/bin/qnsqy.js"
}

echo
echo "== subtest 1: resolve + run (real binary) =="
NM="$TESTROOT/t1/node_modules"
build_tree "$NM" 1
set +e
OUT="$( "$NM/.bin/qnsqy" version 2>&1 )"; RC=$?
set -e
printf '    output: %s\n' "$(printf '%s' "$OUT" | head -n1)"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qi "$BIN_VERSION_RE"; then
  ok "qnsqy version resolved the sibling platform package and ran (exit 0, version printed)"
else
  bad "qnsqy version did not run cleanly (exit $RC). Output: $OUT"
fi

echo
echo "== subtest 2: QNSQY_BINARY_PATH escape hatch (no platform package) =="
NM2="$TESTROOT/t2/node_modules"
build_tree "$NM2" 0   # NO platform package
PRESTAGED="$TESTROOT/prestaged-qnsqy"
cp "$LINUX_PKG/qnsqy" "$PRESTAGED"; chmod 755 "$PRESTAGED"
set +e
OUT2="$( QNSQY_BINARY_PATH="$PRESTAGED" "$NM2/.bin/qnsqy" version 2>&1 )"; RC2=$?
set -e
if [ "$RC2" -eq 0 ] && printf '%s' "$OUT2" | grep -qi "$BIN_VERSION_RE"; then
  ok "escape hatch ran the pre-staged binary without any platform package"
else
  bad "escape hatch failed (exit $RC2). Output: $OUT2"
fi

echo
echo "== subtest 3: QNSQY_BINARY_PATH rejects a symlink =="
LINK="$TESTROOT/link-to-qnsqy"
ln -sf "$PRESTAGED" "$LINK"
set +e
OUT3="$( QNSQY_BINARY_PATH="$LINK" "$NM2/.bin/qnsqy" version 2>&1 )"; RC3=$?
set -e
if [ "$RC3" -ne 0 ] && printf '%s' "$OUT3" | grep -qi 'must not be a symlink'; then
  ok "symlink env value rejected (exit $RC3, clear message)"
else
  bad "symlink was NOT rejected as expected (exit $RC3). Output: $OUT3"
fi

echo
echo "== subtest 4: missing platform package -> clear error =="
set +e
OUT4="$( "$NM2/.bin/qnsqy" version 2>&1 )"; RC4=$?
set -e
if [ "$RC4" -ne 0 ] && printf '%s' "$OUT4" | grep -q 'include=optional'; then
  ok "missing platform package fails closed with --include=optional guidance (exit $RC4)"
else
  bad "missing-platform error not as expected (exit $RC4). Output: $OUT4"
fi

echo
echo "== subtest 5: published main package has NO scripts block =="
HAS_SCRIPTS="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]+"/qnsqy/package.json","utf8")); process.stdout.write(j.scripts?"yes":"no")' "$NM")"
if [ "$HAS_SCRIPTS" = "no" ]; then
  ok "main package ships no scripts block (no install/postinstall script)"
else
  bad "main package still has a scripts block!"
fi

echo
echo "== subtest 6: win32 tarball contains qnsqy.exe (when staged) =="
if [ -f "$WIN_PKG/qnsqy.exe" ]; then
  # Capture the full listing first, then grep a here-string. Do NOT pipe tar
  # into `grep -q`: grep exits on first match and closes the pipe while tar is
  # still decompressing past the 43MB entry, so tar dies on SIGPIPE and
  # `set -o pipefail` falsely reports failure.
  WIN_LIST="$(tar -tzf "$WIN_TGZ" 2>/dev/null || true)"
  if grep -q 'qnsqy\.exe$' <<<"$WIN_LIST"; then
    ok "win32 platform tarball ships qnsqy.exe"
  else
    bad "win32 binary is staged but is NOT in the packed win32 tarball ($WIN_TGZ)"
  fi
else
  printf '  WARN: qnsqy-win32-x64/qnsqy.exe is NOT staged (linux-only run). Run\n'
  printf '        ./scripts/stage-platform-packages.sh   (default: both)   before a real\n'
  printf '        publish. publish-release.sh hard-fails until the .exe is staged.\n'
fi

echo
echo "=================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ] || exit 1
