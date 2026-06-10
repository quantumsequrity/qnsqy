# Publishing the QNSQY npm packages

Operator notes for the maintainer. This file is excluded from every
published tarball (`.npmignore` + the `files` allowlist), so end users
never see it.

## Architecture: optionalDependencies, no install script

As of 7.2.21 the npm distribution uses the platform-specific
`optionalDependencies` model (the same one esbuild, @swc/core, turbo, and
biome use). There are **three** packages:

| Package                              | Contents                              | npm guard            |
|--------------------------------------|---------------------------------------|----------------------|
| `qnsqy`                              | the JS shim (`bin/qnsqy.js`) + `bin/integrity.json` | none (installs anywhere) |
| `@quantumsequrity/qnsqy-linux-x64`   | the raw Linux x86_64 binary `qnsqy`   | `os:[linux] cpu:[x64]` |
| `@quantumsequrity/qnsqy-win32-x64`   | the raw Windows x86_64 binary `qnsqy.exe` | `os:[win32] cpu:[x64]` |

The main `qnsqy` package lists the two platform packages under
`optionalDependencies`, pinned to the **exact** same version. When a user
runs `npm install qnsqy`, npm downloads only the platform package whose
`os`/`cpu` matches the host (others are silently skipped) and the shim
resolves the binary out of it. There is **no postinstall script and no
network fetch**, so:

- Socket.dev no longer flags "install scripts" or "network access".
- `npm install --ignore-scripts` works (this was broken under the old
  postinstall-download model, which hardened/air-gapped sites hit).

The platform packages are **scoped** to `@quantumsequrity`. Only the org
can publish into that scope, which removes the name-squat / dependency-
confusion risk for these and all future platform packages.

## Integrity model

`bin/integrity.json` ships inside the main `qnsqy` package (the package the
user explicitly installs) and pins the SHA-256 of each platform binary.
Before exec, `bin/qnsqy.js` hashes the resolved platform binary and refuses
to run on mismatch. Trust is anchored in the main package, so even a
compromised or substituted platform dependency cannot ship runnable bytes.

`scripts/stage-platform-packages.sh` provisions these hashes: it downloads
each artifact from `cdn.quantumsequrity.com`, SHA-256-verifies it against
`lib/manifest.json` (the same hashes the website download page publishes),
extracts the binary, computes its hash, and stamps it into
`bin/integrity.json`. The chain is: pinned manifest hash (matches website)
-> verified .deb/.exe -> deterministic extract -> inner hash -> baked into
the shipped shim. `publish-release.sh` refuses to publish if either hash is
not a real 64-hex value.

The CDN is unchanged and remains the source of truth for the website, RPM,
DEB, NSIS installer, and `curl | bash`. The npm channel now gets identical
bytes from the npm registry instead of fetching from the CDN at install
time.

## Versioning policy

- The single source of truth for the npm release version is the `version`
  field of the **main** `package.json`. `stage-platform-packages.sh` copies
  it into both platform packages and into the main package's
  `optionalDependencies`. Never edit those by hand.
- Use a **clean SemVer** (`MAJOR.MINOR.PATCH`). Do NOT carry the Debian
  package revision (`-1` from `qnsqy_7.2.20-1_amd64.deb`) into the npm
  version: `7.2.20-1` is a SemVer *prerelease*. It is not matched by caret
  ranges (`^7.2.20`) and sorts *below* `7.2.20`, so range installers keep
  the old version and `latest` looks like a downgrade. `publish-release.sh`
  refuses to push a prerelease to the `latest` dist-tag.
- When the wrapper changes but the binary does not, bump the **patch** of the
  npm version anyway (you cannot republish an existing version). This creates
  a temporary skew between the npm version and the binary version, which is
  fine functionally but should be closed at the next binary build (see
  "Version alignment" below).
- `optionalDependencies` must always be **exact** versions, never ranges.
  The lockstep check enforces this.

## Version alignment (npm version == binary version)

GOAL: `qnsqy --version` (the binary's compiled version, sourced from
`lib/manifest.json` `qnsqy_version`) should equal the npm package version, so
a user who runs `npm install qnsqy@X` and then `qnsqy --version` sees `X`.

CURRENT STATE (2026-06-05): they are intentionally **skewed**. The npm
packages are at `7.2.22` but the binary is `7.2.20`. Reason: the old
postinstall model already occupies `qnsqy@7.2.20` on npm, so the new wrapper
had to move to `7.2.21`/`7.2.22` (a clean patch above it; a `7.2.20-1`
prerelease would sort *below* `7.2.20`). The binary was never rebuilt, so it
stayed `7.2.20`. This skew is cosmetic: the shim's SHA-256 integrity check is
hash-based, not version-based, and passes regardless.

TO ALIGN at the next real binary build:
1. Build the next QNSQY binary with a version **>= the current npm latest**
   (today: `>= 7.2.23`; check `npm view qnsqy version`).
2. Update `lib/manifest.json`: new `qnsqy_version`, URLs, and pinned hashes
   from https://quantumsequrity.com/download.
3. Set the main `package.json` `version` to that **same** number.
4. Run the normal release flow. `stage-platform-packages.sh` and
   `publish-release.sh` will then report "version alignment OK" instead of a
   skew warning.

Both scripts WARN on a skew today. Once the first aligned binary ships, set
`REQUIRE_VERSION_ALIGNMENT=1` in your release environment to make any future
skew a hard error, so the versions can never silently drift apart again.

## One-time setup (do this BEFORE the first publish)

1. Own the `@quantumsequrity` scope on npm (free for public packages) on an
   account with 2FA:

   ```
   npm profile enable-2fa auth-and-writes
   ```

2. Claim the two scoped names immediately (the first release publish below
   claims them; if you want to reserve them earlier, publish a 0.0.0
   placeholder). Right after the first successful publish of each, require
   2FA at the package level:

   ```
   npm access 2fa-required @quantumsequrity/qnsqy-linux-x64
   npm access 2fa-required @quantumsequrity/qnsqy-win32-x64
   npm access 2fa-required qnsqy
   ```

3. Pre-claim scoped names for any platform you have publicly documented but
   not yet shipped (e.g. `@quantumsequrity/qnsqy-darwin-arm64`) so the name
   is reserved. With a scope you control, this is largely covered already.

## Release flow (every release)

From `npm-wrapper/`:

```
# 0. Set the release version once, in the MAIN package.json "version"
#    (clean SemVer, e.g. 7.2.21).

# 1. Stage BOTH platform binaries: download from the CDN, SHA-256-verify
#    against lib/manifest.json, extract, stamp the version everywhere, and
#    stamp bin/integrity.json with each binary's hash.
./scripts/stage-platform-packages.sh

# 2. Local clean-room test (registry-free). Must end "0 failed".
./scripts/local-clean-room-test.sh

# 3. Dry-run the publish: inspect the file list of all three tarballs and
#    run the lockstep + integrity + shim-consistency checks.
./scripts/publish-release.sh
#    - each platform package must contain ONLY its binary + package.json
#      + README + LICENSE
#    - main must contain ONLY bin/qnsqy.js + bin/integrity.json +
#      package.json + README + LICENSE (NO postinstall.js, NO lib/, NO
#      scripts/, NO platform-packages/)

# 4. Publish for real. Platform packages publish FIRST, main LAST.
#    npm prompts for your 2FA OTP per package.
./scripts/publish-release.sh --publish

# 5. Verify on the registry, then deprecate the superseded old-model version.
npm view qnsqy@<version> optionalDependencies
npm deprecate qnsqy@7.2.20 "Superseded by 7.2.21 (optionalDependencies model, no install script)."
#    On a clean machine: npm install -g qnsqy && qnsqy version
```

If `lib/manifest.json` has drifted from what the CDN actually serves, step
1 aborts with a SHA-256 mismatch. Fix the manifest from
https://quantumsequrity.com/download (and confirm the CDN binary is the
intended one) before retrying.

## Recovering from a mid-sequence publish failure

`publish-release.sh` publishes platform packages first and aborts on the
first failure, so the main package is never published against a missing
dependency. But if one platform package published and the next failed, that
one is already live at `$VERSION`. npm forbids re-publishing a version (and
forbids re-using an unpublished version for 24h), so the clean recovery is
to **bump the patch** (e.g. 7.2.21 -> 7.2.22), re-stage, and run the flow
again. Do not try to overwrite the already-published version.

## Adding a new platform later (macOS, ARM)

When a real binary exists for a new target:

1. Add the artifact (url, sha256, format, `binary_path_in_archive`) to
   `lib/manifest.json` under `platforms`.
2. Create `platform-packages/<dir>/` with a `package.json` named
   `@quantumsequrity/qnsqy-<plat>-<arch>`, the right `os`/`cpu`,
   `preferUnplugged: true`, `publishConfig.access: public`, and
   `files: ["qnsqy"]` (or `qnsqy.exe`), plus a README and LICENSE.
3. Add a `PLATFORM_PACKAGES` entry in `bin/qnsqy.js` AND a key in
   `bin/integrity.json` (the publish check fails if the shim and
   optionalDependencies disagree, or if the integrity hash is missing).
4. Add a staging branch in `scripts/stage-platform-packages.sh` and a
   `publish_one` call in `scripts/publish-release.sh`.
5. Add the new package to the main `optionalDependencies`.

## Deprecating a bad version

Never unpublish. Deprecate so existing lockfiles keep working:

```
npm deprecate qnsqy@7.2.21 "Superseded by 7.2.22."
npm deprecate @quantumsequrity/qnsqy-linux-x64@7.2.21 "Superseded by 7.2.22."
npm deprecate @quantumsequrity/qnsqy-win32-x64@7.2.21 "Superseded by 7.2.22."
```

## Deferred: provenance

For parity with the CDN channel's Rekor-logged ML-DSA-87 signature, the npm
packages should eventually publish with `npm publish --provenance` from a
CI/OIDC pipeline (GitHub Actions or GitLab CI/CD), so each tarball carries
a verifiable build attestation. This is not yet wired up (GitHub Actions is
currently billing-blocked; GitLab CI is the alternative). Provenance does
not remove the need for any of the above; it adds build-origin proof.

## Notes on the old (<= 7.2.20) model

Versions up to and including `7.2.20` used a `postinstall.js` that fetched
the binary from the CDN at install time. That code is removed.
`lib/manifest.json` is retained only as the staging input (URLs + pinned
hashes); it is no longer shipped in any published package. After publishing
7.2.21, deprecate `qnsqy@7.2.20` so range installers move to the new model.
