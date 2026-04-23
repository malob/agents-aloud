import Foundation
import FoundationModels
import OSLog

// Uses Apple's on-device Foundation Models framework to rewrite
// visually-structured assistant output (code blocks, tables, URLs,
// bullet lists) into speech-friendly prose. Falls back to the input
// text unchanged on any failure (model unavailable, context overflow,
// guardrails refusal, transient error) so callers always get a usable
// string.
//
// Strategy:
// - Singleton-ish LanguageModelSession per processor instance, primed
//   with the same Instructions on every call. The session is a single
//   context window; we reset it between calls so token usage doesn't
//   accumulate.
// - Synchronous availability check before the first call. If
//   .available is false, log once and permanently passthrough for the
//   lifetime of this processor instance.
// - Length pre-check: skip messages longer than maxInputChars to leave
//   output room within the 4096-token context window.
// - Short-circuit trivial input (empty, whitespace-only, or clearly-
//   prose without any structural markers we'd want to rewrite) to
//   avoid the 1-3s model call cost on content it would return verbatim.
@MainActor
final class FoundationModelSpeechProcessor: SpeechTextProcessor {
    // Roughly: the 4096-token context window holds instructions
    // (~200 tokens) + input + output. Keep input under ~2000 chars
    // (~500 tokens) so there's room for up to ~3000 tokens of output,
    // which comfortably covers rewrites of dense structures.
    private static let maxInputChars = 2000

    private static let logger = Logger(subsystem: "local.claudecodevoice", category: "SpeechTextProcessor")

    // Apple's Foundation Models doesn't expose a tokenizer, so we
    // estimate. Characters → tokens ratio is 3-4 for English.

    // Instructions: the system-prompt-equivalent steering the model
    // toward "refine, don't summarize."
    static let instructions = """
    You adapt text from a coding assistant for text-to-speech playback. \
    Your job is to make structure-heavy content listenable without \
    changing what it says.

    Rules:
    - Preserve all information. Do NOT summarize or omit detail.
    - Code blocks: describe in natural English at the same level of \
      detail, preserving symbol names. For example, "The function \
      fetchUser takes a user ID, calls the API client, and returns a User."
    - Tables: read as bullet-style prose. For example, "The benchmarks \
      column shows Sonnet 4.6 at 82 percent and Haiku 4.5 at 74 percent."
    - URLs and file paths: say "a link" or "the file" instead of \
      reading character-by-character.
    - Bullet lists: read with transitions like "First... Then... Finally."
    - If the input is already prose with no code, tables, URLs, or \
      dense symbols, return it UNCHANGED.
    - Never add commentary, opinions, or content not in the input.
    - Do not wrap your response in quotes or any framing — return \
      just the adapted text.
    """

    // Fast filter: if the text has no visual structures, skip the model
    // call entirely. Saves the 1-3s round-trip on plain-prose messages.
    private static let structuralMarkers: [Character] = ["`", "|", "#", "*", "_", "[", "]", "(", ")", "{", "}", "<", ">", "\\"]

    // Cache `.available` once we see it (stable — model doesn't become
    // un-downloaded mid-session) but re-check anything else every call.
    // That way if the user turns on Apple Intelligence, finishes the
    // model download, or the device becomes eligible while the app is
    // open, the processor starts working without needing a toggle-off /
    // toggle-on dance.
    private var knownAvailable = false
    private var session: LanguageModelSession?

    init() {}

    // Returns true iff the on-device model is currently available.
    // Property reads on SystemLanguageModel.default are cheap — the
    // re-check on unavailable doesn't meaningfully impact hot-path cost.
    private func checkAvailable() -> Bool {
        if knownAvailable {
            return true
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            knownAvailable = true
            Self.logger.info("FoundationModel available; speech processor active")
            return true
        case .unavailable(let reason):
            Self.logger.debug(
                "FoundationModel unavailable (\(String(describing: reason), privacy: .public)); passthrough"
            )
            return false
        }
    }

    // Pre-warm so the first real call doesn't pay cold-start cost. Safe
    // to call when unavailable (no-ops).
    func prewarm() {
        guard checkAvailable() else { return }
        ensureSession().prewarm()
    }

    private func ensureSession() -> LanguageModelSession {
        if let session {
            return session
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        self.session = session
        return session
    }

    // Reset the session so each message starts with a clean context
    // window. Called after each respond() so context-window usage
    // doesn't accumulate across messages.
    private func resetSession() {
        session = nil
    }

    func process(text: String) async -> String {
        // Short-circuits (no model call needed):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard text.count <= Self.maxInputChars else {
            Self.logger.debug("Skipping FM refinement: input too long (\(text.count, privacy: .public) chars)")
            return text
        }
        guard Self.containsStructuralMarkers(trimmed) else {
            // Plain prose — the model would return it unchanged anyway.
            return text
        }
        guard checkAvailable() else { return text }

        // Real call.
        let session = ensureSession()
        do {
            let response = try await session.respond(to: text)
            resetSession()
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? text : output
        } catch {
            // All error paths fall back to the input. Log at debug so
            // Console doesn't fill up from transient failures, but stays
            // queryable when diagnosing odd behavior.
            Self.logger.debug(
                "FoundationModel respond failed; passthrough: \(error.localizedDescription, privacy: .public)"
            )
            resetSession()
            return text
        }
    }

    private static func containsStructuralMarkers(_ text: String) -> Bool {
        for character in text {
            if structuralMarkers.contains(character) {
                return true
            }
        }
        return false
    }
}
