#!/bin/bash
# fetch.sh <arm64|amd64> <dir>: the current release's Linux files from the CDN,
# each checked against the published SHA-256 list. The program from the .deb
# goes to <dir>/bin/qnsqy; on arm64 the static build goes to <dir>/static/qnsqy.
# <dir>/version holds the release version, read from the list; <dir>/fetch.log
# the results.
set -uo pipefail
ARCH="$1" D="$2"
CDN="${CDN:-https://cdn.quantumsequrity.com}"
mkdir -p "$D" && D="$(cd "$D" && pwd)" && cd "$D" || exit 1
: > "$D/fetch.log"
r() { echo "RESULT|$1|$2|$3" | tee -a "$D/fetch.log"; }
get() { curl -fsSL --retry 5 --retry-delay 5 --max-time 600 "$1" -o "$2"; }
for dir in linux windows; do
  for f in checksums.txt checksums.txt.sig; do
    get "$CDN/$dir/$f" "$dir-$f" || { r fetch FAIL "$dir/$f"; exit 1; }
  done
done
V="$(grep -oE 'qnsqy_[0-9]+\.[0-9]+\.[0-9]+-1_amd64\.deb' linux-checksums.txt | head -1 | sed -E 's/^qnsqy_(.*)-1_amd64\.deb$/\1/')"
[ -n "$V" ] || { r version FAIL "no version in linux/checksums.txt"; exit 1; }
echo "$V" > version
r release INFO "$V"
case "$ARCH" in
  arm64) files="qnsqy_${V}-1_arm64.deb qnsqy-${V}-1.aarch64.rpm qnsqy-${V}-linux-aarch64-static.tar.gz" ;;
  amd64) files="qnsqy_${V}-1_amd64.deb" ;;
  *) r arch FAIL "arch must be arm64 or amd64"; exit 1 ;;
esac
for f in $files; do
  want="$(awk -v f="$f" '$2==f{print $1}' linux-checksums.txt)"
  [ -n "$want" ] || { r "sha256-$f" FAIL "not in linux/checksums.txt"; continue; }
  get "$CDN/linux/$f" "$f" || { r "sha256-$f" FAIL "download failed"; continue; }
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then r "sha256-$f" PASS "$got"; else r "sha256-$f" FAIL "want $want got $got"; rm -f "$f"; fi
done
deb="qnsqy_${V}-1_${ARCH}.deb"
mkdir -p pkg bin
if [ -f "$deb" ] && dpkg-deb -x "$deb" pkg && install -m 755 pkg/usr/bin/qnsqy bin/qnsqy; then
  r unpack PASS "bin/qnsqy from $deb: $(file -b bin/qnsqy | cut -d, -f1-2)"
else
  r unpack FAIL "$deb"
fi
if [ "$ARCH" = arm64 ]; then
  t="qnsqy-${V}-linux-aarch64-static.tar.gz"
  mkdir -p static
  if [ -f "$t" ] && tar -xzf "$t" -C static --strip-components=1 && [ -x static/qnsqy ]; then
    r unpack-static PASS "static/qnsqy from $t: $(file -b static/qnsqy | cut -d, -f1-2)"
  else
    r unpack-static FAIL "$t"
  fi
fi
exit 0
