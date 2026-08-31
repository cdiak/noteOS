// noteOS — speak a note anywhere, get a structured Markdown file in your vault.
//
// Option+Shift+N → ● record → Option+Shift+N → transcribe locally (whisper.cpp)
// → structure with a coding agent (claude -p) → write ~/Notes/<timestamp> <title>.md
//
// Sibling of everywhisper (⌥⇧W, dictate → paste) and optionai (⌥A+I, agent at
// the cursor). Same skeleton: one Swift file, a menu-bar item, a LaunchAgent.
// Unlike its siblings, noteOS needs no Accessibility grant: it never
// pastes and never taps the keyboard. Microphone is the only permission.
//
// Failure is never data loss: the raw transcript is written to the note file
// BEFORE the agent runs. If claude fails or is canceled, the raw note stays.
//
// Build:   ./build.sh
// Install: ./install.sh

import AppKit
import AVFoundation
import Carbon
import Foundation
import WebKit

// MARK: - Config

struct Config {
    var whisperBinary: String
    var modelPath: String
    var language: String
    var threads: Int
    var claudeBinary: String
    var claudeModel: String?
    var timeoutSeconds: Double
    var notesDir: URL
    var orbDir: URL?

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser

        let whisper =
            env["WHISPER_CLI"]
            ?? which("whisper-cli")
            ?? "/opt/homebrew/bin/whisper-cli"

        let model =
            env["WHISPER_MODEL"]
            ?? firstExisting([
                "\(home.path)/Development/Models/whisper/ggml-base.en.bin",
                "\(home.path)/models/whisper/ggml-base.en.bin",
                "\(home.path)/.cache/whisper/ggml-base.en.bin",
                "/opt/homebrew/share/whisper-cpp/ggml-base.en.bin",
            ])
            ?? "\(home.path)/models/whisper/ggml-base.en.bin"

        let claude =
            env["CLAUDE_CLI"]
            ?? which("claude")
            ?? firstExisting([
                "\(home.path)/.local/bin/claude",
                "\(home.path)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
            ?? "claude"

        let notesDir =
            env["NOTEOS_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent("Notes")

        let orbDir =
            env["NOTEOS_ORB_DIR"].map { URL(fileURLWithPath: $0) }
            ?? firstExisting([
                "\(home.path)/.local/share/noteos/orb",
                "\(home.path)/Development/Projects/noteOS/orb",
            ]).map { URL(fileURLWithPath: $0) }

        // Empty env values (e.g. an unset plist key) mean "not set".
        let claudeModel = env["NOTEOS_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Config(
            whisperBinary: whisper,
            modelPath: model,
            language: env["WHISPER_LANGUAGE"] ?? "en",
            threads: Int(env["WHISPER_THREADS"] ?? "")
                ?? max(2, ProcessInfo.processInfo.processorCount / 2),
            claudeBinary: claude,
            claudeModel: (claudeModel?.isEmpty == false) ? claudeModel : nil,
            timeoutSeconds: Double(env["NOTEOS_TIMEOUT"] ?? "") ?? 120,
            notesDir: notesDir,
            orbDir: orbDir
        )
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func which(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Recorder + Whisper (from everywhisper)

final class Recorder {
    private let config: Config
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private(set) var isRecording = false

    init(config: Config) {
        self.config = config
    }

    /// Start capturing 16 kHz mono WAV. Returns false when the mic is denied
    /// or the recorder cannot start.
    func start() -> Bool {
        guard requestMicAccessSync() else {
            fputs(
                "noteos: microphone denied. Enable it in System Settings → Privacy & Security → Microphone.\n",
                stderr
            )
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noteos-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else { return false }
            recorder = rec
            recordingURL = url
            isRecording = true
            return true
        } catch {
            fputs("noteos: recording failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// Stop and return the WAV file for transcription.
    func stop() -> URL? {
        guard let rec = recorder, let url = recordingURL else { return nil }
        rec.stop()
        recorder = nil
        recordingURL = nil
        isRecording = false
        return url
    }

    func transcribe(wav: URL) throws -> String {
        defer {
            try? FileManager.default.removeItem(at: wav)
            let txt = wav.deletingPathExtension().appendingPathExtension("txt")
            try? FileManager.default.removeItem(at: txt)
        }

        guard FileManager.default.fileExists(atPath: config.whisperBinary) else {
            throw err("whisper-cli not found at \(config.whisperBinary). Install whisper.cpp or set WHISPER_CLI.")
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw err("Model not found at \(config.modelPath). Set WHISPER_MODEL to a ggml model file.")
        }

        let outBase = wav.deletingPathExtension().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperBinary)
        process.arguments = [
            "-m", config.modelPath,
            "-f", wav.path,
            "-l", config.language,
            "-t", String(config.threads),
            "-otxt",
            "-of", outBase,
            "-np",
        ]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw err("whisper-cli exited \(process.terminationStatus): \(errText)")
        }

        let raw = try String(
            contentsOf: URL(fileURLWithPath: outBase + ".txt"), encoding: .utf8
        )
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func requestMicAccessSync() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
            return granted
        default:
            return false
        }
    }

    private func err(_ message: String) -> NSError {
        NSError(
            domain: "noteos", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - Agent (claude -p, from optionai)

final class AgentEngine {
    private let config: Config
    private var process: Process?
    private var generation = 0
    private(set) var isBusy = false

    init(config: Config) {
        self.config = config
    }

    static let instruction = """
        You are noteOS, a note-structuring agent. The input is a raw \
        voice-dictation transcript, captured with local speech-to-text. \
        Rewrite it as a well-structured Markdown note for the user's Obsidian \
        vault. The FIRST line must be a heading: '# ' followed by a short \
        title (3–7 words) that names the note's subject. Then a blank line, \
        then the note. Fix dictation artifacts: punctuation, casing, filler \
        words, and obvious mis-transcriptions. Preserve every idea and every \
        specific detail. Do not add ideas of your own, and do not comment on \
        the note. Use lists or sub-headings only when the content calls for \
        them; a short thought stays a short paragraph. Write nothing except \
        the note itself.
        """

    func run(
        transcript: String,
        onDone: @escaping (Result<String, Error>) -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        generation += 1
        let gen = generation

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudeBinary)
        var args = ["-p", Self.instruction, "--output-format", "text"]
        if let model = config.claudeModel {
            args += ["--model", model]
        }
        p.arguments = args
        // Neutral cwd so no project CLAUDE.md leaks into the context.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory

        var env = ProcessInfo.processInfo.environment
        let basePATH = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePATH
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderrPipe

        do {
            try p.run()
        } catch {
            isBusy = false
            onDone(.failure(error))
            return
        }
        process = p

        if let data = transcript.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        let timeout = config.timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == gen, p.isRunning else { return }
            p.terminate()
            fputs("noteos: agent timed out after \(Int(timeout))s\n", stderr)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.isBusy = false
                self.process = nil

                let status = p.terminationStatus
                let text = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""

                guard status == 0 else {
                    onDone(
                        .failure(
                            NSError(
                                domain: "noteos", code: Int(status),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "claude exited \(status): \(errText)"
                                ]
                            )
                        )
                    )
                    return
                }
                onDone(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        generation += 1
        process?.terminate()
        process = nil
        isBusy = false
    }
}

// MARK: - Note store (~/Notes, an Obsidian vault)

enum NoteStore {

    /// Write the raw transcript immediately, before the agent runs. The
    /// filename is the timestamp; frontmatter records the creation time.
    static func writeRaw(transcript: String, in dir: URL, now: Date = Date())
        throws -> URL
    {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("\(stamp(now, "yyyy-MM-dd HHmmss")).md")
        let body = """
            ---
            created: \(stamp(now, "yyyy-MM-dd'T'HH:mm:ssZZZZZ"))
            source: noteos
            ---

            \(transcript)
            """
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Replace the raw transcript with the structured note. Keep the
    /// frontmatter, and rename the file to "<timestamp> <title>.md" when the
    /// note's first line is a heading.
    static func finalize(note: String, rawURL: URL) throws -> URL {
        let existing = try String(contentsOf: rawURL, encoding: .utf8)
        let frontmatter = extractFrontmatter(existing)
        let body = frontmatter.isEmpty ? note : frontmatter + "\n" + note
        try body.write(to: rawURL, atomically: true, encoding: .utf8)

        guard let title = inferTitle(note) else { return rawURL }
        let base = rawURL.deletingPathExtension().lastPathComponent
        var dest = rawURL.deletingLastPathComponent()
            .appendingPathComponent("\(base) \(title).md")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = rawURL.deletingLastPathComponent()
                .appendingPathComponent("\(base) \(title) 2.md")
        }
        try FileManager.default.moveItem(at: rawURL, to: dest)
        return dest
    }

    private static func extractFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") else { return "" }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return "" }
        return String(text[text.startIndex..<end.upperBound])
    }

    /// First "# Title" line → a filename-safe title, or nil.
    static func inferTitle(_ note: String) -> String? {
        guard
            let heading = note
                .components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("# ") })
        else { return nil }

        // Strip characters Obsidian or the filesystem rejects in names.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        var title = heading.dropFirst(2)
            .components(separatedBy: forbidden)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = title
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if title.count > 60 {
            title = String(title.prefix(60))
                .trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}

// MARK: - Orb spinner (thinking-orbs, via WKWebView; from optionai)

final class OrbPanel {
    private var panel: NSPanel?
    private var followTimer: Timer?
    private let orbDir: URL?
    private let size: CGFloat = 64

    init(orbDir: URL?) {
        self.orbDir = orbDir
    }

    private func origin(for anchor: NSPoint) -> NSPoint {
        var origin = NSPoint(x: anchor.x + 14, y: anchor.y - size - 6)
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(anchor)
        }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        return origin
    }

    /// Show the orb near the pointer. `state` picks the thinking-orbs mode:
    /// "listening" (wave) while recording, "composing" (ribbon) while the
    /// agent structures the note. The state rides on the URL fragment.
    func show(state: String) {
        guard let orbDir else { return }
        let html = orbDir.appendingPathComponent("orb.html")
        guard FileManager.default.fileExists(atPath: html.path) else { return }
        guard let url = URL(string: html.absoluteString + "#" + state) else { return }

        hide()

        let origin = origin(for: NSEvent.mouseLocation)
        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: size, height: size)
        )
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.loadFileURL(url, allowingReadAccessTo: orbDir)
        p.contentView = webView

        p.orderFrontRegardless()
        panel = p

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            panel.setFrameOrigin(self.origin(for: NSEvent.mouseLocation))
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case idle, recording, transcribing, composing
    }

    private var config: Config!
    private var recorder: Recorder!
    private var agent: AgentEngine!
    private var orb: OrbPanel!
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        recorder = Recorder(config: config)
        agent = AgentEngine(config: config)
        orb = OrbPanel(orbDir: config.orbDir)

        fputs(
            """
            noteos ready
              hotkey:  Option+Shift+N  (record → stop+compose; press while composing to cancel)
              whisper: \(config.whisperBinary)
              model:   \(config.modelPath)
              claude:  \(config.claudeBinary)
              agent:   \(config.claudeModel ?? "(cli default)")
              notes:   \(config.notesDir.path)
              orb:     \(config.orbDir?.path ?? "(none — menu-bar indicator only)")

            """,
            stderr
        )

        setupStatusItem()
        registerHotkey()
        updateStatus()
    }

    // MARK: flow

    private func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndCompose()
        case .transcribing:
            // Local transcription takes a moment; there is nothing to cancel
            // that would not lose the recording.
            NSSound.beep()
        case .composing:
            // Cancel the agent; the raw transcript note stays on disk.
            agent.cancel()
            state = .idle
            orb.hide()
            updateStatus()
            NSSound(named: .init("Pop"))?.play()
            fputs("noteos: canceled — raw transcript kept\n", stderr)
        }
    }

    private func startRecording() {
        guard recorder.start() else {
            NSSound.beep()
            return
        }
        state = .recording
        orb.show(state: "listening")
        updateStatus()
        NSSound(named: .init("Tink"))?.play()
        fputs("● Recording… (Option+Shift+N to stop)\n", stderr)
    }

    private func stopAndCompose() {
        guard let wav = recorder.stop() else {
            state = .idle
            orb.hide()
            updateStatus()
            return
        }
        state = .transcribing
        orb.show(state: "composing")
        updateStatus()
        NSSound(named: .init("Pop"))?.play()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let transcript: String
            do {
                transcript = try self.recorder.transcribe(wav: wav)
            } catch {
                DispatchQueue.main.async {
                    self.fail("whisper failed: \(error.localizedDescription)")
                }
                return
            }

            DispatchQueue.main.async {
                guard !transcript.isEmpty else {
                    self.fail("no speech detected")
                    return
                }
                fputs("→ \(transcript)\n", stderr)
                self.composeNote(transcript: transcript)
            }
        }
    }

    private func composeNote(transcript: String) {
        let rawURL: URL
        do {
            rawURL = try NoteStore.writeRaw(
                transcript: transcript, in: config.notesDir
            )
        } catch {
            fail("could not write note: \(error.localizedDescription)")
            return
        }
        fputs("noteos: raw transcript saved: \(rawURL.path)\n", stderr)

        state = .composing
        updateStatus()

        agent.run(transcript: transcript) { [weak self] result in
            guard let self else { return }
            self.orb.hide()
            self.state = .idle
            self.updateStatus()

            switch result {
            case .failure(let error):
                NSSound(named: .init("Basso"))?.play()
                fputs(
                    "noteos: agent failed — raw transcript kept at \(rawURL.path): \(error.localizedDescription)\n",
                    stderr
                )

            case .success(let note):
                guard !note.isEmpty else {
                    NSSound.beep()
                    fputs(
                        "noteos: agent returned nothing — raw transcript kept at \(rawURL.path)\n",
                        stderr
                    )
                    return
                }
                do {
                    let dest = try NoteStore.finalize(note: note, rawURL: rawURL)
                    NSSound(named: .init("Glass"))?.play()
                    fputs("noteos: note written: \(dest.path)\n", stderr)
                } catch {
                    NSSound(named: .init("Basso"))?.play()
                    fputs(
                        "noteos: finalize failed — raw transcript kept at \(rawURL.path): \(error.localizedDescription)\n",
                        stderr
                    )
                }
            }
        }
    }

    private func fail(_ message: String) {
        state = .idle
        orb.hide()
        updateStatus()
        NSSound.beep()
        fputs("noteos: \(message)\n", stderr)
    }

    // MARK: status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "N"
            button.toolTip = "noteos — Option+Shift+N"
        }
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Toggle Note (⌥⇧N)",
                action: #selector(toggleFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open Notes Folder",
                action: #selector(openNotes),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func updateStatus() {
        switch state {
        case .recording:
            statusItem?.button?.title = "●"
            statusItem?.button?.toolTip = "noteos — recording (⌥⇧N to stop)"
        case .transcribing:
            statusItem?.button?.title = "…"
            statusItem?.button?.toolTip = "noteos — transcribing"
        case .composing:
            statusItem?.button?.title = "◍"
            statusItem?.button?.toolTip = "noteos — composing (⌥⇧N to cancel)"
        case .idle:
            statusItem?.button?.title = "N"
            statusItem?.button?.toolTip = "noteos — Option+Shift+N"
        }
    }

    @objc private func toggleFromMenu() {
        toggle()
    }

    @objc private func openNotes() {
        try? FileManager.default.createDirectory(
            at: config.notesDir, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(config.notesDir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: hotkey — Option+Shift+N (Carbon, no Accessibility needed)

    private func registerHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E544F53), id: 1) // 'NTOS'
        let keyCode = UInt32(kVK_ANSI_N)
        let modifiers = UInt32(optionKey | shiftKey)

        var handlerSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var hk = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                if hk.id == 1 {
                    DispatchQueue.main.async {
                        app.toggle()
                    }
                }
                return noErr
            },
            1,
            &handlerSpec,
            userData,
            &eventHandler
        )

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
