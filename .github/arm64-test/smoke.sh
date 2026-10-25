#!/bin/bash
# smoke.sh <qnsqy> <expected version>: offline checks with an empty HOME.
set -u
. /qs/common.sh
Q="$1" WANT="$2"
HOME="$(mktemp -d)"
export HOME XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
cd "$HOME" || exit 1
. /etc/os-release
r os INFO "$PRETTY_NAME"
r glibc INFO "$(ldd --version 2>&1 | head -1)"
r kernel INFO "$(uname -r)"
out="$(timeout 60 "$Q" --version 2>&1)"; rc=$?
line="$(echo "$out" | grep -m1 -E '^qnsqy ')"
ran=0
if [ "$rc" -eq 0 ] && echo "$line" | grep -q "^qnsqy $WANT\b"; then r version PASS "$line"; ran=1; else r version FAIL "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"; fi
# The self-hash is enforced only with QNSQY_REQUIRE_INTEGRITY=1; without it a
# program whose hash no longer matches still runs silently.
iout="$(QNSQY_REQUIRE_INTEGRITY=1 timeout 60 "$Q" --version 2>&1)"; irc=$?
if [ "$ran" -ne 1 ]; then r integrity FAIL "binary did not run"
elif echo "$out" | grep -q 'INTEGRITY VERIFICATION UNAVAILABLE'; then r integrity FAIL "hash slot not patched"
elif [ "$irc" -ne 0 ]; then r integrity FAIL "self-hash check failed with QNSQY_REQUIRE_INTEGRITY=1 (rc=$irc): $(echo "$iout" | grep -v '^\s*$' | tail -2 | tr '\n' ' ')"
else r integrity PASS "self-hash verified (QNSQY_REQUIRE_INTEGRITY=1)"; fi
out="$(timeout 60 "$Q" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^Usage:'; then r help PASS ""; else r help FAIL "rc=$rc $(echo "$out" | tail -2 | tr '\n' ' ')"; fi
head -c 300000 /dev/urandom > plain.bin
PW='Matrix-test-pass-4821!'
eout="$(printf '%s\n%s\n' "$PW" "$PW" | timeout 180 "$Q" encrypt --password-stdin -y --no-audit -i plain.bin -o plain.bin.qs 2>&1)"; erc=$?
dout="$(printf '%s\n' "$PW" | timeout 180 "$Q" decrypt --password-stdin -y --no-audit -i plain.bin.qs -o out.bin 2>&1)"; drc=$?
a="$(sha256sum plain.bin | cut -d' ' -f1)"; b="$(sha256sum out.bin 2>/dev/null | cut -d' ' -f1)"
if [ "$erc" -eq 0 ] && [ "$drc" -eq 0 ] && [ "$a" = "$b" ]; then r roundtrip PASS "SHA-256 $a"; else r roundtrip FAIL "encrypt rc=$erc decrypt rc=$drc $(echo "$eout$dout" | grep -v '^\s*$' | tail -3 | tr '\n' ' ')"; fi
for o in "$eout" "$dout"; do
  echo "$o" | grep -q 'SECURITY|sandbox_applied|phase=1|enforced=true' || { r sandbox FAIL "no enforced phase 1 sandbox line: $(echo "$o" | grep 'SECURITY|' | tr '\n' ' ')"; break; }
  echo "$o" | grep -q 'SECURITY|network_dropped|phase=2|enforced=true' || { r sandbox FAIL "no enforced network drop line: $(echo "$o" | grep 'SECURITY|' | tr '\n' ' ')"; break; }
done
echo "$eout" | grep -q 'SECURITY|network_dropped|phase=2|enforced=true' && echo "$dout" | grep -q 'SECURITY|network_dropped|phase=2|enforced=true' \
  && echo "$eout" | grep -q 'SECURITY|sandbox_applied|phase=1|enforced=true' && r sandbox PASS "$(echo "$eout" | grep -m1 'network_dropped')"
h1="$(timeout 60 "$Q" hash plain.bin 2>/dev/null | grep -oE '^[0-9a-f]{64}' | head -1)"
h2="$(timeout 60 "$Q" hash plain.bin 2>/dev/null | grep -oE '^[0-9a-f]{64}' | head -1)"
if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then r hash PASS "BLAKE3 $h1"; else r hash FAIL "'$h1' '$h2'"; fi
ln -sf "$Q" "$HOME/qnsqy-tui"
tout="$(timeout 30 "$HOME/qnsqy-tui" --help </dev/null 2>&1)"; trc=$?
if [ "$trc" -lt 124 ] && [ -n "$tout" ] && ! echo "$tout" | grep -qE 'panicked at|not found \(required by|error while loading shared libraries'; then
  r tui PASS "started and exited (rc=$trc) without a terminal"
else
  r tui FAIL "rc=$trc $(echo "$tout" | tail -2 | tr '\n' ' ')"
fi
