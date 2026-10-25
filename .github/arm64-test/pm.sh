#!/bin/bash
# pm.sh <repo-url> <rpm-key-file> <deb-key-file>
set -u
. /qs/common.sh
URL="$1" RKEY="$2" DKEY="$3"
. /etc/os-release
r os INFO "$PRETTY_NAME"
KIND="$(pm_kind)"
r pm INFO "$KIND"
pm_prepare
# The package caches are kept between runs; a fresh install must not reuse an
# earlier run's qnsqy metadata or the repository key that run imported.
rm -rf /var/cache/dnf/qnsqy-* /var/cache/libdnf5/qnsqy-* /var/cache/yum/*/*/qnsqy \
       /var/cache/zypp/raw/qnsqy /var/cache/zypp/solv/qnsqy \
       /var/lib/apt/lists/_repo_* /var/lib/apt/lists/*quantumsequrity* 2>/dev/null
case "$KIND" in
  dnf|yum)
    cat > /etc/yum.repos.d/qnsqy.repo <<REPO
[qnsqy]
name=QNSQY
baseurl=$URL/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$URL/$RKEY
REPO
    out="$($KIND -y install qnsqy 2>&1)"; rc=$?
    ;;
  zypper)
    cat > /etc/zypp/repos.d/qnsqy.repo <<REPO
[qnsqy]
name=QNSQY
baseurl=$URL/rpm
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
repo_gpgcheck=1
pkg_gpgcheck=1
gpgkey=$URL/$RKEY
REPO
    out="$(zypper --non-interactive --gpg-auto-import-keys install qnsqy 2>&1)"; rc=$?
    ;;
  apt)
    # The download page's steps: curl the key, gpg --dearmor, signed-by.
    command -v curl >/dev/null && command -v gpg >/dev/null || pm_install_tools curl ca-certificates gnupg
    curl -fsSL "$URL/$DKEY" | gpg --dearmor -o /usr/share/keyrings/qnsqy.gpg
    echo "deb [signed-by=/usr/share/keyrings/qnsqy.gpg] $URL/deb stable main" > /etc/apt/sources.list.d/qnsqy.list
    upd="$(apt-get update 2>&1)"
    echo "$upd"
    if echo "$upd" | grep -iE 'qnsqy|/repo' | grep -qiE 'NO_PUBKEY|not signed|signature|EXPKEYSIG|BADSIG|^E:|^W:'; then
      r apt-signature FAIL "$(echo "$upd" | grep -iE 'NO_PUBKEY|not signed|signature|^E:|^W:' | head -2 | tr '\n' ' ')"
    else
      r apt-signature PASS "InRelease verified with signed-by"
    fi
    out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y qnsqy 2>&1)"; rc=$?
    ;;
  *) r pm-install FAIL "no package manager found"; exit 0 ;;
esac
echo "$out"
if [ "$rc" -eq 0 ] && [ -n "$(pkg_version)" ]; then
  r pm-install PASS "$(pkg_version) with signature checks on"
else
  r pm-install FAIL "rc=$rc: $(echo "$out" | grep -iE 'error|fail|signature|key|nothing provides|requires' | tail -3 | tr '\n' ' ')"
  exit 0
fi
echo "$out" | grep -iE 'Importing (GPG|OpenPGP) key|imported|0x939D0A89|3E4EC494939D0A89|trust' | head -5 | while read -r l; do r key-import INFO "$l"; done
if command -v rpm >/dev/null 2>&1 && rpm -q qnsqy >/dev/null 2>&1; then
  r rpm-signature INFO "$(rpm -q --qf '%{RSAHEADER:pgpsig}|%{DSAHEADER:pgpsig}' qnsqy)"
fi
# Post-install script results
[ -x /usr/bin/qnsqy ] && r bin-installed PASS "/usr/bin/qnsqy" || r bin-installed FAIL "/usr/bin/qnsqy missing"
for l in qnsqy-gui qnsqy-tui qnsqy-mcp; do
  if [ "$(readlink /usr/bin/$l)" = /usr/bin/qnsqy ]; then r "symlink-$l" PASS ""; else r "symlink-$l" FAIL "$(ls -l /usr/bin/$l 2>&1)"; fi
done
[ -f /usr/share/applications/qnsqy.desktop ] && r desktop-file PASS "" || r desktop-file FAIL "missing"
if [ -f /usr/share/mime/packages/qnsqy-encrypted.xml ]; then
  if command -v update-mime-database >/dev/null 2>&1; then
    if grep -qx 'application/x-qnsqy-encrypted' /usr/share/mime/types 2>/dev/null; then r mime-type PASS "registered"; else r mime-type FAIL "update-mime-database present, type not registered"; fi
  else
    r mime-type INFO "definition installed; update-mime-database absent (shared-mime-info not installed)"
  fi
else
  r mime-type FAIL "MIME definition missing"
fi
