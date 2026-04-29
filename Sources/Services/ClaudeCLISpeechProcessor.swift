import Foundation
import OSLog
import Synchronization

// Speech text optimizer that shells out to `claude` CLI (Claude Code)
// with Sonnet at --effort low. Handles code blocks, markdown tables,
// URLs, file paths, bullet and numbered lists, and headings correctly.
//
// Sonnet was chosen over Haiku after benchmarking: on our
// representative 1.3KB structure-heavy input Sonnet averaged ~9.6s
// with 0.2s run-to-run variance versus Haiku's ~18s with 12s variance
// (Haiku 4.5 has much noisier inference provisioning than Sonnet).
//
// --effort low was chosen via a follow-up eval sweep across all five
// levels (low, medium, high, xhigh, max) at fixed model=Sonnet. Low
// landed ~6.5s, max ~31.8s, no-flag default ~31.4s (so the CLI's
// default appears to be max). Output quality at low was
// indistinguishable from medium/high/max for our task — all five
// rewrote tables inline, dropped file extensions, replaced URLs with
// natural-language phrases, and preserved identifiers. See
// `eval-output/cli-eval-effort-*.md` for the data.
//
// Cost per rewrite is ~$0.01 worst case, absorbed by the user's
// OAuth'd Claude Code subscription.
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
// - `--no-session-persistence`: suppresses full message-history JSONL
//   writing. A small ai-title-only JSONL (~120 bytes) still gets
//   written per call. The sidebar filter in ClaudeTranscriptParser
//   drops those so they don't show up as phantom sessions; the
//   files themselves accumulate harmlessly on disk.
// - `--tools ""`: no built-in tools (saves init time)
// - `--disable-slash-commands`: no skills scan
// - `--strict-mcp-config` (without any `--mcp-config`): no MCP servers
//
// What we deliberately DON'T pass, and why:
// - `--session-id <UUID>` with a fixed UUID: tested, fails. Claude
//   rejects duplicate in-use session IDs ("Session ID … is already
//   in use") on the second and subsequent calls, silently breaking
//   rewrites. Reusing the same UUID to collapse to a single session
//   file doesn't work empirically — Claude's session-management
//   layer enforces uniqueness even under --no-session-persistence.
//   The "solve the artifact proliferation" problem has to be done
//   differently (a disk sweep on launch is the next option if it
//   ever matters enough).
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
    //
    // Also holds a Mutex-backed cancelled flag. Without it there's a
    // race window: if cancellation lands AFTER the worker task is
    // created but BEFORE it calls process.run(), then terminate() is
    // a no-op (process isn't running yet) and the launcher then
    // happily starts `claude`. The flag closes this by letting the
    // launcher bail out pre-launch if cancelled, and SIGTERMing
    // post-launch if cancellation raced past the pre-check.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let cancelledFlag = Mutex(false)

        var isCancelled: Bool {
            cancelledFlag.withLock { $0 }
        }

        func terminate() {
            cancelledFlag.withLock { $0 = true }
            // The flag write above happens-before any read inside the
            // worker task via the Mutex memory barrier. A concurrent
            // launcher that has already entered process.run() gets
            // SIGTERM'd here; one that hasn't yet started will see the
            // flag on its pre-launch check and skip.
            if process.isRunning {
                process.terminate()
            }
        }
    }

    // Keep rewrites bounded. Very long messages risk the CLI hanging on
    // a model response that exceeds reasonable latency; passthrough is
    // a better UX than making the user wait 60+ seconds on an outlier.
    private static let maxInputChars = 4000

    // Hard timeout on the subprocess. Sonnet at --effort low averages
    // ~6-7s on a ~1.3KB structure-heavy input. Network hiccups and
    // auth-refresh paths can stretch that — 60s caps the worst case
    // without stranding the user on a real hang.
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
    // Effort level passed to `claude --effort <level>`. nil omits
    // the flag (which the CLI treats as `max` per our eval — slow).
    // Levels: low, medium, high, xhigh, max. Default is `low` based
    // on `cli-eval-effort` data: ~5x faster than no-flag with no
    // measurable quality loss for our markdown→speech task.
    private let effort: String?
    // Computed on first use and cached. nil if claude isn't on PATH.
    private let binaryURLProvider: @Sendable () -> URL?

    init(
        instructions: String = ClaudeCLISpeechProcessor.defaultInstructions,
        model: String = "sonnet",
        effort: String? = "low",
        binaryLocator: @escaping @Sendable () -> URL? = { ClaudeCLISpeechProcessor.findClaudeBinary() }
    ) {
        self.instructions = instructions
        self.model = model
        self.effort = effort
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
            "claude CLI rewrite: \(text.count, privacy: .public) chars in \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms effort=\(self.effort ?? "default", privacy: .public) (\(result == nil ? "passthrough" : "rewritten", privacy: .public))"
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
                [model, instructions, effort] in
                await Self.runSubprocessBody(
                    processBox: processBox,
                    binaryURL: binaryURL,
                    input: input,
                    model: model,
                    instructions: instructions,
                    effort: effort
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
        instructions: String,
        effort: String?
    ) async -> String? {
        let process = processBox.process
        process.executableURL = binaryURL
        var arguments: [String] = [
            "--print",
            "--model", model,
            "--no-session-persistence",
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--system-prompt", instructions,
        ]
        if let effort {
            arguments.append(contentsOf: ["--effort", effort])
        }
        process.arguments = arguments
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

        // Pre-launch cancellation check. If the outer Task was cancelled
        // while the worker was being scheduled, bail before spawning
        // the subprocess. Without this the cancellation handler's
        // terminate() is a no-op (nothing running yet) and claude
        // launches anyway.
        if processBox.isCancelled {
            detachReaders()
            return nil
        }

        do {
            try process.run()
        } catch {
            detachReaders()
            Self.logger.error("Failed to launch claude CLI: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Post-launch re-check — the cancellation handler may have
        // observed isRunning=false between the flag write and the
        // process.run() above. Catch that race here by terminating.
        if processBox.isCancelled {
            process.terminate()
            detachReaders()
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
