const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const os = require('os');

function loadRuntimeConfig(env = process.env) {
  return {
    port: Number(env.PORT || 3000),
    serviceName: env.SERVICE_NAME || 'Diogo Dev Lab',
    bindAddr: env.BIND_ADDR || '127.0.0.1',
    tokenFile: env.TOKEN_FILE || path.join(os.homedir(), 'devlab', 'config', 'token'),
    enableTls: env.ENABLE_TLS !== '0',
    tlsKeyFile: env.TLS_KEY_FILE || path.join(os.homedir(), 'devlab', 'config', 'server.key.pem'),
    tlsCertFile: env.TLS_CERT_FILE || path.join(os.homedir(), 'devlab', 'config', 'server.cert.pem'),
  };
}

function loadAuthToken(tokenFile) {
  const authToken = fs.readFileSync(tokenFile, 'utf8').trim();
  if (!authToken || authToken.length < 32) {
    throw new Error('token must exist and be at least 32 chars');
  }
  return authToken;
}

function createRateLimiter(limit = 30, windowMs = 60_000) {
  const state = new Map();

  function check(ip, now = Date.now()) {
    const entry = state.get(ip);
    if (!entry || now > entry.resetAt) {
      state.set(ip, { count: 1, resetAt: now + windowMs });
      return true;
    }
    if (entry.count >= limit) {
      return false;
    }
    entry.count += 1;
    return true;
  }

  function evict(now = Date.now()) {
    for (const [ip, entry] of state) {
      if (now > entry.resetAt) {
        state.delete(ip);
      }
    }
  }

  return { check, evict, state, limit, windowMs };
}

function getIPv4Addresses(networkInterfaces = os.networkInterfaces()) {
  const ips = [];
  for (const name of Object.keys(networkInterfaces)) {
    for (const details of networkInterfaces[name] || []) {
      if (details && details.family === 'IPv4' && !details.internal) {
        ips.push(details.address);
      }
    }
  }
  return [...new Set(ips)];
}

function setSecurityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
}

function sendJSON(res, status, body) {
  setSecurityHeaders(res);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body, null, 2));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let index = 0; index < a.length; index += 1) {
    diff |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return diff === 0;
}

function createRequestHandler(options) {
  const {
    serviceName,
    authToken,
    rateLimiter,
    hostname = os.hostname,
    networkInterfaces = os.networkInterfaces,
  } = options;

  return function handleRequest(req, res) {
    const clientIP = req.socket.remoteAddress || 'unknown';

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      sendJSON(res, 405, { ok: false, error: 'Method not allowed' });
      return;
    }

    if (!rateLimiter.check(clientIP)) {
      sendJSON(res, 429, { ok: false, error: 'Too many requests' });
      return;
    }

    const authHeader = req.headers.authorization || '';
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    const provided = match ? match[1] : null;
    if (!provided || !timingSafeEqual(provided, authToken)) {
      res.setHeader('WWW-Authenticate', 'Bearer realm="devlab"');
      sendJSON(res, 401, { ok: false, error: 'Unauthorized' });
      return;
    }

    const payload = {
      ok: true,
      service: serviceName,
      timestamp: new Date().toISOString(),
      hostname: hostname(),
      ipv4: getIPv4Addresses(networkInterfaces()),
      requestUrl: req.url,
      requestMethod: req.method,
    };
    sendJSON(res, 200, payload);
  };
}

function createServer(config, dependencies = {}) {
  const authToken = dependencies.authToken || loadAuthToken(config.tokenFile);
  const rateLimiter = dependencies.rateLimiter || createRateLimiter();
  const handler = dependencies.handler || createRequestHandler({
    serviceName: config.serviceName,
    authToken,
    rateLimiter,
    hostname: dependencies.hostname,
    networkInterfaces: dependencies.networkInterfaces,
  });

  let server;
  if (config.enableTls) {
    const key = dependencies.key || fs.readFileSync(config.tlsKeyFile, 'utf8');
    const cert = dependencies.cert || fs.readFileSync(config.tlsCertFile, 'utf8');
    server = https.createServer({ key, cert }, handler);
  } else {
    server = http.createServer(handler);
  }

  const interval = setInterval(() => rateLimiter.evict(), rateLimiter.windowMs);
  interval.unref();

  return { server, authToken, rateLimiter, interval };
}

function startServer(config = loadRuntimeConfig(), dependencies = {}) {
  const runtime = createServer(config, dependencies);
  runtime.server.listen(config.port, config.bindAddr, () => {
    console.log(`[devlab] listening on ${config.enableTls ? 'https' : 'http'}://${config.bindAddr}:${config.port}`);
  });
  return runtime;
}

function installShutdownHandlers(server) {
  function shutdown(signal) {
    console.log(`[devlab] received ${signal}, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

function main() {
  try {
    const runtime = startServer();
    installShutdownHandlers(runtime.server);
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    if (message.includes('token')) {
      console.error(`[devlab] FATAL: could not load token: ${message}`);
    } else if (message.includes('ENOENT') || message.includes('key') || message.includes('cert')) {
      console.error(`[devlab] FATAL: TLS enabled but could not load cert/key: ${message}`);
    } else {
      console.error(`[devlab] FATAL: ${message}`);
    }
    process.exit(1);
  }
}

module.exports = {
  createRateLimiter,
  createRequestHandler,
  createServer,
  getIPv4Addresses,
  installShutdownHandlers,
  loadAuthToken,
  loadRuntimeConfig,
  main,
  sendJSON,
  setSecurityHeaders,
  startServer,
  timingSafeEqual,
};

if (require.main === module) {
  main();
}