# QNSQY

Post-quantum cryptography tool, NIST FIPS 203 / 204 / 205.

QNSQY ships ML-KEM (FIPS 203), ML-DSA (FIPS 204), and SLH-DSA (FIPS 205)
hybridized with X25519, Ed25519, and AES-256-GCM. The single binary
covers encrypt, decrypt, sign, verify, hash, keygen, threshold, and
escrow operations. File content, passwords, and private keys never leave
the machine. Network access is restricted to billing metadata only,
enforced by seccomp-bpf on Linux. 84 MCP tools are exposed for AI agents
over JSON-RPC 2.0 stdio.

## Install

Install globally:

```
npm install -g qnsqy
```

Run once without installing:

```
npx qnsqy --help
```

The matching prebuilt binary for your platform is installed automatically
by npm as an optional dependency (`@quantumsequrity/qnsqy-linux-x64` or
`@quantumsequrity/qnsqy-win32-x64`), selected by its `os` / `cpu` fields.
There is no install script and no network download of our own: npm fetches
only the one platform package that matches your machine, from the npm
registry. Because no install script is involved,
`npm install --ignore-scripts` works too.

## Quick start

```
# Encrypt a file. The default algorithm is ML-KEM-512 + X25519 hybrid.
# The output is secret.pdf.qs.
qnsqy encrypt -i secret.pdf

# Decrypt.
qnsqy decrypt -i secret.pdf.qs

# Generate a hybrid signing keypair (ML-DSA-44 + Ed25519).
qnsqy keygen-sign -o mykey -n "My Signing Key"

# Sign a file.
qnsqy sign -i report.txt -k mykey

# Verify a signature.
qnsqy verify -i report.txt -k mykey.pub

# BLAKE3 hash a file.
qnsqy hash -i secret.pdf

# Show version and tier.
qnsqy version
```

For the full command list, run `qnsqy --help` or see
https://quantumsequrity.com/docs.html.

## Platforms

| Platform        | Status                                                                           |
|-----------------|----------------------------------------------------------------------------------|
| Linux x86_64    | Supported. Requires glibc 2.35+ (Ubuntu 22.04+, Debian 12+, Fedora 40+, AlmaLinux 10). |
| Windows x86_64  | Supported. Windows 10 1809+ and Windows 11.                                      |
| macOS           | Not shipping yet. Target Q3 2026. `npm install` succeeds; `qnsqy` prints a not-yet-shipping message at run time. |
| ARM (any OS)    | Not shipping yet. `npm install` succeeds; `qnsqy` prints a not-yet-shipping message at run time. |

On an unsupported platform, `npm install qnsqy` still succeeds (the main
package installs everywhere), but no platform binary matches your machine,
so running `qnsqy` prints a clear message that the platform is not yet
shipping. If instead you see that message on a supported platform, you
likely installed with optional dependencies disabled: reinstall with
`npm install qnsqy --include=optional`.

## How this package works

The main `qnsqy` package is a thin JavaScript shim. No binary is bundled
in it and it runs no install script. The binary ships in two
platform-specific packages that the main package lists as optional
dependencies:

| Package                            | For            |
|------------------------------------|----------------|
| `@quantumsequrity/qnsqy-linux-x64` | Linux x86_64   |
| `@quantumsequrity/qnsqy-win32-x64` | Windows x86_64 |

1. `npm install -g qnsqy` reads the main package's `optionalDependencies`.
2. npm evaluates each platform package's `os` / `cpu` fields and downloads
   only the one that matches your machine, from the npm registry. The
   others are skipped. No install script and no network fetch of our own
   are involved, so this works even under `npm install --ignore-scripts`.
3. `node_modules/.bin/qnsqy` is a Node shim (`bin/qnsqy.js`) that resolves
   the binary out of the installed platform package and execs it with your
   arguments, propagating exit codes and signals.

The wrapper has zero third-party npm dependencies and uses Node 18+ stdlib
only (`fs`, `path`, `child_process`). The platform packages contain only
the raw binary plus metadata: no code, no scripts.

On the npm channel, binary integrity rests on the npm registry's tarball
checksums (recorded in your lockfile). The same binary bytes are published
on the CDN with SHA-256 checksums and an ML-DSA-87 signature logged to the
Sigstore Rekor transparency log (see the download page), and the QNSQY
binary self-verifies its embedded integrity hash at startup.

## Air-gapped install

If your machine cannot reach the npm registry for the platform package, or
you want to run a specific pre-staged binary, set the `QNSQY_BINARY_PATH`
env var. The shim honours it at run time, ahead of the platform package:

```
# 1. On a connected machine, download the binary for the target platform
#    from https://quantumsequrity.com/download and verify its SHA-256.
# 2. Copy it to the air-gapped machine (USB, internal mirror, etc.).
# 3. Install the wrapper. The platform package may be skipped if the
#    registry is unreachable; that is fine, the env var takes over:

npm install -g qnsqy            # or: npm install -g --ignore-scripts qnsqy

# 4. Run qnsqy with the env var pointing at your pre-staged binary:

QNSQY_BINARY_PATH=/path/to/qnsqy qnsqy version
```

`QNSQY_BINARY_PATH` must be a real regular file; symlinks are rejected. No
SHA-256 check is performed on that path, so you are responsible for
verifying the binary out-of-band before staging it. To make it permanent,
export `QNSQY_BINARY_PATH` from your shell profile or service unit.

## Verification

You can verify the binary manually against the official checksums on the
download page.

```
# Linux DEB
sha256sum qnsqy_7.2.20-1_amd64.deb
# Expected:
# 93caee47f8af7c09f73373771ab116019d04903d6958369e865c77638e600afc

# Windows standalone
certutil -hashfile qnsqy-7.2.20-x86_64.exe SHA256
# Expected:
# 1383df812dff16cc593b0caab6bbe6092184a42f212aac8d13e42ed6a52b8f38
```

The canonical hash list is published at
https://quantumsequrity.com/download under "SHA-256 Checksums".

QNSQY releases are also signed with ML-DSA-87 (NIST FIPS 204) and logged
to the Sigstore Rekor transparency log. See the download page for the
post-quantum signature verification flow.

## Tier model

QNSQY has four tiers: Free, Pro, Business, Enterprise. Tier is determined
at runtime by the billing API on first run, not at install time.
Installing via npm does not grant Pro, Business, or Enterprise access.

- Free covers ML-KEM-512 + ML-DSA-44 with no file size limit and works
  without an account. Advanced algorithms have a 100 MB per-file limit.
- Pro unlocks ML-KEM-768/1024, ML-DSA-65/87, SLH-DSA, 25 GB file limit,
  batch operations, the encrypted password vault, audit logging, and
  password rekey.
- Business adds HQC, FN-DSA, LMS, pure KEM mode, M-of-N threshold
  encryption, Shamir secret sharing, time-lock, steganography,
  deniable encryption, polyglot files, PQ migration scanning, encryption
  policy management, recipient groups, and key escrow.
- Enterprise adds air-gap license bundles, HSM integration, SLA, and a
  dedicated engineering channel.

See https://quantumsequrity.com/pricing.html for current pricing.

## Disclaimers

QNSQY uses NIST-standardized algorithms (FIPS 203 ML-KEM, FIPS 204
ML-DSA, FIPS 205 SLH-DSA, FIPS 206 draft FN-DSA, SP 800-208 LMS, RFC 9106
Argon2id). The product itself holds no CMVP certificate (so is not a
FIPS 140 module), no SOC 2 attestation, no U.S. federal cloud ATO under
the standard government program, and no external HIPAA audit on file.
The vendor does not sign HIPAA Business Associate Agreements.

The distinction matters: "uses NIST algorithms" is a property of the
cryptographic primitives; "FIPS 140 validated" is a property of a
CMVP-tested cryptographic module. QNSQY is the former, not the latter.

Compliance documentation packages (control mapping, algorithm usage,
data flow) are available on request for Business tier customers as a
starting point for your internal or third-party audit.

## Links

- Homepage: https://quantumsequrity.com
- Documentation: https://quantumsequrity.com/docs.html
- Pricing: https://quantumsequrity.com/pricing.html
- Download page: https://quantumsequrity.com/download
- Contact: https://quantumsequrity.com/contact
- Security disclosure: security@quantumsequrity.com
