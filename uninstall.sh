#!/usr/bin/env bash
set -euo pipefail
LABEL="com.cdiak.whispernote"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DEST="${HOME}/.local/bin/whispernote"
SHARE_DIR="${HOME}/.local/share/whispernote"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$DEST"
rm -rf "$SHARE_DIR"
echo "Removed whispernote (binary, orb assets, LaunchAgent). Your notes stay in place."
