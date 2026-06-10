# @quantumsequrity/qnsqy-win32-x64

Prebuilt [QNSQY](https://www.npmjs.com/package/qnsqy) binary for **Windows
x86_64** (Windows 10 1809+ / Windows 11). QNSQY is a post-quantum
cryptography tool built on NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), and
FIPS 205 (SLH-DSA), hybridized with X25519, Ed25519, and AES-256-GCM.

## Do not install this package directly

This package only carries the platform binary. It is pulled in
automatically as an `optionalDependencies` entry of the main `qnsqy`
package, so `npm` downloads only the binary that matches your platform
(selected by the `os` / `cpu` fields). It contains **no install scripts
and makes no network calls** during installation.

Install the main package instead:

```bash
npm install -g qnsqy
qnsqy --help
```

## What the binary does

One executable, four run modes: command line (`qnsqy`), terminal UI
(`qnsqy --tui`), desktop GUI (`qnsqy --gui`), and an MCP server for AI
agents (`qnsqy --mcp`, 84 tools). Core operations:

- **Encrypt / decrypt** with hybrid post-quantum envelopes: ML-KEM
  (512/768/1024) combined with X25519, sealed with AES-256-GCM or
  XChaCha20-Poly1305, passwords stretched with Argon2id.
- **Sign / verify** with ML-DSA (44/65/87) combined with Ed25519, plus
  SLH-DSA, FN-DSA, and LMS / HSS (SP 800-208) on higher tiers.
- **Hash / verify-integrity** with BLAKE3, SHA-2, and SHA-3.
- **Key tools**: keygen, key import/export, password vault,
  multi-recipient encryption, M-of-N threshold encryption, Shamir secret
  sharing, key escrow, time-lock encryption.
- **Migration**: scan data for legacy classical cryptography and
  re-encrypt it under post-quantum algorithms.
- **Audit logging** with hash-chained entries and SIEM/CSV/JSON export.

All cryptographic operations run locally. Plaintext, passwords, and
private keys never leave the machine.

## Integrity model (defense in depth)

1. **npm shim pinning.** The main `qnsqy` package ships
   `bin/integrity.json` with the SHA-256 of this binary. The shim
   verifies the hash before every run and refuses to execute a
   substituted or tampered binary.
2. **Startup self-check.** The binary verifies its own embedded
   integrity hash at startup.
3. **Release manifest signature.** The same bytes are published on the
   download page and listed in `checksums.txt`, which is signed with an
   **ML-DSA-87 (FIPS 204, security category 5)** post-quantum signature
   made with an offline release key. Verify with any QNSQY install:
   `qnsqy verify-release checksums.txt checksums.txt.sig`
4. **Sigstore transparency log.** The release manifest is additionally
   signed keylessly from the public GitHub repository's CI identity and
   recorded in the Sigstore Rekor transparency log, so the release
   history is publicly auditable.

Manual hash check on Windows:

```
certutil -hashfile node_modules\@quantumsequrity\qnsqy-win32-x64\qnsqy.exe SHA256
:: Compare against the Windows checksum on https://quantumsequrity.com/download
```

## Supported platforms

| Target | Status |
|--------|--------|
| Windows 10 1809+ x86_64 | supported (this package) |
| Windows 11 x86_64 | supported (this package) |
| Linux x86_64, glibc 2.35+ | use `@quantumsequrity/qnsqy-linux-x64` |
| macOS | in development |

## Troubleshooting

- **"integrity mismatch" from the shim**: the binary on disk does not
  match the pinned SHA-256. Reinstall with
  `npm install -g qnsqy --force`. If it persists, treat it as a
  security signal and compare hashes against the download page.
- **Endpoint policy blocks unsigned executables**: Authenticode EV code
  signing is in progress; until then, verify the SHA-256 and the
  ML-DSA-87 release signature as above, or use a policy exception pinned
  to the published hash.
- **Running a pre-staged binary** (air-gapped or mirrored installs): set
  `QNSQY_BINARY_PATH` to an absolute path and the shim will verify and
  run that binary instead of the packaged one.
- **Version note**: the npm package version can be ahead of the binary's
  self-reported `qnsqy version` when a release only changes packaging.
  The binary version is authoritative for cryptographic behavior.

## Links

- Homepage: https://quantumsequrity.com
- Download page (checksums + post-quantum signatures): https://quantumsequrity.com/download
- Documentation: https://quantumsequrity.com/docs.html
- Wrapper source: https://github.com/quantumsequrity/qnsqy
- Issues: https://github.com/quantumsequrity/qnsqy/issues
- Security disclosure: security@quantumsequrity.com

## License

Proprietary. (c) 2026 Quantum Sequrity. See the bundled `LICENSE`.
Source access for security audit is available on request.
