const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repoRoot = path.resolve(__dirname, '..');
const installScript = path.join(repoRoot, 'install-devlab.sh');

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'devlab-install-test-'));
}

function writeExecutable(filePath, content) {
  fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function makeStubBin(dir) {
  const binDir = path.join(dir, 'bin');
  fs.mkdirSync(binDir, { recursive: true });

  writeExecutable(path.join(binDir, 'node'), '#!/usr/bin/env bash\necho v22.0.0\n');
  writeExecutable(path.join(binDir, 'launchctl'), '#!/usr/bin/env bash\nexit 0\n');
  writeExecutable(path.join(binDir, 'security'), '#!/usr/bin/env bash\nexit 0\n');
  writeExecutable(path.join(binDir, 'openssl'), `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "rand" ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  exit 0
fi
keyout=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -keyout)
      keyout="$2"
      shift 2
      ;;
    -out)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'TEST-KEY\n' > "$keyout"
printf 'TEST-CERT\n' > "$out"
`);

  return binDir;
}

function runInstaller(tempHome, binDir) {
  return spawnSync('bash', [installScript], {
    cwd: repoRoot,
    env: {
      ...process.env,
      HOME: tempHome,
      PATH: `${binDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
    },
    encoding: 'utf8',
  });
}

test('installer creates expected files with secure defaults and is rerunnable', () => {
  const tempHome = makeTempDir();
  const binDir = makeStubBin(tempHome);

  const firstRun = runInstaller(tempHome, binDir);
  assert.equal(firstRun.status, 0, firstRun.stderr || firstRun.stdout);

  const devlabDir = path.join(tempHome, 'devlab');
  const configDir = path.join(devlabDir, 'config');
  const logsDir = path.join(devlabDir, 'logs');
  const plistPath = path.join(tempHome, 'Library', 'LaunchAgents', 'com.diogo.devlab.plist');
  const tokenPath = path.join(configDir, 'token');
  const certPath = path.join(configDir, 'server.cert.pem');
  const keyPath = path.join(configDir, 'server.key.pem');

  for (const requiredPath of [
    devlabDir,
    configDir,
    logsDir,
    path.join(devlabDir, 'install-devlab.sh'),
    path.join(devlabDir, 'start-devlab.sh'),
    path.join(devlabDir, 'status-devlab.sh'),
    path.join(devlabDir, 'uninstall-devlab.sh'),
    path.join(devlabDir, 'devlab-server.js'),
    path.join(devlabDir, 'enable-hotspot.applescript'),
    plistPath,
    tokenPath,
    certPath,
    keyPath,
  ]) {
    assert.equal(fs.existsSync(requiredPath), true, `${requiredPath} should exist`);
  }

  const token = fs.readFileSync(tokenPath, 'utf8').trim();
  assert.equal(token.length, 64);
  assert.match(token, /^[a-f0-9]+$/);

  const tokenMode = fs.statSync(tokenPath).mode & 0o777;
  assert.equal(tokenMode, 0o600);

  const plist = fs.readFileSync(plistPath, 'utf8');
  assert.match(plist, /<string>127\.0\.0\.1<\/string>/);
  assert.match(plist, /<key>ENABLE_TLS<\/key>/);
  assert.match(plist, /<string>1<\/string>/);
  assert.match(plist, /<key>SHARE_SERVICE<\/key>/);
  assert.match(plist, /<string>0<\/string>/);

  const generatedStart = fs.readFileSync(path.join(devlabDir, 'start-devlab.sh'), 'utf8');
  assert.match(generatedStart, /BIND_ADDR="\$\{BIND_ADDR:-127\.0\.0\.1\}"/);
  assert.match(generatedStart, /ENABLE_TLS="\$\{ENABLE_TLS:-1\}"/);

  const secondRun = runInstaller(tempHome, binDir);
  assert.equal(secondRun.status, 0, secondRun.stderr || secondRun.stdout);
  const tokenAfterSecondRun = fs.readFileSync(tokenPath, 'utf8').trim();
  assert.equal(tokenAfterSecondRun, token);
});
