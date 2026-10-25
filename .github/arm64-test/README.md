# ARM64 hardware test

The workflow `arm64-hardware-test` (run by hand from the Actions tab) tests the current public Linux release of QNSQY on real ARM64 CPUs, GitHub's arm64 runners, with the checks we run before every release. It downloads only the public release files and needs no secrets.

- `fetch.sh`: the release files from the CDN, each checked against the published SHA-256 list.
- `distro.sh`: one distribution in Docker, 13 in all: install from the live repository with signature checks on (`pm.sh`), offline smoke checks (`smoke.sh`), the same checks with the bare program, and the one-line installer from the live site (`inst-live.sh`).
- `host.sh`: the runner itself: both signed SHA-256 lists verified with ML-DSA-87 (with the key built into the program and with the key published on the website), a changed list and a changed signature refused, the smoke checks for the packaged and the static program, the file sandbox probe (`landlock-probe.sh`), edge sizes, 20 round trips of 64 MiB, speed, and files encrypted on x86_64 decrypted here (`files.sh`).
- `x64.sh`: the x86_64 side: files for the ARM64 job, and decrypting the files the ARM64 job made.
- `gui.sh`: the desktop app on X11 (Xvfb) and on Wayland (Weston, headless), with no network.
- `alpine.sh`: the static build on Alpine Linux.
- `summary.sh`: every result in one table; the run fails if any check fails.

Every program run uses an empty HOME and, apart from the installs, no network.

`common.sh`, `pm.sh` and `smoke.sh` are the scripts our release test matrix runs in its containers.
