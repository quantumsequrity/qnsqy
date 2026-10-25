#!/bin/bash
# landlock-probe.sh <qnsqy>: does the program enforce its file sandbox
# (Landlock) on this kernel? Run as root with no network (unshare -n).
# The packaged program does not print a Landlock banner, so this looks at
# behaviour: it records its file rules only when the kernel enforces them,
# and its MCP server then refuses a file outside them. The server's own rule
# allows its working folder, so a file there can be refused only by the file
# sandbox: started in /srv/qsprobe, hashing a file there must be refused where
# the kernel has Landlock and answered where it has none. A file in HOME must
# be answered either way.
set -u
Q="$1"
r() { echo "RESULT|$1|$2|$3"; }
r kernel INFO "$(uname -r)"
abi="$(python3 -c '
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
n = libc.syscall(444, None, 0, 1)
print(n if n >= 0 else -ctypes.get_errno())' 2>&1)"
r landlock-kernel INFO "ABI $abi (a negative number is the errno: the kernel has no Landlock)"
W="$(mktemp -d)"; cd "$W" || exit 1
export HOME="$W" XDG_CONFIG_HOME="$W/.config" XDG_DATA_HOME="$W/.local/share" XDG_CACHE_HOME="$W/.cache"
head -c 4096 /dev/urandom > "$W/plain.bin"
mkdir -p /srv/qsprobe && head -c 4096 /dev/urandom > /srv/qsprobe/outside.bin
chmod 755 /srv/qsprobe && chmod 644 /srv/qsprobe/outside.bin
mcp() {  # mcp <file> <out>: initialize, initialized, then the hash tool on <file>
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"qs-arm64-probe","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"qnsqy_hash\",\"arguments\":{\"file\":\"$1\"}}}"
    sleep 8
  } | timeout 90 "$Q" --mcp > "$2" 2> "$2.err"
}
answered() { grep -q '"id":2' "$1" && grep -qE '[0-9a-f]{64}' "$1" && ! grep -q '"isError":true' "$1"; }
mcp "$W/plain.bin" "$W/home.out"
if answered "$W/home.out"; then r probe-home PASS "file in HOME: answered with a hash"; else r probe-home FAIL "$(tail -c 300 "$W/home.out" | tr '\n' ' ')"; fi
( cd /srv/qsprobe && mcp /srv/qsprobe/outside.bin "$W/cwd.out" )
if [ "$abi" -ge 1 ] 2>/dev/null; then
  if grep -q '"id":2' "$W/cwd.out" && grep -q 'Landlock' "$W/cwd.out" && ! answered "$W/cwd.out"; then
    r probe-landlock PASS "file in the working folder refused by the file sandbox: $(grep -o '[^"]*Landlock[^"]*' "$W/cwd.out" | head -1)"
  else
    r probe-landlock FAIL "kernel has Landlock ABI $abi, file outside the rules not refused: $(tail -c 400 "$W/cwd.out" | tr '\n' ' ')"
  fi
else
  if answered "$W/cwd.out"; then r probe-landlock INFO "kernel without Landlock: answered, as expected"; else r probe-landlock FAIL "$(tail -c 400 "$W/cwd.out" | tr '\n' ' ')"; fi
fi
