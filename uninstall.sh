#!/usr/bin/env bash
set -euo pipefail
LABEL="com.cdiak.noteos"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DEST="${HOME}/.local/bin/noteos"
SHARE_DIR="${HOME}/.local/share/noteos"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$DEST"
rm -rf "$SHARE_DIR"
echo "Removed noteos (binary, orb assets, LaunchAgent). Your notes stay in place."
