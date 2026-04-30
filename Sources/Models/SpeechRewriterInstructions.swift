import Foundation

// Shared system prompt for the CLI speech rewriter, used by both
// ClaudeCLISpeechProcessor and CodexCLISpeechProcessor. The rules
// are about TTS output shape, not about which CLI delivers them,
// so the same instructions produce equivalent rewrites regardless
// of backend. Centralising here removes the trap of editing one
// processor and forgetting to mirror to the other.
//
// Forward extensibility: each processor takes `instructions: String`
// as an init parameter that defaults to `defaultText` here. A
// future settings UI (user-edited prompt, per-backend overrides)
// passes a non-default value through that injection point without
// touching the processors. Plumbing for "settings → rewriter prompt"
// stops at this constant.
//
// Several rules in the prompt are load-bearing — keeping them in
// one place so the rationale stays paired with the text:
//
//  - Without the URL/path-spelling line, the model (Haiku and
//    Sonnet both) dot-slash-spells URLs and paths letter by letter.
//  - Without the dot-extension line, the model leaves bare
//    filenames like `AppConfig.swift` intact — TTS then reads
//    them as "AppConfig dot swift." Caught this in a 4-run
//    benchmark: 3/4 runs leaked filename-with-extension.
//  - Without the verbatim-passage rule, the model paraphrases
//    drafts of messages, proposed phrasings, and quoted text
//    whose specific wording IS the content — e.g. "the assistant
//    suggested writing to Alexander about scheduling" in place
//    of the actual proposed text. Phrased as a judgment call
//    keyed on "would paraphrasing lose information that's in the
//    wording itself?", which covers blockquotes, inline quotes,
//    and labelled drafts — not just the markdown `>` shape —
//    without making the rewriter model what a listener wants
//    (a level of abstraction past the actual decision).
//
// Keep all three rules. They add ~500 chars to the prompt and the
// latency impact is within API-side noise.
enum SpeechRewriterInstructions {
    static let defaultText = """
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

    Some passages must be preserved verbatim because the words \
    themselves are the content — drafts of messages, proposed \
    phrasings, exact quotes, anything where the specific wording is \
    part of the information, not just a vehicle for the meaning. \
    Markdown blockquotes (lines prefixed with `>`) are the clearest \
    signal; inline quotes ("he said: …") and labelled drafts \
    ("Draft:", "Proposed:") qualify too. Use judgment: would \
    paraphrasing this passage lose information that's in the wording \
    itself? If yes, preserve it verbatim; if no, rewrite freely. \
    Inside a verbatim passage: no paraphrasing or substitution, \
    though markdown markers still get stripped per the rule above. \
    A short lead-in like "the draft reads:" is fine before a \
    verbatim section.

    Describe code in natural English, preserving every identifier name \
    exactly as written.

    Preserve every piece of information — do not summarize or drop \
    detail. Do not add preamble, commentary, or framing. Return only \
    the rewritten text.
    """
}
