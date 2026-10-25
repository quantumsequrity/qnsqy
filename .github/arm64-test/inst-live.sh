#!/bin/bash
# inst-live.sh <expected version>: the one-line installer exactly as the
# download page gives it, from the live site, nothing skipped: it checks the
# package's SHA-256 against the signed list and the list's ML-DSA-87
# signature with the program it downloaded, then installs the package.
set -u
. /qs/common.sh
. /etc/os-release
r os INFO "$PRETTY_NAME"
pm_prepare
# install.sh needs curl, sha256sum and awk; minimal images can lack curl and awk.
command -v curl >/dev/null 2>&1 || { pm_install_tools curl ca-certificates; r curl INFO "curl installed first (the one-liner needs it)"; }
command -v awk >/dev/null 2>&1 || { pm_install_tools gawk; r awk INFO "awk installed first (install.sh needs it; this image lacks it)"; }
out="$(set -o pipefail; curl -fsSL https://quantumsequrity.com/downloads/install.sh | bash 2>&1)"; rc=$?
echo "$out"
if [ "$rc" -eq 0 ] && pkg_version | grep -q -- "$1"; then
  r inst PASS "$(pkg_version)"
else
  r inst FAIL "rc=$rc $(pkg_version) $(echo "$out" | grep -iE 'error|refus|fail|tamper' | tail -3 | tr '\n' ' ')"
fi
if echo "$out" | grep -q 'RELEASE_SIGNATURE_OK' && echo "$out" | grep -q 'Post-quantum release signature verified'; then
  r inst-signature PASS "$(echo "$out" | grep -m1 'Release signature VALID' | tr -s ' ')"
else
  r inst-signature FAIL "the installer did not report a verified ML-DSA-87 signature"
fi
