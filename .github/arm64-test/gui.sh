#!/bin/bash
# gui.sh <image> <out dir>: the desktop app on this runner's CPU, in Docker.
# Step 1 (network on): qnsqy from the live repository with signature checks
# on and weak dependencies, the libraries a desktop has (X11 keyboard, EGL and
# Mesa), Xvfb, xwininfo and Weston as a headless Wayland compositor.
# Step 2 (no network, so the app cannot reach anything): without --allow-x11
# the app must refuse X11 with its message; with --allow-x11 its window must
# appear, in the foreground and started the way a user starts it (detached);
# on Weston (Wayland, the default mode) it must set its title and draw; with
# no display it must stop cleanly. A screenshot of the X11 window is kept.
set -uo pipefail
IMG="$1" OUT="$2"
REPO_URL="${REPO_URL:-https://cdn.quantumsequrity.com/repo}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
slug="$(echo "$IMG" | tr -c 'A-Za-z0-9._-' '-')"; slug="${slug%-}"
tag="qsgui-$(echo "$slug" | tr 'A-Z' 'a-z')"
LOG="$OUT/gui-$slug.log"; RES="$OUT/results.tsv"
[ -f "$RES" ] || printf 'image\tphase\tcheck\tresult\tdetail\n' > "$RES"
: > "$LOG"
for i in 1 2 3; do docker pull -q "$IMG" > /dev/null 2>&1 && break; sleep 15; done

docker run --name "$tag-inst" -e URL="$REPO_URL" "$IMG" bash -c '
  if command -v dnf > /dev/null; then
    printf "[qnsqy]\nname=QNSQY\nbaseurl=$URL/rpm\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=$URL/qnsqy-repo.gpg.asc\n" > /etc/yum.repos.d/qnsqy.repo
    dnf -y install qnsqy && echo "RESULT|gui-install|PASS|$(rpm -q qnsqy) with weak dependencies, signature checks on"
    dnf -y install xorg-x11-server-Xvfb xorg-x11-utils || dnf -y install xorg-x11-server-Xvfb xwininfo
    dnf -y install libxkbcommon-x11 mesa-libEGL mesa-libGL mesa-dri-drivers
    dnf -y install epel-release && dnf -y install weston
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y curl gnupg ca-certificates
    curl -fsSL "$URL/qnsqy-repo.gpg.asc" | gpg --dearmor -o /usr/share/keyrings/qnsqy.gpg
    echo "deb [signed-by=/usr/share/keyrings/qnsqy.gpg] $URL/deb stable main" > /etc/apt/sources.list.d/qnsqy.list
    apt-get update && apt-get install -y qnsqy && echo "RESULT|gui-install|PASS|$(dpkg-query -W -f="\${Package} \${Version}" qnsqy) with recommends, signature checks on"
    apt-get install -y xvfb x11-utils x11-apps imagemagick weston libxkbcommon-x11-0 libegl1 libgl1-mesa-dri
  fi
  command -v Xvfb > /dev/null && echo "RESULT|xvfb|INFO|present" || echo "RESULT|xvfb|FAIL|Xvfb not installed"
  command -v weston > /dev/null && echo "RESULT|weston|INFO|$(weston --version 2>&1 | head -1)" || echo "RESULT|weston|FAIL|weston not installed"
' >> "$LOG" 2>&1
docker commit "$tag-inst" "$tag:inst" > /dev/null 2>&1 || echo "RESULT|commit|FAIL|docker commit" >> "$LOG"
docker rm -f "$tag-inst" > /dev/null 2>&1

timeout --kill-after=30 900 docker run --rm --network none -v "$OUT":/out "$tag:inst" bash -c '
export HOME="$(mktemp -d)" XDG_RUNTIME_DIR="$(mktemp -d)"; chmod 700 "$XDG_RUNTIME_DIR"; cd "$HOME"
bad="panicked at|Segmentation|core dumped|error while loading shared libraries|Illegal instruction"
glog="$HOME/.local/share/qnsqy/gui.log"
guikill() { for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q "^qnsqy-gui " && kill "${p#/proc/}" 2>/dev/null; done; }
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > xvfb.log 2>&1 & sleep 4
out="$(DISPLAY=:99 timeout 30 qnsqy-gui --no-detach 2>&1)"; rc=$?
if [ "$rc" -lt 124 ] && echo "$out" | grep -q "X11" && ! echo "$out" | grep -qE "$bad"; then
  echo "RESULT|gui-x11-refused|PASS|rc=$rc $(echo "$out" | grep -m1 "X11" | tr -s " ")"
else
  echo "RESULT|gui-x11-refused|FAIL|rc=$rc $(echo "$out" | tail -3 | tr "\n" " ")"
fi
DISPLAY=:99 qnsqy-gui --no-detach --allow-x11 > gui.out 2> gui.err & pid=$!
sleep 30
if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; wait "$pid"; grc=$?; fi
win="$(DISPLAY=:99 xwininfo -root -tree 2>/dev/null | grep -iE "qnsqy|quantum" | head -3 | tr -s " " | tr "\n" " ")"
if [ "$alive" = yes ] && [ -n "$win" ]; then echo "RESULT|gui-x11-window|PASS|$win"
else echo "RESULT|gui-x11-window|FAIL|alive=$alive rc=${grc:-} window=${win:-none} $(tail -5 gui.err | tr "\n" " ")"; fi
if command -v xwd > /dev/null && command -v convert > /dev/null; then
  xwd -root -silent -display :99 | convert xwd:- /out/gui-x11.png 2>/dev/null && echo "RESULT|gui-x11-screenshot|INFO|gui-x11.png"
fi
echo "RESULT|gui-x11-stderr|INFO|$(grep -v "^\s*$" gui.err | head -6 | tr -s " " | tr "\n" " ")"
kill "$pid" 2>/dev/null; sleep 3
DISPLAY=:99 qnsqy-gui --allow-x11 > /dev/null 2>&1; prc=$?
sleep 30
win="$(DISPLAY=:99 xwininfo -root -tree 2>/dev/null | grep -iE "qnsqy|quantum" | head -3 | tr -s " " | tr "\n" " ")"
if [ "$prc" -eq 0 ] && [ -n "$win" ] && ! grep -qE "$bad" "$glog" 2>/dev/null; then echo "RESULT|gui-x11-detached|PASS|$win"
else echo "RESULT|gui-x11-detached|FAIL|parent rc=$prc window=${win:-none} log: $(tail -5 "$glog" 2>/dev/null | tr "\n" " ")"; fi
guikill; sleep 2
if command -v weston > /dev/null; then
  weston --backend=headless-backend.so --socket=wayland-1 --idle-time=0 > weston.log 2>&1 & sleep 4
  [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { weston --backend=headless --socket=wayland-1 --idle-time=0 > weston.log 2>&1 & sleep 4; }
  if [ -S "$XDG_RUNTIME_DIR/wayland-1" ]; then
    env -u DISPLAY WAYLAND_DISPLAY=wayland-1 WAYLAND_DEBUG=1 qnsqy-gui --no-detach > wl.out 2> wl.err & pid=$!
    sleep 30
    if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; wait "$pid"; grc=$?; fi
    title="$(grep -oE "xdg_toplevel@[0-9]+\.set_title\(\"[^\"]*\"\)" wl.err | head -1)"
    attach="$(grep -cE "wl_surface@[0-9]+\.attach\(wl_buffer@[0-9]+" wl.err)"
    commit="$(grep -cE "wl_surface@[0-9]+\.commit\(\)" wl.err)"
    if [ "$alive" = yes ] && echo "$title" | grep -q "QNSQY" && [ "$attach" -gt 0 ] && [ "$commit" -gt 0 ]; then
      echo "RESULT|gui-wayland|PASS|$title, $attach buffer attach(es), $commit commit(s)"
    else
      echo "RESULT|gui-wayland|FAIL|alive=$alive rc=${grc:-} title=${title:-none} attach=$attach commit=$commit $(grep -vE "^\[|wl_|xdg_|zwp_|wp_" wl.err | grep -v "^\s*$" | tail -4 | tr "\n" " ")"
    fi
    kill "$pid" 2>/dev/null; sleep 2
  else
    echo "RESULT|gui-wayland|FAIL|weston did not start: $(tail -3 weston.log | tr "\n" " ")"
  fi
fi
out="$(env -u DISPLAY -u WAYLAND_DISPLAY timeout 30 qnsqy-gui --no-detach 2>&1)"; rc=$?
if [ "$rc" -lt 124 ] && ! echo "$out" | grep -qE "$bad"; then
  echo "RESULT|gui-no-display|PASS|rc=$rc $(echo "$out" | grep -v "^\s*$" | tail -2 | tr -s " " | tr "\n" " ")"
else
  echo "RESULT|gui-no-display|FAIL|rc=$rc $(echo "$out" | tail -3 | tr "\n" " ")"
fi
' >> "$LOG" 2>&1
n=0
while IFS='|' read -r _ check res detail; do
  printf '%s\t%s\t%s\t%s\t%s\n' "$IMG" gui "$check" "$res" "$detail" >> "$RES"; n=$((n + 1))
done < <(grep -a '^RESULT|' "$LOG")
[ "$n" -gt 0 ] || printf '%s\tgui\trun\tFAIL\tno results\n' "$IMG" >> "$RES"
grep -a '^RESULT|' "$LOG" | sed 's/^RESULT|/  [gui] /' | tr '|' ' '
exit 0
