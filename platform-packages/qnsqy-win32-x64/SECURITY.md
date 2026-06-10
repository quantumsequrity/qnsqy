# Security Policy

## Supported Versions

We provide security updates for the latest stable release of QNSQY.

| Version | Supported          |
| ------- | ------------------ |
| v7.2.x  | :white_check_mark: |
| < v7.2  | :x:                |

## Reporting a Vulnerability

We take the security of QNSQY seriously. If you believe you have found a security vulnerability, please report it to us privately.

**Please do not open a public GitHub issue for security vulnerabilities.**

You can report vulnerabilities via:
- **Email:** security@quantumsequrity.com
- **Website:** https://quantumsequrity.com/contact

We will acknowledge receipt of your report within 48 hours and provide a timeline for remediation.

## Our Security Model

QNSQY is built on NIST-standardized post-quantum algorithms (FIPS 203, 204, 205). Our security guarantees include:
- **Zero Telemetry:** Your data and keys never leave your machine.
- **Kernel Sandboxing:** (Linux only) Seccomp-BPF and Landlock enforced by default.
- **Memory Protection:** mlock(2) used to prevent secrets from being swapped to disk.
