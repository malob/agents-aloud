import Foundation

// Pre-processes a message's text before it reaches a TTS backend. The
// intended use is to rewrite visual structures (code blocks, tables,
// URLs, bullet lists, dense markdown) into listenable prose WITHOUT
// summarizing or altering the underlying information.
//
// `process` never throws — implementations are responsible for their
// own error handling and must fall back to returning the input text
// unchanged on any failure (availability, context overflow, refusal,
// transient errors). Callers should treat the result as a drop-in
// replacement for the input.
protocol SpeechTextProcessor: Sendable {
    func process(text: String) async -> String
}

// Identity processor: returns input unchanged. The default until the
// user opts into AI-driven refinement, and the fallback when a real
// processor isn't available on this device.
struct PassthroughSpeechProcessor: SpeechTextProcessor {
    func process(text: String) async -> String {
        text
    }
}
