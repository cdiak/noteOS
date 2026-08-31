# whispernote

**⌥⇧N — speak a note anywhere, get a structured Markdown file in your vault.**

Press **⌥⇧N** anywhere on your Mac and talk. Press **⌥⇧N** again. whispernote transcribes your words on-device with [whisper.cpp](https://github.com/ggml-org/whisper.cpp). It then hands the transcript to a coding agent ([Claude Code](https://claude.com/claude-code), `claude -p`). The agent cleans the dictation, gives it a title, and structures it as a note. The note lands in `~/Notes` — an Obsidian vault — as `<timestamp> <title>.md`.

```
⌥⇧N  →  ● record  →  ⌥⇧N  →  … transcribe  →  ◍ compose  →  ~/Notes/2026-08-31 143205 Title.md
```

No text field is needed. Focus does not matter. A floating orb shows the state: a **listening** wave while you speak, a **composing** ribbon while the agent writes.

whispernote is the third sibling of [everywhisper](https://github.com/cdiak/everywhisper) (⌥⇧W, dictate → paste) and [optionai](https://github.com/cdiak/optionai) (⌥A+I, agent at the cursor). Same skeleton: one Swift file, a menu-bar item, a LaunchAgent.

## Safety rule

The raw transcript is written to the note file **before** the agent runs. If claude fails, times out, or is canceled, the raw note stays on disk. You never lose a thought to a network error.

## Requirements

| Need | Notes |
|------|-------|
| macOS | Apple Silicon or Intel |
| [Xcode Command Line Tools](https://developer.apple.com/xcode/) | for `swiftc` (build once) |
| [`whisper-cli`](https://github.com/ggml-org/whisper.cpp) | `brew install whisper-cpp` |
| A GGML Whisper model (`.bin`) | not included — see everywhisper's README |
| [Claude Code CLI](https://claude.com/claude-code) | `claude` on PATH, logged in |

**Permissions:** Microphone only. whispernote never pastes and never taps the keyboard, so it needs **no Accessibility grant**.

## Install

```bash
git clone https://github.com/cdiak/whispernote.git ~/Development/Projects/whispernote
cd ~/Development/Projects/whispernote
./install.sh
```

`install.sh` builds `~/.local/bin/whispernote`, copies the orb assets to `~/.local/share/whispernote/orb`, and registers the login LaunchAgent `com.cdiak.whispernote`. Grant **Microphone** on first use.

## Use

1. Press **⌥⇧N**. The menu bar shows **●** and the listening orb follows your pointer. Speak.
2. Press **⌥⇧N** again. whisper.cpp transcribes locally (**…**). The raw transcript is saved to `~/Notes/<timestamp>.md` at once.
3. The agent structures the note (**◍**, composing orb). On success the file is rewritten and renamed to `<timestamp> <title>.md`. A Glass sound confirms it.
4. Press **⌥⇧N** during **◍** to cancel the agent. The raw transcript stays.

Each note carries YAML frontmatter (`created`, `source: whispernote`), so Obsidian can sort and filter them.

## Configuration (environment variables)

| Variable | Default | Meaning |
|----------|---------|---------|
| `WHISPERNOTE_DIR` | `~/Notes` | vault folder for new notes |
| `WHISPERNOTE_MODEL` | claude CLI default | model passed to `claude --model` |
| `WHISPERNOTE_TIMEOUT` | `120` | agent timeout, seconds |
| `WHISPER_CLI` | auto-detected | path to `whisper-cli` |
| `WHISPER_MODEL` | auto-detected | path to a GGML model |
| `WHISPER_LANGUAGE` | `en` | transcription language |
| `WHISPERNOTE_ORB_DIR` | auto-detected | orb assets; unset hides the orb |

Set them in the LaunchAgent plist (re-run `./install.sh` after exporting them), or in the shell when running the binary directly.

## Uninstall

```bash
./uninstall.sh
```

Removes the binary, the orb assets, and the LaunchAgent. Your notes stay in place.

## License

MIT. The orb animation is [thinking-orbs](https://www.npmjs.com/package/thinking-orbs) (MIT), vendored in `orb/`.
