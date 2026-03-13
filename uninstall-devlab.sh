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
