#!/bin/bash
# x64.sh <make|check> <release dir> <out dir> <files dir>: the x86_64 side of
# the test, on GitHub's x86_64 runner, every program run with no network and
# an empty HOME. make: the edge sizes and speed (to compare with ARM64), then
# files encrypted here for the ARM64 job. check: decrypt the files the ARM64
# job encrypted and compare them by SHA-256.
set -uo pipefail
MODE="$1" REL="$(cd "$2" && pwd)" OUT="$3" FILES="$4"
S="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT" "$FILES" && OUT="$(cd "$OUT" && pwd)" && FILES="$(cd "$FILES" && pwd)"
BIN="$REL/bin/qnsqy"
RES="$OUT/results.tsv"
[ -f "$RES" ] || printf 'image\tphase\tcheck\tresult\tdetail\n' > "$RES"
record() {   # record <phase> <log>
  local n=0 check res detail
  while IFS='|' read -r _ check res detail; do
    printf '%s\t%s\t%s\t%s\t%s\n' "runner-x86_64" "$1" "$check" "$res" "$detail" >> "$RES"; n=$((n + 1))
  done < <(grep -a '^RESULT|' "$2")
  [ "$n" -gt 0 ] || printf '%s\t%s\trun\tFAIL\tno results (see %s)\n' "runner-x86_64" "$1" "$(basename "$2")" >> "$RES"
  grep -a '^RESULT|' "$2" | sed "s/^RESULT|/  [$1] /" | tr '|' ' '
}
offline() {
  sudo unshare --net -- setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
    env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 "$@"
}
case "$MODE" in
  make)
    record fetch "$REL/fetch.log"
    for m in sizes speed; do
      offline bash "$S/files.sh" "$BIN" "$m" > "$OUT/x64-files-$m.log" 2>&1; record "x64-files-$m" "$OUT/x64-files-$m.log"
    done
    offline bash "$S/files.sh" "$BIN" make "$FILES" > "$OUT/x64-cross-make.log" 2>&1; record x64-cross-make "$OUT/x64-cross-make.log"
    ;;
  check)
    offline bash "$S/files.sh" "$BIN" check "$FILES" > "$OUT/x64-cross-from-arm64.log" 2>&1; record x64-cross-from-arm64 "$OUT/x64-cross-from-arm64.log"
    ;;
  *) echo "mode must be make or check" >&2; exit 2 ;;
esac
exit 0
