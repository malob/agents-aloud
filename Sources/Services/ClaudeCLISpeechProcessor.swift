import Foundation
import OSLog
import Synchronization

// Speech text optimizer that shells out to `claude` CLI (Claude Code)
// with Sonnet. Strictly better output than the on-device FoundationModel
// — handles code blocks, markdown tables, URLs, file paths, bullet and
// numbered lists, and headings correctly. Sonnet was chosen over Haiku
// after benchmarking: on our representative 1.3KB structure-heavy
// input Sonnet averaged ~9.6s with 0.2s run-to-run variance, versus
// Haiku's ~18s with 12s variance (Haiku 4.5 has much noisier inference
// provisioning than Sonnet). Cost per rewrite is ~$0.01 worst case,
// absorbed by the user's OAuth'd Claude Code subscription.
//
// The invocation recipe is copied from the user's TTS plugin
// (~/.config/nix-config/configs/claude/plugins/tts/skills/say/scripts/speak.sh),
// which took the naive `claude --print` from 44s down to the numbers
// above by avoiding per-project CLAUDE.md, MCP, hook, and plugin
// discovery:
//
//   cd "${TMPDIR:-/tmp}" && \
//     TTS_SUBPROCESS=1 CLAUDECODE='' \
//     command claude --print \
//       --model sonnet \
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
// - `--no-session-persistence`: suppresses JSONL session-file creation
//   entirely. Earlier we paired it with `--session-id UUID`, but that
//   combination actually creates an empty (zero-message) session file,
//   which is worse — the flag alone does the right thing.
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

    // Holds a Process instance accessible from both the detached worker
    // Task (which blocks on waitUntilExit) and the cancellation handler
    // (which terminates the subprocess when the outer Task is
    // cancelled). Process instance methods are thread-safe per Apple's
    // docs; @unchecked Sendable is correct here.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    // Keep rewrites bounded. Very long messages risk the CLI hanging on
    // a model response that exceeds reasonable latency; passthrough is
    // a better UX than making the user wait 60+ seconds on an outlier.
    private static let maxInputChars = 4000

    // Hard timeout on the subprocess. Sonnet averages ~10s on a ~1.3KB
    // structure-heavy input with very tight run-to-run variance, but
    // network hiccups and auth-refresh paths can stretch it. 60s caps
    // the worst case without stranding the user forever on a real hang.
    private static let subprocessTimeout: Duration = .seconds(60)

    // System prompt steering the model toward "rewrite for speech,
    // preserve everything." The two NEVER lines are both load-bearing:
    //
    //  - Without the URL/path-spelling line, the model (Haiku and
    //    Sonnet both) dot-slash-spells URLs and paths letter by letter.
    //  - Without the dot-extension line, the model leaves bare
    //    filenames like `AppConfig.swift` intact — TTS then reads
    //    them as "AppConfig dot swift." Caught this in a 4-run
    //    benchmark: 3/4 runs leaked filename-with-extension.
    //
    // Keep both rules. They add ~300 chars to the prompt and the
    // latency impact is within API-side noise.
    static let defaultInstructions = """
    Rewrite the input as plain spoken English suitable for text-to-speech.

    Strip all markdown (headings, bold, italic, code fences, table pipes, \
    bullet and numbered list markers).

    NEVER spell URLs or file paths out loud character by character \
    (no "dot com slash benchmarks," no "slash Users slash malo slash …"). \
    Replace a URL with a short natural phrase like "a link to the \
    benchmark methodology."

    NEVER include filenames with their dot-extensions — not \
    "AppConfig.swift," not "fixtures.sh," not "benchmarks.csv." Refer \
    to files by their short name plus the language or purpose, for \
    example "the AppConfig Swift file," "the regenerate-fixtures \
    script," "the benchmarks CSV." Never use full paths.

    Describe code in natural English, preserving every identifier name \
    exactly as written.

    Preserve every piece of information — do not summarize or drop \
    detail. Do not add preamble, commentary, or framing. Return only \
    the rewritten text.
    """

    private let instructions: String
    private let model: String
    // Computed on first use and cached. nil if claude isn't on PATH.
    private let binaryURLProvider: @Sendable () -> URL?

    init(
        instructions: String = ClaudeCLISpeechProcessor.defaultInstructions,
        model: String = "sonnet",
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
    // error, task cancellation). Caller should treat nil as
    // "passthrough."
    //
    // Cancellation: wraps the work in withTaskCancellationHandler so
    // that if the outer Task is cancelled (user hit Stop, switched
    // session, etc.) the subprocess is terminated synchronously from
    // the cancellation handler. Without this the `claude` subprocess
    // runs to completion or the 60s timeout regardless of user intent.
    private func runSubprocess(binaryURL: URL, input: String) async -> String? {
        let processBox = ProcessBox()

        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                [model, instructions] in
                await Self.runSubprocessBody(
                    processBox: processBox,
                    binaryURL: binaryURL,
                    input: input,
                    model: model,
                    instructions: instructions
                )
            }.value
        } onCancel: {
            processBox.terminate()
        }
    }

    // Body of the subprocess run, factored out so the Task.detached
    // closure can stay short and the cancellation wiring above stays
    // readable. All state (pipes, buffers, timeout) is local to this
    // call — only the process reference is shared via the box.
    private static func runSubprocessBody(
        processBox: ProcessBox,
        binaryURL: URL,
        input: String,
        model: String,
        instructions: String
    ) async -> String? {
        let process = processBox.process
        process.executableURL = binaryURL
        process.arguments = [
            "--print",
            "--model", model,
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
        // the child would block on write while we wait on exit.
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
    }

    // MARK: - Binary discovery

    // Search PATH, but ALSO search a hard-coded list of common install
    // locations (Homebrew on Apple silicon + Intel, user-local prefix,
    // global npm). The inherited PATH in a Finder/LaunchServices-spawned
    // app is typically `/usr/bin:/bin:/usr/sbin:/sbin` — none of which
    // catch the way most users install claude. Without this fallback,
    // the CLI option appears unavailable to GUI-launched builds even
    // when the binary is present.
    //
    // Swift's Process needs an absolute executableURL — we can't pass
    // bare "claude" and have Process resolve it like a shell would.
    static func findClaudeBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        var searchDirs: [String] = []
        if let pathVar = env["PATH"] {
            searchDirs.append(contentsOf: pathVar.split(separator: ":").map(String.init))
        }
        // Common install locations appended after PATH so an
        // explicitly-configured PATH still wins.
        searchDirs.append(contentsOf: [
            "/opt/homebrew/bin",        // Homebrew on Apple silicon
            "/usr/local/bin",           // Homebrew on Intel + MacPorts
            "\(home)/.local/bin",       // pipx / user-local installs
            "\(home)/.nix-profile/bin", // nix-darwin
            "/etc/profiles/per-user/\(fileManager.displayName(atPath: home))/bin", // nix-darwin profile
            "/run/current-system/sw/bin", // nix-darwin system
            "/usr/bin", "/bin",
        ])

        // Dedupe preserving order.
        var seen = Set<String>()
        for dir in searchDirs where seen.insert(dir).inserted {
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
