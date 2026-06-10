#!/usr/bin/env node
'use strict';

// QNSQY shim. Resolves the platform binary that npm installed as an
// optional dependency (@quantumsequrity/qnsqy-<platform>-<arch>) and execs
// it with the user's argv. Exit code and signals propagate.
//
// There is NO install script and NO network access. The binary arrives
// purely through npm dependency resolution, so it is present even under
// `npm install --ignore-scripts`.
//
// Integrity: the SHA-256 of each platform binary is pinned in
// ./integrity.json, which ships INSIDE this (main) package, the package the
// user explicitly installed. Before exec, the shim hashes the resolved
// platform binary and refuses to run on mismatch. This anchors trust in the
// main package, so a substituted or name-squatted platform dependency cannot
// ship runnable bytes. The QNSQY_BINARY_PATH escape hatch is exempt (the
// operator vouches for that binary out-of-band).

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

// PLATFORM_PACKAGES maps `${platform}-${arch}` to the optional dependency
// that carries the prebuilt binary and the binary's filename inside it.
const PLATFORM_PACKAGES = {
  'linux-x64': { pkg: '@quantumsequrity/qnsqy-linux-x64', bin: 'qnsqy' },
  'win32-x64': { pkg: '@quantumsequrity/qnsqy-win32-x64', bin: 'qnsqy.exe' },
};

function fail(msg) {
  process.stderr.write('qnsqy: ' + msg + '\n');
  process.exit(1);
}

// loadIntegrity: read the pinned per-platform hashes that ship with this
// package. Fail closed if the file is missing or unreadable.
function loadIntegrity() {
  try {
    return require('./integrity.json');
  } catch (err) {
    fail(
      'integrity manifest (integrity.json) could not be loaded: ' +
        (err && err.message ? err.message : String(err)) +
        '. This qnsqy install is corrupt; reinstall it.'
    );
  }
}

// resolveFromEnv: honour the QNSQY_BINARY_PATH escape hatch. Returns a
// real binary path or null. Rejects symlinks (a hostile value must not
// point the runtime at an arbitrary file) and requires a regular,
// executable file. No SHA-256 check applies here: the operator vouches for
// the binary out-of-band. (A residual lstat->spawn TOCTOU exists, but it is
// only exploitable by someone who already has write access to that exact
// path, i.e. who can already run code as this user.)
function resolveFromEnv() {
  const envPath = process.env.QNSQY_BINARY_PATH;
  if (!envPath) return null;
  let st;
  try {
    st = fs.lstatSync(envPath);
  } catch (err) {
    fail(
      'QNSQY_BINARY_PATH was set to "' + envPath + '" but lstat failed: ' +
        (err && err.message ? err.message : String(err))
    );
  }
  if (st.isSymbolicLink()) {
    fail('QNSQY_BINARY_PATH must not be a symlink. Resolve it to a real path and retry.');
  }
  if (!st.isFile()) {
    fail(
      'QNSQY_BINARY_PATH must be a regular file (got ' +
        (st.isDirectory() ? 'directory' : 'special file') + ').'
    );
  }
  if (process.platform !== 'win32' && !(st.mode & 0o111)) {
    fail('QNSQY_BINARY_PATH points to a non-executable file. Run: chmod +x ' + envPath);
  }
  process.stderr.write(
    'qnsqy: using QNSQY_BINARY_PATH=' + envPath +
      ' (integrity check skipped; you are responsible for verifying this binary out-of-band).\n'
  );
  return path.resolve(envPath);
}

// verifyIntegrity: hash the resolved platform binary and compare it against
// the value pinned in integrity.json. Fail closed on any mismatch or if the
// build was never provisioned with a real hash.
function verifyIntegrity(key, binPath) {
  const integrity = loadIntegrity();
  const expected = (integrity && typeof integrity[key] === 'string') ? integrity[key].toLowerCase() : '';
  if (!/^[0-9a-f]{64}$/.test(expected)) {
    fail(
      'no integrity hash is provisioned for ' + key + ' in integrity.json. This qnsqy ' +
        'build was not prepared for release (run scripts/stage-platform-packages.sh). ' +
        'Refusing to run an unverified binary.'
    );
  }
  const actual = crypto.createHash('sha256').update(fs.readFileSync(binPath)).digest('hex');
  let match = false;
  try {
    match = crypto.timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'));
  } catch (_) {
    match = false;
  }
  if (!match) {
    fail(
      'binary integrity check FAILED for ' + PLATFORM_PACKAGES[key].pkg + '.\n' +
        '  expected sha256: ' + expected + '\n' +
        '  actual sha256:   ' + actual + '\n' +
        'The installed platform binary does not match the hash pinned in the qnsqy ' +
        'package. This can indicate a tampered or substituted dependency. Refusing to ' +
        'run. Report to security@quantumsequrity.com.'
    );
  }
}

// resolvePlatformBinary: find the binary inside the installed optional
// dependency. Resolving the package's package.json (always resolvable when
// the package is present, regardless of `exports`) and joining the binary
// name is the robust pattern esbuild and @swc/core use. Verifies integrity
// before returning.
function resolvePlatformBinary() {
  const key = process.platform + '-' + process.arch;
  const entry = PLATFORM_PACKAGES[key];
  if (!entry) {
    fail(
      'no prebuilt QNSQY binary is published for ' + process.platform + '/' +
        process.arch + '.\n' +
        'qnsqy: shipping targets today are Linux x86_64 and Windows x86_64. ' +
        'macOS is targeted for Q3 2026; ARM is not yet shipping. ' +
        'See https://quantumsequrity.com/download for status.\n' +
        'qnsqy: for a pre-staged binary, set QNSQY_BINARY_PATH=/path/to/qnsqy and re-run.'
    );
  }
  let pkgJson;
  try {
    pkgJson = require.resolve(entry.pkg + '/package.json');
  } catch (_) {
    fail(
      'the platform package "' + entry.pkg + '" is not installed.\n' +
        'qnsqy: this happens when npm skipped optional dependencies. Reinstall with:\n' +
        '  npm install qnsqy --include=optional\n' +
        'qnsqy: (also check you did not pass --no-optional / --omit=optional, and that ' +
        'any lockfile was generated with optional dependencies enabled).\n' +
        'qnsqy: or set QNSQY_BINARY_PATH=/path/to/qnsqy for an air-gapped install.'
    );
  }
  const binPath = path.join(path.dirname(pkgJson), entry.bin);
  if (!fs.existsSync(binPath)) {
    fail(
      'platform package "' + entry.pkg + '" is installed but its binary is missing at ' +
        binPath + '.\n' +
        'qnsqy: if you use Yarn in PnP (plug-n-play) mode, ensure the platform package is ' +
        'unplugged (it sets preferUnplugged: true; rerun `yarn install`) or set ' +
        'nodeLinker: node-modules in .yarnrc.yml.\n' +
        'qnsqy: otherwise reinstall qnsqy, or report at https://quantumsequrity.com/contact.'
    );
  }
  verifyIntegrity(key, binPath);
  return binPath;
}

const binPath = resolveFromEnv() || resolvePlatformBinary();

const child = spawn(binPath, process.argv.slice(2), { stdio: 'inherit' });

function forwardSignal(sig) {
  if (child && child.pid && !child.killed) {
    try {
      child.kill(sig);
    } catch (_) {
      // child may have already exited
    }
  }
}

function detachSignalListeners() {
  try { process.removeAllListeners('SIGINT'); } catch (_) {}
  try { process.removeAllListeners('SIGTERM'); } catch (_) {}
  try { process.removeAllListeners('SIGHUP'); } catch (_) {}
}

process.on('SIGINT', function onSigint() { forwardSignal('SIGINT'); });
process.on('SIGTERM', function onSigterm() { forwardSignal('SIGTERM'); });
process.on('SIGHUP', function onSighup() { forwardSignal('SIGHUP'); });

child.on('error', function (err) {
  detachSignalListeners();
  process.stderr.write(
    'qnsqy: failed to spawn ' + binPath + ': ' +
      (err && err.message ? err.message : String(err)) + '\n'
  );
  process.exit(1);
});

child.on('exit', function (code, signal) {
  detachSignalListeners();
  if (signal) {
    // Re-raise so the parent shell sees "killed by signal". A short fallback
    // timer guarantees we still exit even if the signal is intercepted or is
    // non-fatal (e.g. on Windows, where Unix signals do not terminate).
    setTimeout(function () { process.exit(1); }, 100).unref();
    try {
      process.kill(process.pid, signal);
    } catch (_) {
      process.exit(1);
    }
    return;
  }
  process.exit(typeof code === 'number' ? code : 1);
});
