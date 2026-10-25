#!/bin/bash
# files.sh <qnsqy> <mode> [dir]: password encryption on this CPU. Every run
# has an empty HOME; the caller runs this with no network (unshare -n).
#   sizes   round trips of edge sizes (0, 1, 4095, 4096, 4097 bytes, 1 MiB + 1,
#           64 MiB), a changed byte and a wrong password refused
#   stress  20 round trips of a 64 MiB file (decrypt's worker threads)
#   speed   encrypt and decrypt 256 MiB, hash 1 GiB: times only
#   make    encrypt 1 MiB and 64 MiB files into <dir> for the other CPU type
#   check   decrypt the other CPU type's files in <dir>, compare by SHA-256
set -u
Q="$1" MODE="$2" DIR="${3:-}"
r() { echo "RESULT|$1|$2|$3"; }
W="$(mktemp -d)"; cd "$W" || exit 1
export HOME="$W" XDG_CONFIG_HOME="$W/.config" XDG_DATA_HOME="$W/.local/share" XDG_CACHE_HOME="$W/.cache"
PW='Arm64-hardware-test-pass-7351!'   # test data only
enc() { printf '%s\n%s\n' "$PW" "$PW" | timeout 600 "$Q" encrypt --password-stdin -y --no-audit -i "$1" -o "$2" > "$2.log" 2>&1; }
dec() { printf '%s\n' "${3:-$PW}" | timeout 600 "$Q" decrypt --password-stdin -y --no-audit -i "$1" -o "$2" > "$2.log" 2>&1; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
panic() { grep -qE 'panicked at|Segmentation|core dumped|SIGILL|Illegal instruction' "$@" 2>/dev/null; }
now() { date +%s.%N; }
mibs() { awk -v b="$1" -v s="$2" -v e="$3" 'BEGIN { t = e - s; printf "%.2f s, %.0f MiB/s", t, (b / 1048576) / (t > 0 ? t : 1e-9) }'; }
case "$MODE" in
  sizes)
    for n in 0 1 4095 4096 4097 1048577 67108864; do
      head -c "$n" /dev/urandom > "p$n"
      if enc "p$n" "c$n" && dec "c$n" "o$n" && [ "$(sha "p$n")" = "$(sha "o$n")" ]; then
        r "size-$n" PASS "round trip, SHA-256 $(sha "p$n" | cut -c1-16)"
      elif [ "$n" -eq 0 ] && ! panic "c$n.log" "o$n.log"; then
        r "size-$n" INFO "empty input: $(grep -v '^\s*$' "c$n.log" "o$n.log" 2>/dev/null | tail -2 | tr '\n' ' ')"
      else
        r "size-$n" FAIL "$(grep -v '^\s*$' "c$n.log" "o$n.log" 2>/dev/null | tail -3 | tr '\n' ' ')"
      fi
    done
    cp c1048577 changed
    python3 -c 'import sys; f = open(sys.argv[1], "r+b"); f.seek(-100, 2); b = f.read(1); f.seek(-100, 2); f.write(bytes([b[0] ^ 0xFF]))' changed
    if [ "$(sha changed)" = "$(sha c1048577)" ]; then r changed-byte FAIL "the byte did not change"
    elif dec changed changed.out; then r changed-byte FAIL "decrypt accepted a changed file"
    elif panic changed.out.log; then r changed-byte FAIL "$(tail -2 changed.out.log | tr '\n' ' ')"
    else r changed-byte PASS "refused: $(grep -v '^\s*$' changed.out.log | tail -1 | cut -c1-200)"; fi
    if dec c4096 wrong.out 'Not-the-password-123!'; then r wrong-password FAIL "decrypt accepted a wrong password"
    elif panic wrong.out.log; then r wrong-password FAIL "$(tail -2 wrong.out.log | tr '\n' ' ')"
    else r wrong-password PASS "refused: $(grep -v '^\s*$' wrong.out.log | tail -1 | cut -c1-200)"; fi
    ;;
  stress)
    head -c 67108864 /dev/urandom > p; want="$(sha p)"; ok=0
    for i in $(seq 1 20); do
      rm -f c o; enc p c && dec c o && [ "$(sha o)" = "$want" ] && ok=$((ok + 1))
    done
    [ "$ok" -eq 20 ] && r stress-64mib PASS "20 of 20 round trips identical" || r stress-64mib FAIL "$ok of 20 round trips identical: $(tail -2 o.log c.log 2>/dev/null | tr '\n' ' ')"
    ;;
  speed)
    r cpu INFO "$(uname -m), $(nproc) CPUs, $( (lscpu 2>/dev/null | grep -m1 'Model name' | cut -d: -f2) | tr -s ' ')"
    head -c 268435456 /dev/urandom > p
    s="$(now)"; enc p c; e="$(now)"; r speed-encrypt-256mib INFO "$(mibs 268435456 "$s" "$e")"
    s="$(now)"; dec c o; e="$(now)"; r speed-decrypt-256mib INFO "$(mibs 268435456 "$s" "$e")"
    [ "$(sha o)" = "$(sha p)" ] || r speed-roundtrip FAIL "256 MiB round trip differs"
    rm -f c o; head -c 1073741824 /dev/urandom > big
    s="$(now)"; h="$(timeout 600 "$Q" hash big 2>/dev/null | grep -oE '^[0-9a-f]{64}' | head -1)"; e="$(now)"
    [ -n "$h" ] && r speed-hash-1gib INFO "$(mibs 1073741824 "$s" "$e")" || r speed-hash-1gib FAIL "no hash"
    ;;
  make)
    mkdir -p "$DIR"
    for n in 1048576 67108864; do
      head -c "$n" /dev/urandom > "p$n"
      if enc "p$n" "$DIR/cross-$n.qs"; then
        echo "$(sha "p$n")  cross-$n" >> "$DIR/cross.sha256"; r "make-$n" PASS "encrypted on $(uname -m)"
      else
        r "make-$n" FAIL "$(tail -2 "$DIR/cross-$n.qs.log" | tr '\n' ' ')"
      fi
      rm -f "$DIR/cross-$n.qs.log"
    done
    uname -m > "$DIR/made-on"
    ;;
  check)
    from="$(cat "$DIR/made-on" 2>/dev/null)"
    [ -s "$DIR/cross.sha256" ] || { r cross FAIL "no files from the other CPU type in $DIR"; exit 0; }
    while read -r want name; do
      if dec "$DIR/$name.qs" "$name" && [ "$(sha "$name")" = "$want" ]; then
        r "$name" PASS "made on $from, decrypted on $(uname -m), SHA-256 identical"
      else
        r "$name" FAIL "made on $from: $(tail -2 "$name.log" 2>/dev/null | tr '\n' ' ')"
      fi
    done < "$DIR/cross.sha256"
    ;;
  *) r files FAIL "unknown mode $MODE" ;;
esac
exit 0
