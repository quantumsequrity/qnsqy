#!/bin/bash
# alpine.sh <release dir> <out dir>: the static build on Alpine Linux (musl,
# no glibc) on this runner's CPU, in Docker. Alpine has no bash, so step 1
# adds it (apk checks the index signature); then, with no network and an
# empty HOME: the release smoke checks (version, self-hash, help, round trip
# with the sandbox lines, hash, TUI), the self-hash with
# QNSQY_REQUIRE_INTEGRITY=1, and the live one-line installer's musl message,
# which must point to the static build for this CPU.
set -uo pipefail
REL="$(cd "$1" && pwd)" OUT="$2"
S="$(cd "$(dirname "$0")" && pwd)"
IMG="${ALPINE_IMAGE:-docker.io/library/alpine:latest}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
V="$(cat "$REL/version")"
case "$(uname -m)" in aarch64) TARCH=aarch64 ;; x86_64) TARCH=x86_64 ;; *) TARCH="$(uname -m)" ;; esac
RES="$OUT/results.tsv"; LOG="$OUT/alpine.log"
[ -f "$RES" ] || printf 'image\tphase\tcheck\tresult\tdetail\n' > "$RES"
curl -fsSL --retry 5 https://quantumsequrity.com/downloads/install.sh -o "$OUT/install.sh"
for i in 1 2 3; do docker pull -q "$IMG" > /dev/null 2>&1 && break; sleep 15; done
docker run --name qs-alpine-bash "$IMG" apk add --no-cache bash > "$OUT/alpine-apk.log" 2>&1
docker commit qs-alpine-bash qs-alpine-bash:latest > /dev/null 2>&1
docker rm -f qs-alpine-bash > /dev/null 2>&1
RUN=(docker run --rm --network none -e HOME=/tmp/qshome -v "$S":/qs:ro -v "$REL/static":/opt/qs:ro)
{
  echo "RESULT|alpine|INFO|$(docker run --rm qs-alpine-bash:latest cat /etc/alpine-release) on $(uname -m)"
  "${RUN[@]}" qs-alpine-bash:latest bash /qs/smoke.sh /opt/qs/qnsqy "$V"
  "${RUN[@]}" qs-alpine-bash:latest bash -c 'mkdir -p "$HOME" && cd "$HOME" && out="$(QNSQY_REQUIRE_INTEGRITY=1 timeout 60 /opt/qs/qnsqy --version 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then echo "RESULT|require-integrity|PASS|self-hash verified (QNSQY_REQUIRE_INTEGRITY=1)"; else echo "RESULT|require-integrity|FAIL|rc=$rc $(echo "$out" | tail -3 | tr "\n" " ")"; fi
    out="$(printf "x-Pass-1234567!\nx-Pass-1234567!\n" | timeout 120 /opt/qs/qnsqy encrypt --password-stdin -y --no-audit -i /etc/alpine-release -o "$HOME/c" 2>&1)"
    echo "RESULT|static-landlock-banner|INFO|$(echo "$out" | grep -i landlock | head -2 | tr -s " " | tr "\n" " ")"'
  "${RUN[@]}" -e TARCH="$TARCH" -e QV="$V" -v "$OUT/install.sh":/qs-install.sh:ro qs-alpine-bash:latest bash -c 'mkdir -p "$HOME" && cd "$HOME"
    out="$(bash /qs-install.sh 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && echo "$out" | grep -q "uses musl libc" && echo "$out" | grep -q "qnsqy-$QV-linux-$TARCH-static.tar.gz"; then echo "RESULT|installer-musl|PASS|exit 1, points to the $TARCH static build"; else echo "RESULT|installer-musl|FAIL|rc=$rc $(echo "$out" | tail -3 | tr "\n" " ")"; fi'
} > "$LOG" 2>&1
n=0
while IFS='|' read -r _ check res detail; do
  printf '%s\t%s\t%s\t%s\t%s\n' "$IMG" static "$check" "$res" "$detail" >> "$RES"; n=$((n + 1))
done < <(grep -a '^RESULT|' "$LOG")
[ "$n" -gt 0 ] || printf '%s\tstatic\trun\tFAIL\tno results\n' "$IMG" >> "$RES"
grep -a '^RESULT|' "$LOG" | sed 's/^RESULT|/  [static] /' | tr '|' ' '
exit 0
