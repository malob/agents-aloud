import Foundation
import Testing
@testable import ClaudeCodeVoice

// Manual-eval harness for the Claude CLI speech rewriter. Runs one
// realistic structure-heavy assistant message through each
// ClaudeCLIModel in turn and writes a markdown comparison to
// `eval-output/` so we can eyeball output quality + latency when
// picking model defaults or weighing a model-picker tweak.
//
// Env-gated because the test makes real network calls to Claude,
// takes tens of seconds per model, and requires the user to have
// the `claude` CLI authenticated. Routine `swift test` runs skip it.
//
// Run:
//   ENABLE_SPEECH_EVAL=1 swift test --filter ClaudeCLISpeechEvalTests
//
// Output lands at `eval-output/cli-eval-<TIMESTAMP>.md`.
//
// This is a reinstated, scope-narrowed version of the eval harness
// we deleted along with the FoundationModel backend — now focused
// on comparing Claude CLI models (Haiku vs Sonnet vs Opus) rather
// than iterating on FM prompt variants.
struct ClaudeCLISpeechEvalTests {
    private static var isEvalEnabled: Bool {
        ProcessInfo.processInfo.environment["ENABLE_SPEECH_EVAL"] == "1"
    }

    // Effort levels supported by `claude --effort`. Run from cheapest
    // to most expensive so the markdown reads top-down by cost. The
    // "default" entry omits the flag entirely to capture the
    // shipped-as-of-this-commit behavior.
    private static let effortSweep: [(label: String, value: String?)] = [
        ("default (no flag)", nil),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max"),
    ]

    @Test(.enabled(if: isEvalEnabled))
    func emitEffortComparisonEval() async throws {
        // Sweep --effort on Sonnet (the default model) against our
        // representative input. Goal: find the lowest effort level
        // whose rewrite quality is indistinguishable from higher
        // levels — that's the new shipping default.
        guard ClaudeCLISpeechProcessor.isAvailable else {
            Issue.record("claude CLI not found on PATH")
            return
        }

        let outputURL = try resolveOutputURL(name: "cli-eval-effort")
        var markdown = "# Claude CLI Speech Rewriter — Effort Sweep (Sonnet)\n\n"
        markdown.append("Run at: \(Date().formatted())\n\n")
        markdown.append("Same representative input rewritten by Sonnet at each `--effort` ")
        markdown.append("level. Goal: find the lowest level whose output quality is ")
        markdown.append("indistinguishable from higher levels — that becomes the new ")
        markdown.append("shipping default.\n\n")
        markdown.append("Latency includes the full subprocess round-trip. Run sequentially ")
        markdown.append("to keep latency numbers honest (no API queueing across runs).\n\n")
        markdown.append("---\n\n## Input\n\n```\n\(Self.representativeInput)\n```\n\n")
        markdown.append("Character count: \(Self.representativeInput.count)\n\n---\n\n")

        for (label, value) in Self.effortSweep {
            markdown.append("## Effort: \(label)\n\n")

            let processor = ClaudeCLISpeechProcessor(
                model: "sonnet",
                effort: value
            )
            let start = ContinuousClock.now
            let output = await processor.process(text: Self.representativeInput)
            let elapsed = ContinuousClock.now - start

            let identicalToInput = output == Self.representativeInput
            markdown.append("**Latency:** \(formatDuration(elapsed))\n\n")
            if identicalToInput {
                markdown.append("**Identical to input:** yes — PASSTHROUGH (CLI returned non-zero or empty; check OSLog)\n\n")
            } else {
                markdown.append("**Output length:** \(output.count) chars (input was \(Self.representativeInput.count))\n\n")
            }
            markdown.append("**Output:**\n\n```\n\(output)\n```\n\n")
            markdown.append("---\n\n")
        }

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Eval output: \(outputURL.path)")
    }

    @Test(.enabled(if: isEvalEnabled))
    func emitModelComparisonEval() async throws {
        guard ClaudeCLISpeechProcessor.isAvailable else {
            Issue.record("claude CLI not found on PATH")
            return
        }

        let outputURL = try resolveOutputURL()
        var markdown = "# Claude CLI Speech Rewriter — Model Comparison\n\n"
        markdown.append("Run at: \(Date().formatted())\n\n")
        markdown.append("The same representative input is routed through each model in turn. ")
        markdown.append("Uses the production `ClaudeCLISpeechProcessor`, so results reflect the ")
        markdown.append("real flag recipe + system prompt — not an idealized fixture.\n\n")
        markdown.append("Latency includes the full subprocess round-trip (spawn, auth probe, ")
        markdown.append("rewrite, drain). Output length lets us eyeball whether a model is over- ")
        markdown.append("or under-summarizing — a rewrite should be roughly the same size as the ")
        markdown.append("input, never much shorter.\n\n")
        markdown.append("---\n\n## Input\n\n```\n\(Self.representativeInput)\n```\n\n")
        markdown.append("Character count: \(Self.representativeInput.count)\n\n---\n\n")

        for model in ClaudeCLIModel.allCases {
            markdown.append("## \(model.displayName) (`\(model.cliArgument)`)\n\n")

            let processor = ClaudeCLISpeechProcessor(model: model.cliArgument)
            let start = ContinuousClock.now
            let output = await processor.process(text: Self.representativeInput)
            let elapsed = ContinuousClock.now - start

            let identicalToInput = output == Self.representativeInput
            markdown.append("**Latency:** \(formatDuration(elapsed))\n\n")
            if identicalToInput {
                markdown.append("**Identical to input:** yes — PASSTHROUGH (CLI returned non-zero or empty; check OSLog)\n\n")
            } else {
                markdown.append("**Output length:** \(output.count) chars (input was \(Self.representativeInput.count))\n\n")
            }
            markdown.append("**Output:**\n\n```\n\(output)\n```\n\n")
            markdown.append("---\n\n")
        }

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Eval output: \(outputURL.path)")
    }

    // A compact, realistic assistant message that exercises everything
    // TTS-hostile in one input: heading, table, code block with
    // identifiers, URL, absolute file path, bullet list, numbered
    // list, inline code + filename-with-extension references. If a
    // model handles this well across the board, narrower real inputs
    // should be fine.
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

    // MARK: - IO helpers

    private func resolveOutputURL(name: String = "cli-eval") throws -> URL {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let outputDir = repoRoot.appendingPathComponent("eval-output", isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return outputDir.appendingPathComponent("\(name)-\(timestamp).md", isDirectory: false)
    }

    private func formatDuration(_ duration: Duration) -> String {
        let millis = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0f ms", millis)
    }
}
