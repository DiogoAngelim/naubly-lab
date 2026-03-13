#!/usr/bin/env bash
set -euo pipefail

LABEL="com.diogo.devlab"
DEVLAB_DIR="$HOME/devlab"
LOG_DIR="$DEVLAB_DIR/logs"
CONFIG_DIR="$DEVLAB_DIR/config"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID"

PORT_DEFAULT="3000"
SERVICE_NAME_DEFAULT="Diogo Dev Lab"
NODE_BIN_DEFAULT="$(command -v node || true)"

info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err() { printf "[ERROR] %s\n" "$*" >&2; }

write_start_script() {
  cat > "$DEVLAB_DIR/start-devlab.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DEVLAB_DIR="$HOME/devlab"
LOG_DIR="$DEVLAB_DIR/logs"
mkdir -p "$LOG_DIR"

START_LOG="$LOG_DIR/start.log"
ERROR_LOG="$LOG_DIR/error.log"
SERVER_OUT="$LOG_DIR/server.out.log"
SERVER_ERR="$LOG_DIR/server.err.log"
MDNS_OUT="$LOG_DIR/mdns.out.log"
MDNS_ERR="$LOG_DIR/mdns.err.log"
HOTSPOT_OUT="$LOG_DIR/hotspot.out.log"
HOTSPOT_ERR="$LOG_DIR/hotspot.err.log"

PORT="${PORT:-3000}"
SERVICE_NAME="${SERVICE_NAME:-Diogo Dev Lab}"
ENABLE_TLS="${ENABLE_TLS:-1}"
SHARE_SERVICE="${SHARE_SERVICE:-0}"
ENABLE_HOTSPOT="${ENABLE_HOTSPOT:-0}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
DNS_SD_BIN="/usr/bin/dns-sd"
OSA_BIN="/usr/bin/osascript"

SERVER_JS="$DEVLAB_DIR/devlab-server.js"
HOTSPOT_SCRIPT="$DEVLAB_DIR/enable-hotspot.applescript"
TOKEN_FILE="${TOKEN_FILE:-$DEVLAB_DIR/config/token}"
TLS_KEY_FILE="${TLS_KEY_FILE:-$DEVLAB_DIR/config/server.key.pem}"
TLS_CERT_FILE="${TLS_CERT_FILE:-$DEVLAB_DIR/config/server.cert.pem}"

SERVER_PID_FILE="$LOG_DIR/server.pid"
MDNS_PID_FILE="$LOG_DIR/mdns.pid"
HOTSPOT_PID_FILE="$LOG_DIR/hotspot.pid"

exec >>"$START_LOG" 2>>"$ERROR_LOG"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] start-devlab.sh invoked"

cleanup_pidfile_process() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "Stopping previous process from $pid_file (PID: $old_pid)"
      kill "$old_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

cleanup_pidfile_process "$SERVER_PID_FILE"
cleanup_pidfile_process "$MDNS_PID_FILE"
cleanup_pidfile_process "$HOTSPOT_PID_FILE"

if [[ -z "$NODE_BIN" ]]; then
  echo "Node.js is not installed or not in PATH. Cannot start devlab server."
  exit 1
fi

if [[ ! -f "$SERVER_JS" ]]; then
  echo "Missing server script: $SERVER_JS"
  exit 1
fi

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "Missing auth token file: $TOKEN_FILE"
  exit 1
fi

if [[ "$ENABLE_TLS" == "1" ]]; then
  if [[ ! -f "$TLS_KEY_FILE" || ! -f "$TLS_CERT_FILE" ]]; then
    echo "TLS is enabled but key/cert missing: $TLS_KEY_FILE / $TLS_CERT_FILE"
    exit 1
  fi
fi

echo "Starting Node server on $BIND_ADDR:$PORT (tls=$ENABLE_TLS)"
"$NODE_BIN" "$SERVER_JS" >>"$SERVER_OUT" 2>>"$SERVER_ERR" &
SERVER_PID=$!
echo "$SERVER_PID" > "$SERVER_PID_FILE"

sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "Server failed to start. Check $SERVER_ERR"
  exit 1
fi

MDNS_PID=""
if [[ "$SHARE_SERVICE" == "1" ]]; then
  if [[ ! -x "$DNS_SD_BIN" ]]; then
    echo "SHARE_SERVICE=1 but missing dns-sd binary at $DNS_SD_BIN"
  else
    SERVICE_TYPE="_http._tcp"
    [[ "$ENABLE_TLS" == "1" ]] && SERVICE_TYPE="_https._tcp"
    echo "Sharing service via Bonjour: $SERVICE_NAME $SERVICE_TYPE local $PORT"
    "$DNS_SD_BIN" -R "$SERVICE_NAME" "$SERVICE_TYPE" local "$PORT" path=/ >>"$MDNS_OUT" 2>>"$MDNS_ERR" &
    MDNS_PID=$!
    echo "$MDNS_PID" > "$MDNS_PID_FILE"
  fi
else
  echo "Bonjour sharing disabled (SHARE_SERVICE=$SHARE_SERVICE)"
fi

if [[ "$ENABLE_HOTSPOT" == "1" ]]; then
  if [[ -f "$HOTSPOT_SCRIPT" ]]; then
    echo "Hotspot helper enabled (best-effort). Running AppleScript helper..."
    "$OSA_BIN" "$HOTSPOT_SCRIPT" >>"$HOTSPOT_OUT" 2>>"$HOTSPOT_ERR" &
    HOTSPOT_PID=$!
    echo "$HOTSPOT_PID" > "$HOTSPOT_PID_FILE"
  else
    echo "ENABLE_HOTSPOT=1 but helper script not found at $HOTSPOT_SCRIPT"
  fi
else
  echo "Hotspot helper disabled (ENABLE_HOTSPOT=$ENABLE_HOTSPOT)"
fi

echo "Devlab started. Server PID=$SERVER_PID${MDNS_PID:+, mDNS PID=$MDNS_PID}"
echo "Tip: if sharing is enabled, discover with: dns-sd -B _http._tcp local or dns-sd -B _https._tcp local"

terminate() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Received termination signal, cleaning up..."
  [[ -f "$MDNS_PID_FILE" ]] && kill "$(cat "$MDNS_PID_FILE" 2>/dev/null || true)" 2>/dev/null || true
  [[ -f "$SERVER_PID_FILE" ]] && kill "$(cat "$SERVER_PID_FILE" 2>/dev/null || true)" 2>/dev/null || true
  rm -f "$MDNS_PID_FILE" "$SERVER_PID_FILE" "$HOTSPOT_PID_FILE"
  exit 0
}

trap terminate INT TERM

wait "$SERVER_PID"
EXIT_CODE=$?
echo "Node server exited with code $EXIT_CODE"

[[ -f "$MDNS_PID_FILE" ]] && kill "$(cat "$MDNS_PID_FILE" 2>/dev/null || true)" 2>/dev/null || true
rm -f "$MDNS_PID_FILE" "$SERVER_PID_FILE" "$HOTSPOT_PID_FILE"

exit "$EXIT_CODE"
EOF
  chmod 755 "$DEVLAB_DIR/start-devlab.sh"
}

write_server_js() {
  cat > "$DEVLAB_DIR/devlab-server.js" <<'EOF'
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
EOF
}

write_hotspot_applescript() {
  cat > "$DEVLAB_DIR/enable-hotspot.applescript" <<'EOF'
-- Best-effort helper for enabling Internet Sharing on macOS.
-- This is fragile because System Settings UI structure can change after macOS updates.
-- Requires Accessibility permission for the app running osascript/Terminal.
-- Failure here should not block the core devlab service.

try
  tell application "System Settings"
    activate
  end tell

  delay 1.5

  tell application "System Events"
    tell process "System Settings"
      set frontmost to true

      -- Attempt to navigate quickly via search box for "Internet Sharing".
      keystroke "f" using {command down}
      delay 0.3
      keystroke "Internet Sharing"
      delay 1.0
      key code 36

      -- Toggle attempt is intentionally conservative; UI may differ across versions.
      delay 2.0
      key code 36
    end tell
  end tell

  return "Internet Sharing toggle attempt executed. Verify manually in System Settings."
on error errMsg number errNum
  return "Hotspot automation failed (expected occasionally): " & errMsg & " (" & errNum & ")"
end try
EOF
}

write_status_script() {
  cat > "$DEVLAB_DIR/status-devlab.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LABEL="com.diogo.devlab"
DEVLAB_DIR="$HOME/devlab"
LOG_DIR="$DEVLAB_DIR/logs"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID"
PORT="${PORT:-3000}"
SERVICE_NAME="${SERVICE_NAME:-Diogo Dev Lab}"
ENABLE_TLS="${ENABLE_TLS:-1}"
SHARE_SERVICE="${SHARE_SERVICE:-0}"

say() { printf "%s\n" "$*"; }
header() { printf "\n=== %s ===\n" "$*"; }

header "DevLab status"
say "Label: $LABEL"
say "DevLab dir: $DEVLAB_DIR"

header "LaunchAgent"
if [[ -f "$PLIST_PATH" ]]; then
  say "plist: present ($PLIST_PATH)"
else
  say "plist: missing ($PLIST_PATH)"
fi

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  say "launchd job: loaded"
else
  say "launchd job: not loaded"
fi

header "Processes"
SERVER_PIDS="$(pgrep -f "$DEVLAB_DIR/devlab-server.js" || true)"
if [[ -n "$SERVER_PIDS" ]]; then
  say "node server: running (PID(s): $SERVER_PIDS)"
else
  say "node server: not running"
fi

MDNS_PIDS_HTTP="$(pgrep -f "dns-sd -R $SERVICE_NAME _http._tcp local" || true)"
MDNS_PIDS_HTTPS="$(pgrep -f "dns-sd -R $SERVICE_NAME _https._tcp local" || true)"
MDNS_PIDS="${MDNS_PIDS_HTTP} ${MDNS_PIDS_HTTPS}"
if [[ "$SHARE_SERVICE" != "1" ]]; then
  say "dns-sd sharing: disabled (SHARE_SERVICE=$SHARE_SERVICE)"
elif [[ -n "$MDNS_PIDS" ]]; then
  say "dns-sd sharing: running (PID(s): $MDNS_PIDS)"
else
  say "dns-sd sharing: not running"
fi

header "Network"
say "Hostname: $(hostname)"
say "Local IPv4 addresses:"
ifconfig | awk '/^[a-z]/ {iface=$1} /inet / {print "  " iface " " $2}' | grep -v ' 127\.0\.0\.1' || true
say "Bonjour browse hint: dns-sd -B _https._tcp local"
say "Resolve hint: dns-sd -L \"$SERVICE_NAME\" _https._tcp local"

header "API probe"
if command -v curl >/dev/null 2>&1; then
  TOKEN_FILE_PATH="$DEVLAB_DIR/config/token"
  PROBE_SCHEME="http"
  PROBE_ARGS=(--max-time 3 --silent --show-error)
  if [[ "$ENABLE_TLS" == "1" ]]; then
    PROBE_SCHEME="https"
    PROBE_ARGS+=(--insecure)
  fi
  if [[ -f "$TOKEN_FILE_PATH" ]]; then
    DEVLAB_TOKEN="$(cat "$TOKEN_FILE_PATH")"
    PROBE_ARGS+=(--header "Authorization: Bearer $DEVLAB_TOKEN")
    say "auth token: found"
  else
    say "auth token: missing ($TOKEN_FILE_PATH) — probe will receive 401"
  fi
  if curl "${PROBE_ARGS[@]}" "$PROBE_SCHEME://127.0.0.1:$PORT" >/tmp/devlab_status_probe.json 2>/tmp/devlab_status_probe.err; then
    say "curl probe: success ($PROBE_SCHEME://127.0.0.1:$PORT)"
    head -n 20 /tmp/devlab_status_probe.json
  else
    say "curl probe: failed ($PROBE_SCHEME://127.0.0.1:$PORT)"
    cat /tmp/devlab_status_probe.err
  fi
  rm -f /tmp/devlab_status_probe.json /tmp/devlab_status_probe.err
else
  say "curl probe: skipped (curl not found)"
fi

header "Logs"
for file in \
  "$LOG_DIR/start.log" \
  "$LOG_DIR/error.log" \
  "$LOG_DIR/server.out.log" \
  "$LOG_DIR/server.err.log" \
  "$LOG_DIR/mdns.out.log" \
  "$LOG_DIR/mdns.err.log" \
  "$LOG_DIR/hotspot.out.log" \
  "$LOG_DIR/hotspot.err.log" \
  "$LOG_DIR/launchd.out.log" \
  "$LOG_DIR/launchd.err.log"; do
  if [[ -f "$file" ]]; then
    say "present: $file"
  else
    say "missing: $file"
  fi
done

header "Diagnostics"
say "If launchd job is not loaded, run: launchctl bootstrap $DOMAIN $PLIST_PATH"
say "If API probe fails, inspect: $LOG_DIR/server.err.log and $LOG_DIR/error.log"
say "If Bonjour is missing, inspect: $LOG_DIR/mdns.err.log"
EOF
  chmod 755 "$DEVLAB_DIR/status-devlab.sh"
}

write_uninstall_script() {
  cat > "$DEVLAB_DIR/uninstall-devlab.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LABEL="com.diogo.devlab"
DEVLAB_DIR="$HOME/devlab"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID"

info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }

info "Stopping LaunchAgent if loaded..."
launchctl bootout "$DOMAIN" "$PLIST_PATH" 2>/dev/null || launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl unload "$PLIST_PATH" 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  info "Removed plist: $PLIST_PATH"
else
  info "plist not present: $PLIST_PATH"
fi

info "Stopping running devlab processes..."
pkill -f "$DEVLAB_DIR/devlab-server.js" 2>/dev/null || true
pkill -f "dns-sd -R Diogo Dev Lab _http._tcp local" 2>/dev/null || true
pkill -f "dns-sd -R Diogo Dev Lab _https._tcp local" 2>/dev/null || true
pkill -f "$DEVLAB_DIR/start-devlab.sh" 2>/dev/null || true

if [[ -d "$DEVLAB_DIR" ]]; then
  printf "Do you want to remove %s entirely? [y/N]: " "$DEVLAB_DIR"
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      rm -rf "$DEVLAB_DIR"
      info "Removed $DEVLAB_DIR"
      ;;
    *)
      info "Kept $DEVLAB_DIR"
      ;;
  esac
else
  warn "$DEVLAB_DIR not found"
fi

info "Uninstall complete."
EOF
  chmod 755 "$DEVLAB_DIR/uninstall-devlab.sh"
}

write_plist() {
  mkdir -p "$(dirname "$PLIST_PATH")"
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEVLAB_DIR/start-devlab.sh</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PORT</key>
    <string>$PORT_DEFAULT</string>
    <key>SERVICE_NAME</key>
    <string>$SERVICE_NAME_DEFAULT</string>
    <key>NODE_BIN</key>
    <string>$NODE_BIN_DEFAULT</string>
    <key>ENABLE_HOTSPOT</key>
    <string>0</string>
    <key>BIND_ADDR</key>
    <string>127.0.0.1</string>
    <key>TOKEN_FILE</key>
    <string>$CONFIG_DIR/token</string>
    <key>SHARE_SERVICE</key>
    <string>0</string>
    <key>ENABLE_TLS</key>
    <string>1</string>
    <key>TLS_KEY_FILE</key>
    <string>$CONFIG_DIR/server.key.pem</string>
    <key>TLS_CERT_FILE</key>
    <string>$CONFIG_DIR/server.cert.pem</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>

  <key>WorkingDirectory</key>
  <string>$DEVLAB_DIR</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF

  cp "$PLIST_PATH" "$CONFIG_DIR/$LABEL.plist"
}

write_config_notes() {
  cat > "$CONFIG_DIR/README.txt" <<'EOF'
DevLab config notes:

- LaunchAgent label: com.diogo.devlab
- Service type shared via Bonjour: _https._tcp (TXT: path=/) when SHARE_SERVICE=1
- Optional hotspot automation: ENABLE_HOTSPOT=1 in LaunchAgent env vars.
- HTTPS enabled by default via self-signed cert/key in ~/devlab/config.

Security notes:
- This setup uses HTTPS and binds to loopback by default (BIND_ADDR=127.0.0.1).
- Avoid enabling SSH/File Sharing unless explicitly needed.
- If enabling hotspot, always use WPA2/WPA3 password protection.
- AppleScript UI automation may require Accessibility permissions.
EOF
}

load_agent() {
  info "Reloading LaunchAgent: $LABEL"
  launchctl bootout "$DOMAIN" "$PLIST_PATH" 2>/dev/null || launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl unload "$PLIST_PATH" 2>/dev/null || true

  launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  launchctl kickstart -k "$DOMAIN/$LABEL"
}

main() {
  mkdir -p "$DEVLAB_DIR" "$LOG_DIR" "$CONFIG_DIR"

  if [[ "${BASH_SOURCE[0]}" != "$DEVLAB_DIR/install-devlab.sh" ]]; then
    cp "${BASH_SOURCE[0]}" "$DEVLAB_DIR/install-devlab.sh"
    chmod 755 "$DEVLAB_DIR/install-devlab.sh"
  fi

  write_start_script
  write_server_js
  write_hotspot_applescript
  write_status_script
  write_uninstall_script
  write_plist
  write_config_notes

  # Generate a 64-char hex auth token (mode 0600). Idempotent: never overwrites an existing token.
  if [[ ! -f "$CONFIG_DIR/token" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$CONFIG_DIR/token"
      chmod 600 "$CONFIG_DIR/token"
      info "Generated new auth token: $CONFIG_DIR/token"
    else
      err "openssl not found. Cannot generate auth token."
      exit 3
    fi
  else
    info "Auth token already exists: $CONFIG_DIR/token"
  fi

  if [[ ! -f "$CONFIG_DIR/server.key.pem" || ! -f "$CONFIG_DIR/server.cert.pem" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      HOST_FQDN="$(hostname)"
      HOST_SHORT="${HOST_FQDN%%.*}"
      openssl req -x509 -newkey rsa:2048 -sha256 -days 365 \
        -nodes \
        -keyout "$CONFIG_DIR/server.key.pem" \
        -out "$CONFIG_DIR/server.cert.pem" \
        -subj "/CN=localhost/O=DevLab" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:$HOST_SHORT,DNS:$HOST_FQDN" >/dev/null 2>&1
      chmod 600 "$CONFIG_DIR/server.key.pem"
      chmod 644 "$CONFIG_DIR/server.cert.pem"
      info "Generated self-signed TLS cert/key in $CONFIG_DIR"
    else
      err "openssl not found. Cannot generate TLS cert/key."
      err "Install OpenSSL or create $CONFIG_DIR/server.key.pem and $CONFIG_DIR/server.cert.pem manually."
      exit 3
    fi
  else
    info "TLS cert/key already exist in $CONFIG_DIR"
  fi

  if command -v security >/dev/null 2>&1; then
    if security add-trusted-cert -d -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CONFIG_DIR/server.cert.pem" >/dev/null 2>&1; then
      info "Trusted TLS certificate in login keychain"
    else
      warn "Could not trust TLS certificate automatically. You may need to trust $CONFIG_DIR/server.cert.pem manually in Keychain Access."
    fi
  else
    warn "security tool not found; skipping certificate trust setup"
  fi

  touch \
    "$LOG_DIR/start.log" \
    "$LOG_DIR/error.log" \
    "$LOG_DIR/server.out.log" \
    "$LOG_DIR/server.err.log" \
    "$LOG_DIR/mdns.out.log" \
    "$LOG_DIR/mdns.err.log" \
    "$LOG_DIR/hotspot.out.log" \
    "$LOG_DIR/hotspot.err.log" \
    "$LOG_DIR/launchd.out.log" \
    "$LOG_DIR/launchd.err.log"

  if ! command -v node >/dev/null 2>&1; then
    err "Node.js is not installed. Files were generated, but LaunchAgent was not loaded."
    err "Install Node.js (LTS) and rerun: $DEVLAB_DIR/install-devlab.sh"
    err "Download: https://nodejs.org/"
    exit 2
  fi

  if [[ -z "$NODE_BIN_DEFAULT" ]]; then
    err "Node.js was found during validation but absolute path detection failed."
    exit 2
  fi

  load_agent

  info "Installation complete."
  info "Status script: $DEVLAB_DIR/status-devlab.sh"
  info "Uninstall script: $DEVLAB_DIR/uninstall-devlab.sh"
  info "Service URL: https://127.0.0.1:$PORT_DEFAULT"
  info "Auth token (keep secret): $(cat "$CONFIG_DIR/token" 2>/dev/null || echo 'not found')"
  info "Test: curl -k -H \"Authorization: Bearer \$(cat $CONFIG_DIR/token)\" https://127.0.0.1:$PORT_DEFAULT"
  info "Bonjour discover (if SHARE_SERVICE=1): dns-sd -B _https._tcp local"
  info "Troubleshooting: tail -f $LOG_DIR/error.log $LOG_DIR/server.err.log"
  warn "Hotspot automation is best-effort and may fail after macOS updates."
  warn "If using hotspot automation, grant Accessibility permission to Terminal/osascript."
}

main "$@"
