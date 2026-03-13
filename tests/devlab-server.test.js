const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const { execFileSync } = require('node:child_process');
const { spawn } = require('node:child_process');

const {
  createRateLimiter,
  createServer,
  getIPv4Addresses,
  installShutdownHandlers,
  loadAuthToken,
  loadRuntimeConfig,
  main,
  startServer,
  timingSafeEqual,
} = require('../devlab-server.js');

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'devlab-test-'));
}

function writeToken(dir, token = 'a'.repeat(64)) {
  const tokenFile = path.join(dir, 'token');
  fs.writeFileSync(tokenFile, token);
  return tokenFile;
}

function writeCertPair(dir) {
  const keyFile = path.join(dir, 'server.key.pem');
  const certFile = path.join(dir, 'server.cert.pem');
  execFileSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-sha256',
    '-days',
    '1',
    '-nodes',
    '-keyout',
    keyFile,
    '-out',
    certFile,
    '-subj',
    '/CN=127.0.0.1/O=DevLabTest',
  ], { stdio: 'ignore' });
  return { keyFile, certFile };
}

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return server.address().port;
}

async function close(server) {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

async function request({ protocol, port, method = 'GET', token, rejectUnauthorized = false }) {
  const client = protocol === 'https' ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request({
      hostname: '127.0.0.1',
      port,
      path: '/',
      method,
      rejectUnauthorized,
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => resolve({ statusCode: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

test('loadRuntimeConfig applies secure defaults', () => {
  const config = loadRuntimeConfig({});
  assert.equal(config.port, 3000);
  assert.equal(config.bindAddr, '127.0.0.1');
  assert.equal(config.enableTls, true);
});

test('loadAuthToken accepts long token and rejects short token', () => {
  const dir = makeTempDir();
  const tokenFile = writeToken(dir);
  assert.equal(loadAuthToken(tokenFile), 'a'.repeat(64));

  const shortTokenFile = path.join(dir, 'short-token');
  fs.writeFileSync(shortTokenFile, 'short');
  assert.throws(() => loadAuthToken(shortTokenFile), /at least 32 chars/);
});

test('timingSafeEqual compares equal and different strings safely', () => {
  assert.equal(timingSafeEqual('abc123', 'abc123'), true);
  assert.equal(timingSafeEqual('abc123', 'abc124'), false);
  assert.equal(timingSafeEqual('short', 'longer'), false);
});

test('getIPv4Addresses filters internal, non-ipv4, and duplicate addresses', () => {
  const ips = getIPv4Addresses({
    lo0: [{ family: 'IPv4', internal: true, address: '127.0.0.1' }],
    en0: [
      { family: 'IPv4', internal: false, address: '192.168.1.20' },
      { family: 'IPv6', internal: false, address: '::1' },
    ],
    en1: [{ family: 'IPv4', internal: false, address: '192.168.1.20' }],
  });
  assert.deepEqual(ips, ['192.168.1.20']);
});

test('rate limiter enforces limit and resets after window', () => {
  const limiter = createRateLimiter(2, 1000);
  assert.equal(limiter.check('1.2.3.4', 0), true);
  assert.equal(limiter.check('1.2.3.4', 1), true);
  assert.equal(limiter.check('1.2.3.4', 2), false);
  assert.equal(limiter.check('1.2.3.4', 1002), true);
  limiter.evict(3000);
  assert.equal(limiter.state.size, 0);
});

test('https server enforces auth, methods, rate limit, and response headers', async () => {
  const dir = makeTempDir();
  const token = 'b'.repeat(64);
  const tokenFile = writeToken(dir, token);
  const { keyFile, certFile } = writeCertPair(dir);
  const rateLimiter = createRateLimiter(2, 60_000);
  const { server } = createServer({
    port: 0,
    bindAddr: '127.0.0.1',
    serviceName: 'Test Service',
    tokenFile,
    enableTls: true,
    tlsKeyFile: keyFile,
    tlsCertFile: certFile,
  }, {
    rateLimiter,
    hostname: () => 'test-host',
    networkInterfaces: () => ({ en0: [{ family: 'IPv4', internal: false, address: '10.0.0.5' }] }),
  });

  const port = await listen(server);

  const unauthorized = await request({ protocol: 'https', port, rejectUnauthorized: false });
  assert.equal(unauthorized.statusCode, 401);
  assert.match(unauthorized.headers['www-authenticate'], /Bearer/);

  const wrongMethod = await request({ protocol: 'https', port, method: 'POST', token, rejectUnauthorized: false });
  assert.equal(wrongMethod.statusCode, 405);

  const success = await request({ protocol: 'https', port, token, rejectUnauthorized: false });
  assert.equal(success.statusCode, 200);
  assert.equal(success.headers['x-content-type-options'], 'nosniff');
  assert.equal(success.headers['x-frame-options'], 'DENY');
  assert.equal(success.headers['referrer-policy'], 'no-referrer');
  assert.equal(success.headers['cache-control'], 'no-store');
  const body = JSON.parse(success.body);
  assert.equal(body.ok, true);
  assert.equal(body.service, 'Test Service');
  assert.equal(body.hostname, 'test-host');
  assert.deepEqual(body.ipv4, ['10.0.0.5']);

  const limited = await request({ protocol: 'https', port, token, rejectUnauthorized: false });
  assert.equal(limited.statusCode, 429);

  await close(server);
});

test('http mode works when TLS is disabled', async () => {
  const dir = makeTempDir();
  const token = 'c'.repeat(64);
  const tokenFile = writeToken(dir, token);
  const { server } = createServer({
    port: 0,
    bindAddr: '127.0.0.1',
    serviceName: 'Plain Service',
    tokenFile,
    enableTls: false,
    tlsKeyFile: path.join(dir, 'unused-key'),
    tlsCertFile: path.join(dir, 'unused-cert'),
  }, {
    hostname: () => 'plain-host',
    networkInterfaces: () => ({ en0: [{ family: 'IPv4', internal: false, address: '10.0.0.9' }] }),
  });

  const port = await listen(server);
  const response = await request({ protocol: 'http', port, token });
  assert.equal(response.statusCode, 200);
  const body = JSON.parse(response.body);
  assert.equal(body.hostname, 'plain-host');
  await close(server);
});

test('createServer throws when TLS assets are missing', () => {
  const dir = makeTempDir();
  const tokenFile = writeToken(dir, 'd'.repeat(64));
  assert.throws(() => createServer({
    port: 0,
    bindAddr: '127.0.0.1',
    serviceName: 'Broken TLS',
    tokenFile,
    enableTls: true,
    tlsKeyFile: path.join(dir, 'missing.key'),
    tlsCertFile: path.join(dir, 'missing.cert'),
  }), /ENOENT/);
});

test('installShutdownHandlers registers signal handlers', () => {
  const originalOn = process.on;
  const calls = [];
  process.on = (eventName, handler) => {
    calls.push({ eventName, handler });
    return process;
  };

  try {
    installShutdownHandlers({ close() {} });
  } finally {
    process.on = originalOn;
  }

  assert.deepEqual(calls.map((entry) => entry.eventName), ['SIGINT', 'SIGTERM']);
  for (const entry of calls) {
    assert.equal(typeof entry.handler, 'function');
  }
});

test('startServer listens and serves requests', async () => {
  const dir = makeTempDir();
  const token = 'e'.repeat(64);
  const tokenFile = writeToken(dir, token);
  const runtime = startServer({
    port: 0,
    bindAddr: '127.0.0.1',
    serviceName: 'Started Service',
    tokenFile,
    enableTls: false,
    tlsKeyFile: path.join(dir, 'unused-key'),
    tlsCertFile: path.join(dir, 'unused-cert'),
  }, {
    hostname: () => 'started-host',
    networkInterfaces: () => ({ en0: [{ family: 'IPv4', internal: false, address: '10.10.0.1' }] }),
  });

  await new Promise((resolve) => runtime.server.on('listening', resolve));
  const port = runtime.server.address().port;
  const response = await request({ protocol: 'http', port, token });
  assert.equal(response.statusCode, 200);
  await close(runtime.server);
  clearInterval(runtime.interval);
});

test('installShutdownHandlers closes the server and schedules forced exit', () => {
  const originalOn = process.on;
  const originalExit = process.exit;
  const originalLog = console.log;
  const originalSetTimeout = global.setTimeout;
  const handlers = {};
  const exitCodes = [];
  let closed = false;
  let timeoutScheduled = false;

  process.on = (eventName, handler) => {
    handlers[eventName] = handler;
    return process;
  };
  process.exit = (code) => {
    exitCodes.push(code);
  };
  console.log = () => {};
  global.setTimeout = () => ({ unref() { timeoutScheduled = true; } });

  try {
    installShutdownHandlers({
      close(callback) {
        closed = true;
        callback();
      },
    });
    handlers.SIGINT();
  } finally {
    process.on = originalOn;
    process.exit = originalExit;
    console.log = originalLog;
    global.setTimeout = originalSetTimeout;
  }

  assert.equal(closed, true);
  assert.deepEqual(exitCodes, [0]);
  assert.equal(timeoutScheduled, true);
});

test('main exits with token error when token cannot be loaded', () => {
  const dir = makeTempDir();
  const { keyFile, certFile } = writeCertPair(dir);
  const originalEnv = process.env;
  const originalExit = process.exit;
  const originalError = console.error;
  const messages = [];

  process.env = {
    ...process.env,
    PORT: '0',
    ENABLE_TLS: '1',
    TOKEN_FILE: path.join(dir, 'missing-token'),
    TLS_KEY_FILE: keyFile,
    TLS_CERT_FILE: certFile,
  };
  process.exit = (code) => {
    throw new Error(`EXIT:${code}`);
  };
  console.error = (message) => {
    messages.push(String(message));
  };

  try {
    assert.throws(() => main(), /EXIT:1/);
  } finally {
    process.env = originalEnv;
    process.exit = originalExit;
    console.error = originalError;
  }

  assert.match(messages.join('\n'), /could not load token/);
});

test('main exits with TLS cert/key error when TLS assets are missing', () => {
  const dir = makeTempDir();
  const tokenFile = writeToken(dir, 'f'.repeat(64));
  const originalEnv = process.env;
  const originalExit = process.exit;
  const originalError = console.error;
  const messages = [];

  process.env = {
    ...process.env,
    PORT: '0',
    ENABLE_TLS: '1',
    TOKEN_FILE: tokenFile,
    TLS_KEY_FILE: path.join(dir, 'missing.key'),
    TLS_CERT_FILE: path.join(dir, 'missing.cert'),
  };
  process.exit = (code) => {
    throw new Error(`EXIT:${code}`);
  };
  console.error = (message) => {
    messages.push(String(message));
  };

  try {
    assert.throws(() => main(), /EXIT:1/);
  } finally {
    process.env = originalEnv;
    process.exit = originalExit;
    console.error = originalError;
  }

  assert.match(messages.join('\n'), /could not load cert\/key/);
});

test('main exits with generic error for invalid port configuration', () => {
  const dir = makeTempDir();
  const tokenFile = writeToken(dir, 'g'.repeat(64));
  const originalEnv = process.env;
  const originalExit = process.exit;
  const originalError = console.error;
  const messages = [];

  process.env = {
    ...process.env,
    PORT: '-1',
    ENABLE_TLS: '0',
    TOKEN_FILE: tokenFile,
  };
  process.exit = (code) => {
    throw new Error(`EXIT:${code}`);
  };
  console.error = (message) => {
    messages.push(String(message));
  };

  try {
    assert.throws(() => main(), /EXIT:1/);
  } finally {
    process.env = originalEnv;
    process.exit = originalExit;
    console.error = originalError;
  }

  assert.match(messages.join('\n'), /FATAL:/);
  assert.doesNotMatch(messages.join('\n'), /token|cert\/key/);
});

test('CLI entrypoint starts and handles SIGTERM', async () => {
  const dir = makeTempDir();
  const tokenFile = writeToken(dir, 'h'.repeat(64));
  const child = spawn(process.execPath, [path.join(repoRoot(), 'devlab-server.js')], {
    env: {
      ...process.env,
      PORT: '0',
      BIND_ADDR: '127.0.0.1',
      ENABLE_TLS: '0',
      TOKEN_FILE: tokenFile,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('server did not start in time')), 5000);
    child.stdout.on('data', (chunk) => {
      if (String(chunk).includes('[devlab] listening on')) {
        clearTimeout(timeout);
        resolve();
      }
    });
    child.on('error', reject);
    child.on('exit', (code) => {
      if (code !== null && code !== 0) {
        clearTimeout(timeout);
        reject(new Error(`unexpected exit ${code}`));
      }
    });
  });

  child.kill('SIGTERM');
  const exitCode = await new Promise((resolve, reject) => {
    child.on('exit', resolve);
    child.on('error', reject);
  });
  assert.equal(exitCode, 0);
});

function repoRoot() {
  return path.resolve(__dirname, '..');
}
