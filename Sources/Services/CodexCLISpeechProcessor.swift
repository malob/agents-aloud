import Foundation
import OSLog
import Synchronization

// Speech text optimizer that shells out to `codex` CLI (OpenAI Codex).
// Built as a structural mirror of ClaudeCLISpeechProcessor so the two
// can be A/B'd in the eval harness and (if it earns its keep) shipped
// side-by-side as alternative speech-text optimizers.
//
// Architecture / why each piece:
//
// - `cd $TMPDIR` (via Process.currentDirectoryURL): keeps any
//   project-scoped `.codex/config.toml` from leaking into the call.
// - `--cd "$TMPDIR"`: redundant belt + suspenders that tells Codex
//   itself to treat that path as the workspace root.
// - `--ephemeral`: equivalent of Claude's `--no-session-persistence`.
//   No session JSONL on disk.
// - `--ignore-user-config`: skip $CODEX_HOME/config.toml so the user's
//   per-machine setup (model, reasoning_effort, MCPs, plugins, etc.)
//   can't drift our rewrite behavior.
// - `--ignore-rules`: skip user/project execpolicy `.rules` files. We
//   aren't executing anything anyway.
// - `--sandbox read-only`: defense-in-depth. The agent shouldn't need
//   to touch the filesystem; if it tries, deny. Pairs with
//   `approval_policy = "never"` (set via -c) for fully unattended runs.
// - `--skip-git-repo-check`: `$TMPDIR` isn't a git repo; without this
//   Codex refuses to start.
// - `--color never`: no ANSI escapes in any captured output.
// - `--output-last-message <tempfile>`: writes the agent's final text
//   message to a file we read on success. Cleaner than parsing stdout
//   (which carries agent-loop chatter even at low verbosity).
//
// Config overrides via `-c`:
// - `model_reasoning_effort`: minimal | low | medium | high | xhigh.
//   Direct equivalent of Claude's --effort, just with one extra rung
//   below low (minimal).
// - `model_verbosity`: low | medium | high. Surface area control on
//   the response text. Set to `low` keeps the rewrite tight.
// - `hide_agent_reasoning = true`: suppress reasoning from the output
//   stream so we don't accidentally capture it.
// - `web_search = "disabled"`: rewriter doesn't need to research.
// - `approval_policy = "never"`: don't pause for command approvals.
//   Safe under read-only sandbox (no destructive action possible).
// - `service_tier = "fast"`: opts into the fast inference tier when
//   the `fast_mode` feature flag is enabled (it is, by default).
// - `personality = "none"`: no conversational warmth in the rewrite
//   voice — speech text shouldn't have model-personality leakage.
//
// Input delivery: prompt arg carries the rewrite rules (treated as
// the user message); the message-to-rewrite is piped via stdin and
// Codex appends it as a `<stdin>` block under the rules.
final class CodexCLISpeechProcessor: SpeechTextProcessor {
    private static let logger = Logger(subsystem: "local.claudecodevoice", category: "CodexCLISpeechProcessor")

    // Same pipe-drain rationale as Claude's processor: macOS pipe
    // buffers are ~64KB; without a concurrent drain a child can block
    // on write and never exit. readabilityHandler fires on a private
    // DispatchQueue so the buffer must be Sendable + thread-safe.
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

    // Same cancellation-flag rationale as ClaudeCLISpeechProcessor.
    // See that file's ProcessBox doc-comment for why both pre-launch
    // and post-launch checks are needed.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let cancelledFlag = Mutex(false)

        var isCancelled: Bool {
            cancelledFlag.withLock { $0 }
        }

        func terminate() {
            cancelledFlag.withLock { $0 = true }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    // Mirror of Claude's cap. Even though Codex on the fast tier with
    // mini may be quicker, oversize messages still risk model-side
    // latency cliffs and token-limit edge cases. Same 8000 cap; we
    // can lift further if eval data justifies it.
    private static let maxInputChars = 8000

    // Hard timeout. Same 60s as Claude — if a rewrite exceeds that,
    // the user is better off hearing the source text than waiting.
    private static let subprocessTimeout: Duration = .seconds(60)

    // System-prompt-equivalent text. Codex doesn't have a system-prompt
    // flag at the CLI level, so this is delivered as the prompt arg
    // (treated as a user message). The message-to-rewrite arrives as
    // a `<stdin>` block underneath.
    //
    // Mirrors ClaudeCLISpeechProcessor's defaultInstructions intent
    // verbatim — the rules are about TTS output shape, not about the
    // backend, so they should produce the same rewrite regardless of
    // which CLI we route through.
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
    private let effort: String          // model_reasoning_effort
    private let verbosity: String       // model_verbosity
    private let useFastTier: Bool       // service_tier = "fast" override
    // Computed on first use and cached. nil if codex isn't on PATH.
    private let binaryURLProvider: @Sendable () -> URL?

    init(
        instructions: String = CodexCLISpeechProcessor.defaultInstructions,
        // Default: gpt-5.5. The 54-run eval showed gpt-5.4-mini was
        // unreliable on code-block handling (4/18 outputs leaked raw
        // Swift verbatim — disastrous for TTS); 5.5 was reliable
        // across all 18. gpt-5.3-codex-spark was the fastest + also
        // reliable, but it's research-preview and Pro-only — better
        // to expose as an opt-in alternative than as the default.
        model: String = "gpt-5.5",
        // Default: low. Same finding as Claude — quality is
        // indistinguishable from medium/high for our task and low is
        // the fastest of the three.
        effort: String = "low",
        // Default: medium. Slightly more connective tissue than low
        // makes the rewrites flow better as listened audio without
        // adding meaningful length.
        verbosity: String = "medium",
        // Default: off (let Codex pick the user's plan default).
        // Fast tier consumes credits at a higher rate per OpenAI's
        // rate card and the eval didn't show a reliable latency
        // benefit anyway. Keep this as an opt-in if we ever expose
        // it; not worth the rate-limit cost as a default.
        useFastTier: Bool = false,
        binaryLocator: @escaping @Sendable () -> URL? = { CodexCLISpeechProcessor.findCodexBinary() }
    ) {
        self.instructions = instructions
        self.model = model
        self.effort = effort
        self.verbosity = verbosity
        self.useFastTier = useFastTier
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
            Self.logger.debug("codex CLI not found on PATH; passthrough")
            return text
        }

        let start = CFAbsoluteTimeGetCurrent()
        let result = await runSubprocess(binaryURL: binaryURL, input: text)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Self.logger.info(
            "codex CLI rewrite: \(text.count, privacy: .public) chars in \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms model=\(self.model, privacy: .public) effort=\(self.effort, privacy: .public) verbosity=\(self.verbosity, privacy: .public) fast=\(self.useFastTier, privacy: .public) (\(result == nil ? "passthrough" : "rewritten", privacy: .public))"
        )
        return result ?? text
    }

    // MARK: - Subprocess

    private func runSubprocess(binaryURL: URL, input: String) async -> String? {
        let processBox = ProcessBox()
        let outputFileURL = Self.makeOutputFileURL()

        let result: String? = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                [model, effort, verbosity, useFastTier, instructions] in
                await Self.runSubprocessBody(
                    processBox: processBox,
                    binaryURL: binaryURL,
                    input: input,
                    model: model,
                    effort: effort,
                    verbosity: verbosity,
                    useFastTier: useFastTier,
                    instructions: instructions,
                    outputFileURL: outputFileURL
                )
            }.value
        } onCancel: {
            processBox.terminate()
        }

        // Best-effort cleanup of the output tempfile. If we never got
        // to write it (early-failure), unlink is a no-op.
        try? FileManager.default.removeItem(at: outputFileURL)
        return result
    }

    private static func runSubprocessBody(
        processBox: ProcessBox,
        binaryURL: URL,
        input: String,
        model: String,
        effort: String,
        verbosity: String,
        useFastTier: Bool,
        instructions: String,
        outputFileURL: URL
    ) async -> String? {
        let process = processBox.process
        process.executableURL = binaryURL

        // Build args. Order matches the doc-comment grouping above so
        // diffing the build is straightforward.
        var arguments: [String] = [
            "exec",
            "--model", model,
            "--color", "never",
            "--cd", NSTemporaryDirectory(),
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--output-last-message", outputFileURL.path,
            // -c overrides for behavior not exposed via dedicated flags.
            "-c", "model_reasoning_effort=\"\(effort)\"",
            "-c", "model_verbosity=\"\(verbosity)\"",
            "-c", "hide_agent_reasoning=true",
            "-c", "web_search=\"disabled\"",
            "-c", "approval_policy=\"never\"",
            "-c", "personality=\"none\"",
        ]
        if useFastTier {
            arguments.append(contentsOf: ["-c", "service_tier=\"fast\""])
        }
        // Final positional arg: the rewrite instructions. Codex treats
        // this as a user message; the input-to-rewrite arrives via
        // stdin and lands inside a `<stdin>` block beneath.
        arguments.append(instructions)
        process.arguments = arguments

        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        // Inherit env unchanged. Unlike Claude we don't have a
        // TTS_SUBPROCESS marker convention to set.
        process.environment = ProcessInfo.processInfo.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        if processBox.isCancelled {
            detachReaders()
            return nil
        }

        do {
            try process.run()
        } catch {
            detachReaders()
            Self.logger.error("Failed to launch codex CLI: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if processBox.isCancelled {
            process.terminate()
            detachReaders()
            return nil
        }

        // Pipe input via stdin → Codex appends as `<stdin>` block.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            detachReaders()
            Self.logger.error("Failed to write to codex stdin: \(error.localizedDescription, privacy: .public)")
            process.terminate()
            return nil
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: Self.subprocessTimeout)
            if process.isRunning {
                Self.logger.error("codex CLI exceeded \(Self.subprocessTimeout) timeout; terminating")
                process.terminate()
            }
        }
        defer { timeoutTask.cancel() }

        process.waitUntilExit()

        detachReaders()
        if let residualOut = try? stdoutPipe.fileHandleForReading.readToEnd() {
            stdoutBuffer.append(residualOut)
        }
        if let residualErr = try? stderrPipe.fileHandleForReading.readToEnd() {
            stderrBuffer.append(residualErr)
        }

        guard process.terminationStatus == 0 else {
            let stderrString = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""
            let stdoutString = String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
            Self.logger.error(
                "codex CLI exited \(process.terminationStatus, privacy: .public): stderr=\(stderrString, privacy: .public) stdout=\(stdoutString, privacy: .public)"
            )
            return nil
        }

        // Output captured via --output-last-message.
        guard let outputData = try? Data(contentsOf: outputFileURL),
              let output = String(data: outputData, encoding: .utf8) else {
            Self.logger.error("codex output file missing or not UTF-8: \(outputFileURL.path, privacy: .public)")
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Tempfile + binary discovery

    private static func makeOutputFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-tts-output-\(UUID().uuidString).txt", isDirectory: false)
    }

    // Mirrors ClaudeCLISpeechProcessor.findClaudeBinary's PATH +
    // common-install-locations search. GUI-launched apps don't get
    // the user's shell PATH, so we have to look in the obvious places
    // explicitly.
    static func findCodexBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        var searchDirs: [String] = []
        if let pathVar = env["PATH"] {
            searchDirs.append(contentsOf: pathVar.split(separator: ":").map(String.init))
        }
        searchDirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.nix-profile/bin",
            "/etc/profiles/per-user/\(fileManager.displayName(atPath: home))/bin",
            "/run/current-system/sw/bin",
            "/usr/bin", "/bin",
        ])

        var seen = Set<String>()
        for dir in searchDirs where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static var isAvailable: Bool {
        findCodexBinary() != nil
    }
}
