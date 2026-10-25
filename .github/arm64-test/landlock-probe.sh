#!/bin/bash
# landlock-probe.sh <qnsqy> [--home-only]: does the program enforce its file
# sandbox (Landlock) on this kernel, and does it still read what it should?
# Run with no network (unshare -n). As root it also runs the working-folder
# probe; --home-only (any user) runs only the checks that need no root.
# The packaged program does not print a Landlock banner, so this looks at
# behaviour: it records its file rules only when the kernel enforces them,
# and its MCP server then refuses a file outside them. The server's own rule
# allows its working folder, so a file there can be refused only by the file
# sandbox: started in /srv/qsprobe, hashing a file there must be refused where
# the kernel has Landlock and answered where it has none. A file in HOME must
# be answered either way, by the MCP server and by the command line.
set -u
Q="$1" MODE="${2:-}"
r() { echo "RESULT|$1|$2|$3"; }
# As root, use a root-owned copy, as a package install has: run as root, the
# program does not let its MCP server start a program file another user owns.
if [ "$(id -u)" -eq 0 ]; then install -m 755 -o root -g root "$Q" /usr/local/bin/qnsqy-probe && Q=/usr/local/bin/qnsqy-probe; fi
abi="$(python3 -c '
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
n = libc.syscall(444, None, 0, 1)
print(n if n >= 0 else -ctypes.get_errno())' 2>&1)"
W="$(mktemp -d)"; cd "$W" || exit 1
export HOME="$W" XDG_CONFIG_HOME="$W/.config" XDG_DATA_HOME="$W/.local/share" XDG_CACHE_HOME="$W/.cache"
r context INFO "uid $(id -u), kernel $(uname -r), Landlock ABI $abi, HOME=$W on $(findmnt -no FSTYPE,OPTIONS -T "$W" 2>/dev/null | head -1), TMPDIR=${TMPDIR:-unset}, apparmor $(cat /proc/self/attr/apparmor/current 2>/dev/null || cat /proc/self/attr/current 2>/dev/null)"
r dirs INFO "$(ls -ld /tmp "$W" 2>&1 | awk '{print $1, $3, $NF}' | tr '\n' ';')"
head -c 4096 /dev/urandom > "$W/plain.bin"
T="$(mktemp /tmp/qsprobe-XXXXXX.bin)"; head -c 4096 /dev/urandom > "$T"; chmod 644 "$T"
mcp() {  # mcp <file> <out>: initialize, initialized, then the hash tool on <file>
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"qs-arm64-probe","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"qnsqy_hash\",\"arguments\":{\"file\":\"$1\"}}}"
    sleep 8
  } | timeout 90 "$Q" --mcp > "$2" 2> "$2.err"
}
answered() { grep -q '"id":2' "$1" && grep -qE '[0-9a-f]{64}' "$1" && ! grep -q '"isError":true' "$1"; }
said() { grep '"id":2' "$1" | head -1 | cut -c1-300; }
mcp "$W/plain.bin" "$W/home.out"
if answered "$W/home.out"; then r probe-home PASS "file in HOME: answered with a hash"; else r probe-home FAIL "file in HOME: $(said "$W/home.out")"; fi
r probe-home-stderr INFO "$(grep -iE 'SECURITY|landlock|sandbox|denied' "$W/home.out.err" | head -4 | tr '\n' ' ' | cut -c1-400)"
mcp "$T" "$W/tmp.out"
# The MCP server's own rule allows only its working folder and HOME, so this
# one is for the record: which rule answers (its own, or the file sandbox).
if answered "$W/tmp.out"; then r probe-tmp INFO "file in /tmp: answered"; else r probe-tmp INFO "file in /tmp: $(said "$W/tmp.out")"; fi
h="$(printf '' | timeout 60 "$Q" hash "$W/plain.bin" 2> "$W/cli.err" | grep -oE '^[0-9a-f]{64}' | head -1)"
if [ -n "$h" ]; then r cli-hash-home PASS "command line, file in HOME: $h"; else r cli-hash-home FAIL "command line, file in HOME: $(grep -v '^\s*$' "$W/cli.err" | tail -2 | tr '\n' ' ')"; fi
rm -f "$T"
[ "$MODE" = --home-only ] && exit 0
mkdir -p /srv/qsprobe && head -c 4096 /dev/urandom > /srv/qsprobe/outside.bin
chmod 755 /srv/qsprobe && chmod 644 /srv/qsprobe/outside.bin
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
