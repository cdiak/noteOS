#!/usr/bin/env bash
# Install noteos → ~/.local/bin + orb assets → ~/.local/share/noteos + login LaunchAgent
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/noteos"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
LABEL="com.cdiak.noteos"
PLIST="${LAUNCH_AGENTS}/${LABEL}.plist"
DEST="${BIN_DIR}/noteos"

mkdir -p "$BIN_DIR" "$SHARE_DIR" "$LAUNCH_AGENTS"

./build.sh "$DEST"

# Orb assets (vendored thinking-orbs engine + driver page)
rm -rf "${SHARE_DIR}/orb"
cp -R orb "${SHARE_DIR}/orb"

# Stop current agent
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

# Resolve whisper-cli: env → PATH → common Homebrew location
if [[ -z "${WHISPER_CLI:-}" ]]; then
  if command -v whisper-cli >/dev/null 2>&1; then
    WHISPER_CLI="$(command -v whisper-cli)"
  else
    WHISPER_CLI="/opt/homebrew/bin/whisper-cli"
  fi
fi

# Resolve a whisper model: env → common locations
if [[ -z "${WHISPER_MODEL:-}" ]]; then
  for candidate in \
    "${HOME}/Development/Models/whisper/ggml-base.en.bin" \
    "${HOME}/models/whisper/ggml-base.en.bin" \
    "${HOME}/.cache/whisper/ggml-base.en.bin" \
    "/opt/homebrew/share/whisper-cpp/ggml-base.en.bin"
  do
    if [[ -f "$candidate" ]]; then
      WHISPER_MODEL="$candidate"
      break
    fi
  done
fi
WHISPER_MODEL="${WHISPER_MODEL:-}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"

if [[ -z "$WHISPER_MODEL" ]]; then
  echo "warning: no whisper model found. Set WHISPER_MODEL to a ggml model path." >&2
fi

# Resolve claude CLI: env → PATH → common locations
if [[ -z "${CLAUDE_CLI:-}" ]]; then
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CLI="$(command -v claude)"
  elif [[ -x "${HOME}/.local/bin/claude" ]]; then
    CLAUDE_CLI="${HOME}/.local/bin/claude"
  elif [[ -x "${HOME}/.claude/local/claude" ]]; then
    CLAUDE_CLI="${HOME}/.claude/local/claude"
  else
    CLAUDE_CLI="/opt/homebrew/bin/claude"
  fi
fi
NOTEOS_MODEL="${NOTEOS_MODEL:-}"
NOTEOS_TIMEOUT="${NOTEOS_TIMEOUT:-120}"
NOTEOS_DIR="${NOTEOS_DIR:-${HOME}/Notes}"

if [[ ! -x "$CLAUDE_CLI" ]]; then
  echo "warning: claude CLI not found at $CLAUDE_CLI. Set CLAUDE_CLI and re-run." >&2
fi

# Escape XML special chars in paths for plist
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

WCLI_XML="$(xml_escape "$WHISPER_CLI")"
WMODEL_XML="$(xml_escape "$WHISPER_MODEL")"
WLANG_XML="$(xml_escape "$WHISPER_LANGUAGE")"
CCLI_XML="$(xml_escape "$CLAUDE_CLI")"
CMODEL_XML="$(xml_escape "$NOTEOS_MODEL")"
TIMEOUT_XML="$(xml_escape "$NOTEOS_TIMEOUT")"
NOTES_XML="$(xml_escape "$NOTEOS_DIR")"
ORB_XML="$(xml_escape "${SHARE_DIR}/orb")"
DEST_XML="$(xml_escape "$DEST")"
HOME_XML="$(xml_escape "$HOME")"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST_XML}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WHISPER_CLI</key>
    <string>${WCLI_XML}</string>
    <key>WHISPER_MODEL</key>
    <string>${WMODEL_XML}</string>
    <key>WHISPER_LANGUAGE</key>
    <string>${WLANG_XML}</string>
    <key>CLAUDE_CLI</key>
    <string>${CCLI_XML}</string>
    <key>NOTEOS_MODEL</key>
    <string>${CMODEL_XML}</string>
    <key>NOTEOS_TIMEOUT</key>
    <string>${TIMEOUT_XML}</string>
    <key>NOTEOS_DIR</key>
    <string>${NOTES_XML}</string>
    <key>NOTEOS_ORB_DIR</key>
    <string>${ORB_XML}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME_XML}/Library/Logs/noteos.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME_XML}/Library/Logs/noteos.log</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  || launchctl load "$PLIST"

echo
echo "Installed noteos"
echo "  binary:  $DEST"
echo "  orb:     ${SHARE_DIR}/orb"
echo "  agent:   $PLIST"
echo "  log:     $HOME/Library/Logs/noteos.log"
echo "  whisper: $WHISPER_CLI"
echo "  model:   ${WHISPER_MODEL:-(not set)}"
echo "  claude:  $CLAUDE_CLI"
echo "  notes:   $NOTEOS_DIR"
echo
echo "Hotkey: Option+Shift+N  (record → stop+compose; press while composing to cancel)"
echo
echo "Permissions (first run):"
echo "  System Settings → Privacy & Security → Microphone → noteos"
echo "  No Accessibility grant is needed — noteos never pastes or taps keys."
echo "  If missing from the list, run once: $DEST"
echo
echo "Menu bar: \"N\" idle · \"●\" recording · \"…\" transcribing · \"◍\" composing"
echo "Orb: listening wave while you speak · composing ribbon while the note is structured"
echo "Uninstall: ./uninstall.sh"
