#!/bin/bash
# distro.sh <image> <version> <bare program> <out dir>: one Linux distribution
# on this runner's own CPU, in fresh Docker containers, with the phases our
# release test matrix runs before every release:
#   pm     install from the live repository with signature checks on
#          (dnf gpgcheck=1 + repo_gpgcheck=1, zypper gpgcheck, apt signed-by),
#          then the post-install checks; network on
#   smoke  on the pm result with no network and an empty HOME: --version and
#          the self-hash check, --help, a password encrypt and decrypt round
#          trip compared by SHA-256 with the sandbox and network-drop lines,
#          hash, the TUI start
#   raw    the same checks with the bare program on the untouched image
#   inst   the download page's one-line installer from the live site; network on
# Results: <out>/results.tsv (image, phase, check, PASS|FAIL|INFO, detail).
set -uo pipefail
IMG="$1" V="$2" BIN="$3" OUT="$4"
S="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="${REPO_URL:-https://cdn.quantumsequrity.com/repo}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
slug="$(echo "$IMG" | tr -c 'A-Za-z0-9._-' '-')"; slug="${slug%-}"
tag="qstest-$(echo "$slug" | tr 'A-Z' 'a-z')"
RES="$OUT/results.tsv"
[ -f "$RES" ] || printf 'image\tphase\tcheck\tresult\tdetail\n' > "$RES"
record() {   # record <phase> <log>
  local n=0 check res detail
  while IFS='|' read -r _ check res detail; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$IMG" "$1" "$check" "$res" "$detail" >> "$RES"; n=$((n + 1))
  done < <(grep -a '^RESULT|' "$2")
  [ "$n" -gt 0 ] || printf '%s\t%s\trun\tFAIL\tno results (see %s)\n' "$IMG" "$1" "$(basename "$2")" >> "$RES"
  grep -a '^RESULT|' "$2" | sed "s/^RESULT|/  [$1] /" | tr '|' ' '
}
pulled=0
for i in 1 2 3; do docker pull -q "$IMG" > /dev/null 2>&1 && { pulled=1; break; }; sleep 15; done
[ "$pulled" -eq 1 ] || { printf '%s\tall\tpull\tFAIL\tdocker pull failed 3 times\n' "$IMG" >> "$RES"; exit 0; }
printf '%s\tall\tcpu\tINFO\t%s, image %s\n' "$IMG" "$(uname -m)" "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$IMG")" >> "$RES"

echo "== $IMG pm"
name="$tag-pm-$$"
timeout --kill-after=30 1800 docker run --name "$name" -v "$S":/qs:ro "$IMG" \
  bash /qs/pm.sh "$REPO_URL" qnsqy-repo.gpg.asc qnsqy-repo.gpg.asc > "$OUT/$slug.pm.log" 2>&1
docker commit "$name" "$tag:pm" > /dev/null 2>&1 || echo "RESULT|commit|FAIL|docker commit" >> "$OUT/$slug.pm.log"
docker rm -f "$name" > /dev/null 2>&1
record pm "$OUT/$slug.pm.log"

echo "== $IMG smoke"
if grep -aq '^RESULT|pm-install|PASS' "$OUT/$slug.pm.log"; then
  timeout --kill-after=30 900 docker run --rm --network none -v "$S":/qs:ro "$tag:pm" \
    bash /qs/smoke.sh /usr/bin/qnsqy "$V" > "$OUT/$slug.smoke.log" 2>&1
  record smoke "$OUT/$slug.smoke.log"
else
  printf '%s\tsmoke\trun\tFAIL\tno pm result to test\n' "$IMG" >> "$RES"
fi

echo "== $IMG raw"
timeout --kill-after=30 900 docker run --rm --network none -v "$S":/qs:ro -v "$BIN":/opt/qsbin/qnsqy:ro "$IMG" \
  bash /qs/smoke.sh /opt/qsbin/qnsqy "$V" > "$OUT/$slug.raw.log" 2>&1
record raw "$OUT/$slug.raw.log"

echo "== $IMG inst"
timeout --kill-after=30 1800 docker run --rm -v "$S":/qs:ro "$IMG" \
  bash /qs/inst-live.sh "$V" > "$OUT/$slug.inst.log" 2>&1
record inst "$OUT/$slug.inst.log"
exit 0
