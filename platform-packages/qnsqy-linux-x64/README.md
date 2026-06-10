# @quantumsequrity/qnsqy-linux-x64

Prebuilt [QNSQY](https://www.npmjs.com/package/qnsqy) binary for **Linux
x86_64** (glibc 2.35+). QNSQY is a post-quantum cryptography tool built on
NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), and FIPS 205 (SLH-DSA),
hybridized with X25519, Ed25519, and AES-256-GCM.

## Do not install this package directly

This package only carries the platform binary. It is pulled in
automatically as an `optionalDependencies` entry of the main `qnsqy`
package, so `npm` downloads only the binary that matches your platform
(selected by the `os` / `cpu` fields). It contains **no install script and
makes no network calls**.

Install the main package instead:

```bash
npm install -g qnsqy
qnsqy --help
```

## Integrity

The main `qnsqy` package pins the SHA-256 of this binary and verifies it
before every run, so a substituted or tampered binary is refused. The same
bytes are published on the download page with SHA-256 checksums and an
ML-DSA-87 (FIPS 204) signature logged to the Sigstore Rekor transparency
log, and the binary self-verifies its embedded integrity hash at startup.

You can confirm the bytes match the official release:

```bash
sha256sum node_modules/@quantumsequrity/qnsqy-linux-x64/qnsqy
# Compare against the Linux checksum on https://quantumsequrity.com/download
```

## Links

- Homepage: https://quantumsequrity.com
- Download page (checksums + PQ signatures): https://quantumsequrity.com/download
- Documentation: https://quantumsequrity.com/docs.html
- Security disclosure: security@quantumsequrity.com

## License

Proprietary. (c) 2026 Quantum Sequrity. See the bundled `LICENSE`.
