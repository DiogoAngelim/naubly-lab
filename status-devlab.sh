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
ADVERTISE_SERVICE="${ADVERTISE_SERVICE:-0}"

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
if [[ "$ADVERTISE_SERVICE" != "1" ]]; then
  say "dns-sd advertisement: disabled (ADVERTISE_SERVICE=$ADVERTISE_SERVICE)"
elif [[ -n "$MDNS_PIDS" ]]; then
  say "dns-sd advertisement: running (PID(s): $MDNS_PIDS)"
else
  say "dns-sd advertisement: not running"
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
