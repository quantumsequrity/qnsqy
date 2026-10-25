r() { echo "RESULT|$1|$2|$3"; }
pm_kind() {
  if command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  elif command -v apt-get >/dev/null 2>&1; then echo apt
  else echo none; fi
}
# Keep downloaded packages in the mounted caches and skip weak dependencies
# (the GUI stack), as a headless server install would.
pm_prepare() {
  case "$(pm_kind)" in
    apt) rm -f /etc/apt/apt.conf.d/docker-clean
         printf 'APT::Install-Recommends "false";\nBinary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/90qnsqy-test
         # Debian 11 is past its end of life: deb.debian.org's bullseye-security
         # index names files its pool no longer has (404), so use the archive,
         # as such a system must. Its Release files are no longer renewed.
         if grep -q '^VERSION_CODENAME=bullseye' /etc/os-release; then
           rm -f /etc/apt/sources.list.d/debian.sources
           printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' > /etc/apt/sources.list
           echo 'Acquire::Check-Valid-Until "false";' >> /etc/apt/apt.conf.d/90qnsqy-test
         fi ;;
    zypper) sed -i 's/^#\? *solver.onlyRequires *=.*/solver.onlyRequires = true/' /etc/zypp/zypp.conf 2>/dev/null
            zypper --non-interactive modifyrepo --all --keep-packages >/dev/null 2>&1 ;;
    dnf|yum) for f in /etc/dnf/dnf.conf /etc/yum.conf; do
               [ -f "$f" ] && printf 'install_weak_deps=False\nkeepcache=True\n' >> "$f"
             done ;;
  esac
}
pm_install_tools() {   # pm_install_tools <pkg>...: tools the documented steps need
  local rc
  case "$(pm_kind)" in
    apt) { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; } > /tmp/pm-tools.log 2>&1 ;;
    zypper) zypper --non-interactive install "$@" > /tmp/pm-tools.log 2>&1 ;;
    dnf) dnf -y install "$@" > /tmp/pm-tools.log 2>&1 ;;
    yum) yum -y install "$@" > /tmp/pm-tools.log 2>&1 ;;
  esac
  rc=$?
  [ "$rc" -eq 0 ] || { echo "pm_install_tools $* failed (rc=$rc):"; tail -5 /tmp/pm-tools.log; }
  return "$rc"
}
pkg_version() {
  if command -v rpm >/dev/null 2>&1 && rpm -q qnsqy >/dev/null 2>&1; then rpm -q qnsqy
  elif command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f='${Package} ${Version}\n' qnsqy 2>/dev/null
  fi
}
