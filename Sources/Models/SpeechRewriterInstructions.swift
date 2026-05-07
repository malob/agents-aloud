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
//  - Without the identifier-splitting line, the macOS `say` engine
//    spells long camelCase / snake_case identifiers letter by
//    letter. Short ones (e.g. `userId`) usually read fine, but
//    `processedTranscriptMessageBuffer`-class names get spelled
//    one character at a time. Splitting on case/underscore
//    boundaries keeps the words intact while giving `say` natural
//    word breaks.
//  - Without the angle-bracket strip, the macOS `say` engine
//    frequently truncates mid-sentence when it encounters `<` or
//    `>` — most common around HTML/XML tags or generic type
//    parameters. ElevenLabs handles them fine, but stripping
//    costs nothing there and avoids the macOS regression.
//  - Without the voice-preservation preamble, the rewriter (itself
//    another LLM instance) defaults to translator/summary mode:
//    paraphrasing the reply or shifting it into third-person ("the
//    assistant said…", "the response covers…"). Symptom is subtle
//    in writing but jarring in audio. The preamble names the input
//    as another AI's first-person reply and the task as medium
//    translation, not content paraphrase. Paired with swapping
//    "Describe code" → "Read code" so no body rule pulls back
//    toward outside-observer voice.
//
// Keep all the rules. They add ~1000 chars to the prompt and the
// latency impact is within API-side noise.
enum SpeechRewriterInstructions {
    static let defaultText = """
    The input is another AI model's reply to a user. Your task is to \
    translate that reply from its written form — markdown, code \
    blocks, structured formatting — into spoken English that a \
    text-to-speech engine can read aloud naturally. You are \
    translating the medium, not the message: the same speaker, the \
    same voice, the same content, just spoken instead of written. \
    Don't summarize, paraphrase, narrate, or describe the reply from \
    outside.

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

    NEVER include angle brackets (`<` or `>`) in the output. They \
    serve no purpose in spoken text and some text-to-speech engines \
    truncate or stall when they encounter them. Rephrase comparisons \
    in plain English ("x < y" → "x less than y"); for tag-like \
    content (HTML, XML, generic type parameters) drop the brackets \
    and read the inner content directly: "<task-notification>" \
    becomes "task notification," "Array<String>" becomes "array of \
    strings."

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

    Read code in natural English, preserving every identifier \
    exactly as named. For multi-word identifiers in any case style — \
    camelCase, snake_case, PascalCase, kebab-case — split on word \
    boundaries with spaces so the words read naturally: \
    `processedTranscriptMessageBuffer` becomes "processed transcript \
    message buffer," `MAX_RETRY_COUNT` becomes "max retry count," \
    `user-id-token` becomes "user id token." Single-word identifiers \
    stay as-is. Some text-to-speech engines spell long unsplit \
    identifiers letter by letter; the splitting keeps the named \
    entity intact for the listener.

    Preserve every piece of information — do not summarize or drop \
    detail. Do not add preamble, commentary, or framing. Return only \
    the rewritten text.
    """
}
