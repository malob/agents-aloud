import Foundation
import FoundationModels
import Testing
@testable import ClaudeCodeVoice

// Manual-eval harness for evaluating whether Apple's on-device
// FoundationModel can rewrite assistant output for TTS — independent
// of the production processor's filtering + short-circuit logic.
//
// The goal is to answer: "Is the model + the right instructions
// capable of producing good spoken output for content that's
// structurally hostile to speech (tables, code blocks, URLs,
// headings, lists)?" Not "does our filter work" — the filter question
// comes later.
//
// Run:
//   ENABLE_FM_EVAL=1 swift test --filter FoundationModelSpeechEvalTests
//
// Output lands at eval-output/speech-eval-TIMESTAMP.md.
//
// To iterate: edit the `instructionVariants` below, re-run, compare.
// One realistic input is run through every variant so differences
// are attributable to the instructions, not the content.
struct FoundationModelSpeechEvalTests {

    private static var isEvalEnabled: Bool {
        ProcessInfo.processInfo.environment["ENABLE_FM_EVAL"] == "1"
    }

    @Test(.enabled(if: isEvalEnabled))
    @MainActor
    func emitEvalMarkdown() async throws {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            Issue.record("FoundationModel unavailable: \(availability)")
            return
        }

        let outputURL = try resolveOutputURL(suffix: "fm")
        var markdown = "# Speech Text Optimization — Prompt Iteration\n\n"
        markdown.append("Run at: \(Date().formatted())\n\n")
        markdown.append("One realistic assistant message, run through each instruction variant. ")
        markdown.append("Model calls bypass the production processor's short-circuits — we're ")
        markdown.append("evaluating the model + instructions directly.\n\n")
        markdown.append("---\n\n## Input\n\n")
        markdown.append("```\n\(Self.representativeInput)\n```\n\n")
        markdown.append("Character count: \(Self.representativeInput.count)\n\n")
        markdown.append("---\n\n")

        for variant in Self.instructionVariants {
            markdown.append("## Variant: \(variant.name)\n\n")
            markdown.append("**Instructions:**\n\n```\n\(variant.instructions)\n```\n\n")

            let session = LanguageModelSession(instructions: variant.instructions)
            let start = ContinuousClock.now
            let output: String
            do {
                let response = try await session.respond(to: Self.representativeInput)
                output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                output = "[ERROR: \(error.localizedDescription)]"
            }
            let elapsed = ContinuousClock.now - start

            markdown.append("**Latency:** \(formatDuration(elapsed))\n\n")
            markdown.append("**Output:**\n\n```\n\(output)\n```\n\n")
            markdown.append("---\n\n")
        }

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Eval output: \(outputURL.path)")
    }

    // MARK: - The representative input
    //
    // One message that tries to contain every TTS-hostile thing we
    // actually see in Claude Code output: a table, a code block with
    // explanation, URLs, bullet list, numbered list, inline code,
    // file paths, and a heading. If the model handles THIS well, it
    // can handle the narrower cases.

    private static let representativeInput = """
    # Benchmark comparison

    Here's what I found when I ran the tests on different models:

    | Model      | Latency | Accuracy |
    |------------|---------|----------|
    | Small-v2   | 45ms    | 72%      |
    | Medium-v2  | 120ms   | 84%      |
    | Large-v2   | 310ms   | 91%      |

    The Medium model is the sweet spot for most workloads. Full benchmark \
    methodology is documented at https://example.com/benchmarks/methodology \
    and the raw data lives in /Users/malo/Code/project/data/benchmarks.csv.

    To switch between models, update the `ModelKind` enum in \
    `Sources/Services/ModelSelector.swift`:

    ```swift
    enum ModelKind {
        case small, medium, large
        var maxTokens: Int {
            switch self {
            case .small: return 1024
            case .medium: return 2048
            case .large: return 4096
            }
        }
    }
    ```

    A few things to consider when picking:

    - Real-time use cases should prefer Small-v2 despite the accuracy drop.
    - Batch processing can afford Large-v2; throughput is not the bottleneck.
    - If you need intermediate quality, Medium-v2 is the right default.

    Steps to deploy the change:

    1. Update the `ModelKind` default in `AppConfig.swift`.
    2. Regenerate the fixtures with `./script/regenerate-fixtures.sh`.
    3. Run `swift test` and verify all suites pass.

    Let me know which you want to go with.
    """

    // MARK: - Instruction variants
    //
    // Edit these, re-run the eval, compare outputs. Start with the
    // current production prompt as the baseline.

    private struct InstructionVariant {
        let name: String
        let instructions: String
    }

    private static let instructionVariants: [InstructionVariant] = [
        InstructionVariant(
            name: "Baseline (current production prompt)",
            instructions: FoundationModelSpeechProcessor.instructions
        ),

        // Add variants below, re-run, compare. Keep the current best at
        // the bottom so it's the last thing in the output file.
        InstructionVariant(
            name: "V2 — stronger anti-summarization + explicit length guard",
            instructions: """
            You adapt written text for text-to-speech playback. The input is \
            output from a coding assistant that may contain code blocks, \
            markdown tables, URLs, file paths, bullet lists, numbered lists, \
            headings, and inline formatting.

            Your ONE job: make the text comfortable to listen to, WITHOUT \
            changing what it says.

            Absolute rules:
            1. Preserve every piece of information. Do NOT summarize. Do NOT \
               drop sentences, even if they feel redundant. The output should \
               be roughly the same length as the input, or slightly longer — \
               never shorter.
            2. For code blocks: describe what the code does in natural English, \
               preserving every identifier name exactly as written. If the \
               code has 5 cases in a switch, describe all 5.
            3. For tables: read each row as a sentence, using the column \
               headers naturally. Don't say "pipe" or "dash." Read the table \
               values in order.
            4. For URLs: say "a link to" plus the site name or purpose, \
               instead of spelling out the URL.
            5. For file paths: refer to "the file called X" instead of \
               reading slashes and extensions.
            6. For bullet or numbered lists: say "First... Second... Third..." \
               or similar natural transitions.
            7. For markdown formatting (bold, italic, headings): remove the \
               markers (asterisks, underscores, hashes) but keep the words \
               they wrapped. Headings become short declarative sentences.
            8. Never add your own commentary, opinions, conclusions, or \
               content not present in the input.
            9. Return only the adapted text. No quotes, no framing, no \
               "Here is the adapted version" — just the spoken form.
            """
        ),

        InstructionVariant(
            name: "V3 — consequence framing + few-shot example",
            instructions: """
            Your output will be sent DIRECTLY to a text-to-speech engine and \
            read aloud without further processing. The TTS engine reads every \
            character literally: a pipe becomes the word "pipe", a backtick \
            becomes "backtick", a hash becomes "hash." Leaving markdown \
            characters in your output makes the spoken version sound broken.

            Rewrite the user's input into plain prose suitable for spoken \
            English. No markdown. No code fences. No table pipes. No bullet \
            dashes. No heading hashes. Just sentences.

            Preserve every piece of information. This is NOT a summary. If \
            the input has 5 bullets, your output has 5 corresponding \
            sentences. If the input has a table with 3 rows, your output \
            describes all 3 rows.

            Example input:
            ---
            ## Results

            | City  | Population |
            |-------|------------|
            | Tokyo | 37M        |
            | Delhi | 33M        |

            See `https://example.com/data` for sources.
            ---

            Example output:
            Results. Tokyo has a population of 37 million, and Delhi has a \
            population of 33 million. See the link for sources.
            ---

            Now rewrite the actual input below. Return only the rewritten \
            text, nothing else.
            """
        ),

        InstructionVariant(
            name: "V4 — minimal + few-shot only",
            instructions: """
            Rewrite the input as plain spoken English. Strip all markdown, \
            code fences, table pipes, list markers, heading hashes, and URLs. \
            Preserve every detail.

            Example input: "## Notes\\n- first\\n- second\\nSee \
            `/path/to/file.txt`."

            Example output: "Notes. First. Second. See the file named \
            file.txt."

            Now rewrite:
            """
        ),
    ]

    // MARK: - Claude CLI end-to-end eval
    //
    // Runs the same representative input through ClaudeCLISpeechProcessor
    // (which wraps `claude --print --model haiku` with the plugin's
    // env/flag recipe). Verifies end-to-end that our Swift wrapper
    // produces the same quality we saw from the shell.

    @Test(.enabled(if: isEvalEnabled))
    @MainActor
    func emitClaudeCLIEval() async throws {
        guard ClaudeCLISpeechProcessor.isAvailable else {
            Issue.record("claude CLI not found on PATH")
            return
        }

        let processor = ClaudeCLISpeechProcessor()
        let outputURL = try resolveOutputURL(suffix: "cli")

        var markdown = "# Speech Text Optimization — Claude CLI end-to-end\n\n"
        markdown.append("Run at: \(Date().formatted())\n\n")
        markdown.append("The same representative input used in emitEvalMarkdown, piped through ")
        markdown.append("`ClaudeCLISpeechProcessor` which invokes `claude --print --model sonnet` ")
        markdown.append("with the plugin-pattern environment (cd TMPDIR + CLAUDECODE='' + ")
        markdown.append("TTS_SUBPROCESS=1 + `--no-session-persistence --tools ''` ")
        markdown.append("+ `--disable-slash-commands --strict-mcp-config`).\n\n")
        markdown.append("---\n\n## Input\n\n```\n\(Self.representativeInput)\n```\n\n")
        markdown.append("Character count: \(Self.representativeInput.count)\n\n---\n\n")

        let start = ContinuousClock.now
        let output = await processor.process(text: Self.representativeInput)
        let elapsed = ContinuousClock.now - start

        markdown.append("## Output\n\n")
        markdown.append("**Latency:** \(formatDuration(elapsed))\n\n")
        markdown.append("**Identical to input:** \(output == Self.representativeInput ? "yes (PASSTHROUGH)" : "no")\n\n")
        markdown.append("```\n\(output)\n```\n")

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Eval output: \(outputURL.path)")
    }

    // MARK: - IO helpers

    private func resolveOutputURL(suffix: String = "fm") throws -> URL {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let outputDir = repoRoot.appendingPathComponent("eval-output", isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return outputDir.appendingPathComponent("speech-eval-\(suffix)-\(timestamp).md", isDirectory: false)
    }

    private func formatDuration(_ duration: Duration) -> String {
        let millis = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0f ms", millis)
    }
}
