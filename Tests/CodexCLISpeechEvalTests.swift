import Foundation
import Testing
@testable import AgentsAloud

// Eval harness for the Codex CLI speech rewriter. Two tests:
//
//  1. `smokeSingleInvocation` — one call at gpt-5.4-mini / low / low /
//     fast=true. Validates the wiring end-to-end before committing to
//     the full matrix; prints latency and output.
//
//  2. `emitMatrixComparisonEval` — full 4-D sweep:
//        models   = gpt-5.4-mini, gpt-5.5, gpt-5.3-codex-spark
//        effort   = low, medium, high
//        verbosity = low, medium, high
//        fast     = on, off
//     = 54 invocations, written to a markdown file with summary table
//     + full outputs grouped by model. Sequential to keep latency
//     numbers honest.
//
// Both tests are env-gated (ENABLE_SPEECH_EVAL=1) and require the user
// to be authenticated via `codex login`.
//
// Run smoke only:
//   ENABLE_SPEECH_EVAL=1 swift test --filter CodexCLISpeechEvalTests/smokeSingleInvocation
//
// Run matrix:
//   ENABLE_SPEECH_EVAL=1 swift test --filter CodexCLISpeechEvalTests/emitMatrixComparisonEval
//
// Output: `eval-output/codex-eval-*.md`.
struct CodexCLISpeechEvalTests {
    private static var isEvalEnabled: Bool {
        ProcessInfo.processInfo.environment["ENABLE_SPEECH_EVAL"] == "1"
    }

    @Test(.enabled(if: isEvalEnabled))
    func smokeSingleInvocation() async throws {
        guard CodexCLISpeechProcessor.isAvailable else {
            Issue.record("codex CLI not found on PATH")
            return
        }

        let processor = CodexCLISpeechProcessor(
            model: "gpt-5.4-mini",
            effort: "low",
            verbosity: "low",
            useFastTier: true
        )
        let start = ContinuousClock.now
        let output = await processor.process(text: Self.representativeInput)
        let elapsed = ContinuousClock.now - start

        let identicalToInput = output == Self.representativeInput
        print("Codex smoke test: \(formatDuration(elapsed))")
        print("Identical to input: \(identicalToInput)")
        print("Output length: \(output.count)")
        print("Output:\n\(output)")

        // No assertion on quality — just that something other than
        // passthrough came back. If the CLI is misconfigured the
        // output equals the input (passthrough fallback).
        #expect(!identicalToInput, "Codex returned passthrough — check OSLog for the failure reason")
    }

    @Test(.enabled(if: isEvalEnabled))
    func emitMatrixComparisonEval() async throws {
        guard CodexCLISpeechProcessor.isAvailable else {
            Issue.record("codex CLI not found on PATH")
            return
        }

        let outputURL = try resolveOutputURL(name: "codex-eval-matrix")
        var markdown = "# Codex CLI Speech Rewriter — 4-D Matrix Sweep\n\n"
        markdown.append("Run at: \(Date().formatted())\n\n")
        markdown.append("Same representative input rewritten across the full Cartesian product of:\n")
        markdown.append("- **Models:** gpt-5.4-mini, gpt-5.5, gpt-5.3-codex-spark\n")
        markdown.append("- **Effort:** low, medium, high (`model_reasoning_effort`)\n")
        markdown.append("- **Verbosity:** low, medium, high (`model_verbosity`)\n")
        markdown.append("- **Service tier:** with `fast`, without (default flex tier)\n\n")
        markdown.append("Total: 54 combinations, sequential (no concurrent API queueing).\n\n")
        markdown.append("---\n\n## Input\n\n```\n\(Self.representativeInput)\n```\n\n")
        markdown.append("Character count: \(Self.representativeInput.count)\n\n---\n\n")

        // Run the full matrix, keeping a flat result list. Group/render
        // afterward.
        struct Result {
            let model: String
            let effort: String
            let verbosity: String
            let fast: Bool
            let latencyMs: Double
            let output: String
            let identicalToInput: Bool
        }
        var results: [Result] = []

        let models = ["gpt-5.4-mini", "gpt-5.5", "gpt-5.3-codex-spark"]
        let efforts = ["low", "medium", "high"]
        let verbosities = ["low", "medium", "high"]
        let fastOptions = [true, false]

        for model in models {
            for fast in fastOptions {
                for effort in efforts {
                    for verbosity in verbosities {
                        let processor = CodexCLISpeechProcessor(
                            model: model,
                            effort: effort,
                            verbosity: verbosity,
                            useFastTier: fast
                        )
                        let start = ContinuousClock.now
                        let output = await processor.process(text: Self.representativeInput)
                        let elapsed = ContinuousClock.now - start

                        let latencyMs = Self.durationMs(elapsed)
                        let identical = output == Self.representativeInput
                        results.append(Result(
                            model: model,
                            effort: effort,
                            verbosity: verbosity,
                            fast: fast,
                            latencyMs: latencyMs,
                            output: output,
                            identicalToInput: identical
                        ))
                        print("[\(results.count)/54] \(model) effort=\(effort) verbosity=\(verbosity) fast=\(fast): \(Int(latencyMs))ms")
                    }
                }
            }
        }

        // Summary table at the top — easiest read for picking defaults.
        markdown.append("## Summary\n\n")
        markdown.append("| Model | Effort | Verbosity | Fast | Latency | Output Chars | Notes |\n")
        markdown.append("|-------|--------|-----------|------|---------|--------------|-------|\n")
        for result in results {
            let latency = "\(Int(result.latencyMs))ms"
            let chars = result.identicalToInput ? "—" : "\(result.output.count)"
            let notes = result.identicalToInput ? "PASSTHROUGH" : ""
            markdown.append("| \(result.model) | \(result.effort) | \(result.verbosity) | \(result.fast ? "yes" : "no") | \(latency) | \(chars) | \(notes) |\n")
        }
        markdown.append("\n---\n\n")

        // Full outputs grouped by model so per-model quality patterns
        // are easy to skim.
        for model in models {
            markdown.append("## Model: \(model)\n\n")
            for result in results where result.model == model {
                markdown.append("### effort=\(result.effort), verbosity=\(result.verbosity), fast=\(result.fast ? "yes" : "no")\n\n")
                markdown.append("**Latency:** \(Int(result.latencyMs))ms\n\n")
                if result.identicalToInput {
                    markdown.append("**PASSTHROUGH** — CLI returned non-zero or empty; check OSLog\n\n")
                } else {
                    markdown.append("**Output length:** \(result.output.count) chars\n\n")
                    markdown.append("```\n\(result.output)\n```\n\n")
                }
                markdown.append("---\n\n")
            }
        }

        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Eval output: \(outputURL.path)")
    }

    // Same representative input as ClaudeCLISpeechEvalTests so the two
    // markdowns are directly comparable.
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

    private func resolveOutputURL(name: String) throws -> URL {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let outputDir = repoRoot.appendingPathComponent("eval-output", isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return outputDir.appendingPathComponent("\(name)-\(timestamp).md", isDirectory: false)
    }

    private func formatDuration(_ duration: Duration) -> String {
        return String(format: "%.0f ms", Self.durationMs(duration))
    }

    private static func durationMs(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
