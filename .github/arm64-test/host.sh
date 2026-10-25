#!/bin/bash
# host.sh <release dir> <out dir> <x86_64 files dir> <files-for-x86_64 dir>:
# the release on this runner itself (Ubuntu on an ARM64 CPU, no container),
# every program run with no network and an empty HOME:
#   - the CPU and kernel, for the record;
#   - both signed SHA-256 lists (linux/ and windows/) verified with ML-DSA-87,
#     once with the program's own key and once with the public key published
#     on the website; a changed list and a changed signature refused;
#   - the release smoke checks for the packaged and the static program;
#   - the file sandbox (Landlock) probe for both programs;
#   - edge sizes, a changed byte, a wrong password, 20 round trips of 64 MiB,
#     speed;
#   - files encrypted on x86_64 decrypted here, and files made here for the
#     x86_64 job to decrypt.
set -uo pipefail
REL="$(cd "$1" && pwd)" OUT="$2" FROM_X86="$3" FOR_X86="$4"
S="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT" "$FOR_X86" && OUT="$(cd "$OUT" && pwd)" && FOR_X86="$(cd "$FOR_X86" && pwd)"
V="$(cat "$REL/version")" BIN="$REL/bin/qnsqy" STATIC="$REL/static/qnsqy"
RES="$OUT/results.tsv"
[ -f "$RES" ] || printf 'image\tphase\tcheck\tresult\tdetail\n' > "$RES"
record() {   # record <phase> <log>
  local n=0 check res detail
  while IFS='|' read -r _ check res detail; do
    printf '%s\t%s\t%s\t%s\t%s\n' "runner-host" "$1" "$check" "$res" "$detail" >> "$RES"; n=$((n + 1))
  done < <(grep -a '^RESULT|' "$2")
  [ "$n" -gt 0 ] || printf '%s\t%s\trun\tFAIL\tno results (see %s)\n' "runner-host" "$1" "$(basename "$2")" >> "$RES"
  grep -a '^RESULT|' "$2" | sed "s/^RESULT|/  [$1] /" | tr '|' ' '
}
# offline <cmd>...: as this user, in a new network namespace (no network).
offline() {
  sudo unshare --net -- setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
    env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 "$@"
}
sudo ln -sfn "$S" /qs   # smoke.sh reads /qs/common.sh
record fetch "$REL/fetch.log"

{
  echo "RESULT|cpu|INFO|$(uname -m); $(lscpu | grep -E '^(Vendor ID|Model name|CPU\(s\)):' | tr -s ' ' | tr '\n' ';')"
  echo "RESULT|cpu-features|INFO|$(grep -m1 -i '^Features' /proc/cpuinfo | cut -d: -f2 | tr -s ' ')"
  . /etc/os-release; echo "RESULT|os|INFO|$PRETTY_NAME, kernel $(uname -r)"
  echo "RESULT|lsm|INFO|$(cat /sys/kernel/security/lsm 2>/dev/null || sudo cat /sys/kernel/security/lsm)"
} > "$OUT/system.log" 2>&1
record system "$OUT/system.log"

# The website's copy of the release public key, fetched before going offline.
curl -fsSL --retry 5 https://quantumsequrity.com/keys/release-mldsa87.pub -o "$OUT/release-mldsa87.pub"
vr() {   # vr <dir with checksums.txt and checksums.txt.sig> [--pubkey FILE]
  ( cd "$1" && offline timeout 120 "$BIN" verify-release checksums.txt checksums.txt.sig "${@:2}" 2>&1 )
}
{
  for d in linux windows; do
    T="$(mktemp -d)"; cp "$REL/$d-checksums.txt" "$T/checksums.txt"; cp "$REL/$d-checksums.txt.sig" "$T/checksums.txt.sig"
    out="$(vr "$T")"
    echo "$out" | grep -q '^RELEASE_SIGNATURE_OK' && echo "RESULT|list-$d|PASS|ML-DSA-87 valid (key built into the program)" \
      || echo "RESULT|list-$d|FAIL|$(echo "$out" | tail -2 | tr '\n' ' ')"
    out="$(vr "$T" --pubkey "$OUT/release-mldsa87.pub")"
    echo "$out" | grep -q '^RELEASE_SIGNATURE_OK' && echo "RESULT|list-$d-site-key|PASS|ML-DSA-87 valid with the website's public key: $(echo "$out" | grep -m1 -o 'fingerprint: [0-9a-f]*')" \
      || echo "RESULT|list-$d-site-key|FAIL|$(echo "$out" | tail -2 | tr '\n' ' ')"
  done
  # A changed list: the first hex digit of the first SHA-256 line replaced.
  T="$(mktemp -d)"; cp "$REL/linux-checksums.txt.sig" "$T/checksums.txt.sig"; cp "$REL/linux-checksums.txt" "$T/checksums.txt"
  python3 - "$T/checksums.txt" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    if len(l) > 66 and l[64:66] == "  ":
        c = "0" if l[0] != "0" else "1"
        lines[i] = c + l[1:]
        break
open(p, "w").write("\n".join(lines))
PY
  if cmp -s "$T/checksums.txt" "$REL/linux-checksums.txt"; then echo "RESULT|list-changed|FAIL|the list did not change"
  else out="$(vr "$T")"; echo "$out" | grep -q '^RELEASE_SIGNATURE_OK' && echo "RESULT|list-changed|FAIL|a changed list was accepted" \
    || echo "RESULT|list-changed|PASS|changed list refused: $(echo "$out" | grep -v '^\s*$' | tail -1 | cut -c1-200)"; fi
  T="$(mktemp -d)"; cp "$REL/linux-checksums.txt" "$T/checksums.txt"; cp "$REL/linux-checksums.txt.sig" "$T/checksums.txt.sig"
  python3 -c 'import sys; f = open(sys.argv[1], "r+b"); f.seek(-40, 2); b = f.read(1); f.seek(-40, 2); f.write(bytes([b[0] ^ 0x01]))' "$T/checksums.txt.sig"
  out="$(vr "$T")"; echo "$out" | grep -q '^RELEASE_SIGNATURE_OK' && echo "RESULT|signature-changed|FAIL|a changed signature was accepted" \
    || echo "RESULT|signature-changed|PASS|changed signature refused: $(echo "$out" | grep -v '^\s*$' | tail -1 | cut -c1-200)"
} > "$OUT/lists.log" 2>&1
record lists "$OUT/lists.log"

offline bash /qs/smoke.sh "$BIN" "$V" > "$OUT/smoke-packaged.log" 2>&1; record smoke-packaged "$OUT/smoke-packaged.log"
offline bash /qs/smoke.sh "$STATIC" "$V" > "$OUT/smoke-static.log" 2>&1; record smoke-static "$OUT/smoke-static.log"
{
  T="$(mktemp -d)"; head -c 65536 /dev/urandom > "$T/p"
  out="$(cd "$T" && printf 'x-Pass-1234567!\nx-Pass-1234567!\n' | offline env HOME="$T" timeout 120 "$STATIC" encrypt --password-stdin -y --no-audit -i p -o c 2>&1)"
  echo "RESULT|static-landlock-banner|INFO|$(echo "$out" | grep -i 'landlock' | head -2 | tr -s ' ' | tr '\n' ' ')"
} > "$OUT/static-banner.log" 2>&1
record static-banner "$OUT/static-banner.log"
for p in packaged static; do
  b="$BIN"; [ "$p" = static ] && b="$STATIC"
  sudo unshare --net -- bash "$S/landlock-probe.sh" "$b" > "$OUT/landlock-$p.log" 2>&1; record "landlock-$p" "$OUT/landlock-$p.log"
  offline bash "$S/landlock-probe.sh" "$b" --home-only > "$OUT/landlock-$p-user.log" 2>&1; record "landlock-$p-user" "$OUT/landlock-$p-user.log"
done

for m in sizes stress speed; do
  offline bash "$S/files.sh" "$BIN" "$m" > "$OUT/files-$m.log" 2>&1; record "files-$m" "$OUT/files-$m.log"
done
offline bash "$S/files.sh" "$BIN" check "$(cd "$FROM_X86" && pwd)" > "$OUT/cross-from-x86.log" 2>&1; record cross-from-x86 "$OUT/cross-from-x86.log"
offline bash "$S/files.sh" "$BIN" make "$FOR_X86" > "$OUT/cross-make.log" 2>&1; record cross-make "$OUT/cross-make.log"
exit 0
