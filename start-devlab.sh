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
ENABLE_HOTSPOT="${ENABLE_HOTSPOT:-0}"
ADVERTISE_SERVICE="${ADVERTISE_SERVICE:-0}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
ENABLE_TLS="${ENABLE_TLS:-1}"

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
if [[ "$ADVERTISE_SERVICE" == "1" ]]; then
  if [[ ! -x "$DNS_SD_BIN" ]]; then
    echo "ADVERTISE_SERVICE=1 but missing dns-sd binary at $DNS_SD_BIN"
  else
    AD_TYPE="_http._tcp"
    [[ "$ENABLE_TLS" == "1" ]] && AD_TYPE="_https._tcp"
    echo "Advertising service via Bonjour: $SERVICE_NAME $AD_TYPE local $PORT"
    "$DNS_SD_BIN" -R "$SERVICE_NAME" "$AD_TYPE" local "$PORT" path=/ >>"$MDNS_OUT" 2>>"$MDNS_ERR" &
    MDNS_PID=$!
    echo "$MDNS_PID" > "$MDNS_PID_FILE"
  fi
else
  echo "Bonjour advertisement disabled (ADVERTISE_SERVICE=$ADVERTISE_SERVICE)"
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
echo "Tip: if advertisement is enabled, discover with: dns-sd -B _http._tcp local or dns-sd -B _https._tcp local"

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
