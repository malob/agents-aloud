import Foundation
import OSLog
import Synchronization

// Speech text optimizer that shells out to `claude` CLI (Claude Code)
// with the Haiku model. Strictly better output than the on-device
// FoundationModel for this task — handles code blocks, markdown tables,
// URLs, file paths, bullet/numbered lists, and headings correctly.
// The latency cost is real (~5s for short messages, 40–60s for
// structure-heavy 1–2KB messages); the passthrough fallback kicks in
// past a hard cap so the user isn't stranded on an outlier response.
//
// The invocation recipe is copied from the user's TTS plugin
// (~/.config/nix-config/configs/claude/plugins/tts/skills/say/scripts/speak.sh),
// which took the naive `claude --print` from 44s down to ~5s on small
// inputs by avoiding per-project CLAUDE.md, MCP, hook, and plugin
// discovery:
//
//   cd "${TMPDIR:-/tmp}" && \
//     TTS_SUBPROCESS=1 CLAUDECODE='' \
//     command claude --print \
//       --model haiku \
//       --session-id <fresh-uuid> \
//       --no-session-persistence \
//       --tools "" \
//       --disable-slash-commands \
//       --strict-mcp-config \
//       --system-prompt '<instructions>'
//
// Why each piece:
// - `cd TMPDIR`: project CLAUDE.md + .claude/ scanning happens from cwd
// - `CLAUDECODE=''`: unsets "already inside Claude Code" guard
// - `TTS_SUBPROCESS=1`: short-circuits user's own TTS stop-hook so it
//   doesn't recurse if they have one installed
// - `--session-id UUID + --no-session-persistence`: the combination
//   suppresses JSONL session-file creation entirely (neither flag alone
//   does). Without this our ephemeral rewrite calls would pollute
//   `~/.claude/projects/-private-var-folders.../` and show up as
//   "sessions" in our own sidebar.
// - `--tools ""`: no built-in tools (saves init time)
// - `--disable-slash-commands`: no skills scan
// - `--strict-mcp-config` (without any `--mcp-config`): no MCP servers
//
// Caveats:
// - Requires the user to have `claude` CLI installed and authenticated
//   via OAuth. If not, every call falls back to passthrough.
// - Global ~/.claude/CLAUDE.md still loads. --bare would skip it but
//   requires ANTHROPIC_API_KEY. A future opt-in setting could expose
//   `--bare` with a user-provided API key.
final class ClaudeCLISpeechProcessor: SpeechTextProcessor {
    private static let logger = Logger(subsystem: "local.claudecodevoice", category: "ClaudeCLISpeechProcessor")

    // Thread-safe Data accumulator for pipe-reader callbacks. macOS pipe
    // buffers are only ~64KB; if we let the child's stdout or stderr fill
    // without a concurrent drain, the child blocks on write and we never
    // see it exit. `readabilityHandler` fires on a private DispatchQueue,
    // not our actor, so the buffer has to be Sendable + thread-safe.
    private final class StreamBuffer: Sendable {
        private let data = Mutex(Data())

        func append(_ newData: Data) {
            guard !newData.isEmpty else { return }
            data.withLock { $0.append(newData) }
        }

        func snapshot() -> Data {
            data.withLock { $0 }
        }
    }

    // Keep rewrites bounded. Very long messages risk the CLI hanging on
    // a model response that exceeds reasonable latency; passthrough is
    // a better UX than making the user wait 60+ seconds on an outlier.
    private static let maxInputChars = 4000

    // Hard timeout on the subprocess. Measured empirically: Haiku on a
    // ~1300-char structure-heavy input (tables + code + lists) via this
    // invocation recipe takes ~40–50s end to end. Earlier 30s cap was
    // killing legitimate rewrites mid-stream. 90s gives comfortable
    // headroom without stranding the user forever on a real hang.
    private static let subprocessTimeout: Duration = .seconds(90)

    static let defaultInstructions = """
    Rewrite the input as plain spoken English suitable for text-to-speech. \
    Strip all markdown (headings, bold, italic), code fences, table pipes, \
    list markers (bullets and numbered), URLs, and file paths. Describe \
    code in natural English preserving identifier names. Preserve every \
    piece of information — do not summarize or drop detail. Do not add \
    preamble, commentary, or framing — return only the rewritten text.
    """

    private let instructions: String
    private let model: String
    // Computed on first use and cached. nil if claude isn't on PATH.
    private let binaryURLProvider: @Sendable () -> URL?

    init(
        instructions: String = ClaudeCLISpeechProcessor.defaultInstructions,
        model: String = "haiku",
        binaryLocator: @escaping @Sendable () -> URL? = { ClaudeCLISpeechProcessor.findClaudeBinary() }
    ) {
        self.instructions = instructions
        self.model = model
        self.binaryURLProvider = binaryLocator
    }

    func process(text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard text.count <= Self.maxInputChars else {
            Self.logger.debug("Skipping CLI rewrite: input too long (\(text.count, privacy: .public) chars)")
            return text
        }

        guard let binaryURL = binaryURLProvider() else {
            Self.logger.debug("claude CLI not found on PATH; passthrough")
            return text
        }

        let start = CFAbsoluteTimeGetCurrent()
        let result = await runSubprocess(binaryURL: binaryURL, input: text)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Self.logger.info(
            "claude CLI rewrite: \(text.count, privacy: .public) chars in \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms (\(result == nil ? "passthrough" : "rewritten", privacy: .public))"
        )
        return result ?? text
    }

    // MARK: - Subprocess

    // Runs the CLI with the plugin-pattern environment + flags. Returns
    // nil on any failure (nonzero exit, empty stdout, timeout, IO
    // error). Caller should treat nil as "passthrough."
    private func runSubprocess(binaryURL: URL, input: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            [model, instructions] in

            let process = Process()
            process.executableURL = binaryURL
            process.arguments = [
                "--print",
                "--model", model,
                "--session-id", UUID().uuidString,
                "--no-session-persistence",
                "--tools", "",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--system-prompt", instructions,
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            var env = ProcessInfo.processInfo.environment
            env["TTS_SUBPROCESS"] = "1"
            env["CLAUDECODE"] = ""  // explicit empty, not unset — CLI checks presence + value
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Drain both pipes concurrently via readabilityHandler rather
            // than readToEnd() after waitUntilExit(). macOS pipe buffers
            // are only ~64KB; on a long run with unbounded stderr (auth
            // warnings, deprecation notices) the buffer could fill and
            // the child would block on write while we wait on exit. We
            // haven't seen this in practice for `claude --print`, but
            // /usr/bin/say in SystemVoiceBackendDriver uses the same
            // pattern and it's cheap insurance.
            let stdoutBuffer = StreamBuffer()
            let stderrBuffer = StreamBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }

            func detachReaders() {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            }

            do {
                try process.run()
            } catch {
                detachReaders()
                Self.logger.error("Failed to launch claude CLI: \(error.localizedDescription, privacy: .public)")
                return nil
            }

            // Write the input to stdin and close so the CLI gets EOF.
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                detachReaders()
                Self.logger.error("Failed to write to claude stdin: \(error.localizedDescription, privacy: .public)")
                process.terminate()
                return nil
            }

            // Enforce timeout: kill the process if it hasn't exited.
            let timeoutTask = Task {
                try? await Task.sleep(for: Self.subprocessTimeout)
                if process.isRunning {
                    Self.logger.error("claude CLI exceeded \(Self.subprocessTimeout) timeout; terminating")
                    process.terminate()
                }
            }
            defer { timeoutTask.cancel() }

            process.waitUntilExit()

            // Stop the handlers and drain any bytes that arrived between
            // the last callback and pipe EOF.
            detachReaders()
            if let residualOut = try? stdoutPipe.fileHandleForReading.readToEnd() {
                stdoutBuffer.append(residualOut)
            }
            if let residualErr = try? stderrPipe.fileHandleForReading.readToEnd() {
                stderrBuffer.append(residualErr)
            }

            guard process.terminationStatus == 0 else {
                let stderrString = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""
                Self.logger.error(
                    "claude CLI exited \(process.terminationStatus, privacy: .public): \(stderrString, privacy: .public)"
                )
                return nil
            }

            guard let output = String(data: stdoutBuffer.snapshot(), encoding: .utf8) else {
                Self.logger.error("claude CLI stdout not valid UTF-8")
                return nil
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }

    // MARK: - Binary discovery

    // PATH-style lookup for the `claude` binary. Swift's Process needs
    // an absolute executableURL — we can't just pass "claude" and have
    // it resolved like a shell would. Caching is OK: if the user moves
    // their claude installation we reload the app.
    static func findClaudeBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let pathVar = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let fileManager = FileManager.default
        for dir in pathVar.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("claude")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // Whether the CLI is currently findable on PATH. Used by Settings
    // to gate the option availability.
    static var isAvailable: Bool {
        findClaudeBinary() != nil
    }
}
