# TODOs and Known Bugs

This is a lightweight holding pen for non-urgent issues that are real enough to remember but not worth derailing active work.

## Known Bugs

- Toolbar chrome can remain transparent after hiding and showing the sidebar.
  - Repro: select a session, hide the sidebar from the toolbar, then show it again.
  - Expected: reopened sidebar state restores the original unified toolbar material and separator.
  - Observed: the titlebar/toolbar can stay visually transparent and lose the separator until relaunch.
  - Status: parked. Prior experiments with toolbar background modifiers, scroll-edge tweaks, explicit column visibility, and a small AppKit chrome shim did not produce a satisfying fix.

## Later Ideas

- Revisit the sidebar toolbar issue only if it becomes more noticeable or if a broader AppKit/window-chrome pass happens anyway.

- **Re-enable markdown rendering in `TranscriptMarkdownView`.**
  - Context: currently renders `Text(verbatim: content.text)` for all messages. Markdown rendering was disabled during a perf investigation when transcripts were unbounded and LazyVStack re-materialized cells on scroll, both of which made eager markdown parsing a hot path. Both conditions are gone: the 50-message cap (`TranscriptDisplayLimits`) bounds the worst case to ~50 cells, and we're on eager VStack so cells render once at mount with no on-scroll re-parse.
  - Plumbing already in place: `TranscriptMessage.Content` (Sources/Models/TranscriptMessage.swift) classifies each message at parse time into `.literal` / `.plainText` / `.markdown` with a heuristic detector that handles Claude's XML-ish system prompts as `.literal` so they render verbatim. `TranscriptMarkdownView` already takes a `Content` value, not a raw string. The `Textual` dependency is declared in `Package.swift` but no source file imports it yet, kept ready for this restoration.
  - Spike: branch the `body` of `TranscriptMarkdownView` on `content`:
    - `.literal`, `.plainText` → current `Text(verbatim:)` path.
    - `.markdown` → either `Text(AttributedString(markdown: text))` (Apple built-in, basic styling) or a `Textual` view (richer: code blocks, tables, etc.). Try Textual first since the dep is already there for that reason.
  - Success criteria: long Claude/Codex sessions with code blocks and tables render markdown correctly without scroll stutter or visible per-cell parsing delay. Compare cold-load timing (`PerfLog` "Storage.loadTranscript" + initial render) before and after; eyeball scroll smoothness on a session with several code blocks.
  - If it works: ship it. The CLAUDE.md `TranscriptMarkdownView` load-bearing entry can simplify to "renders markdown via the `Content` classification" instead of warning against re-enabling.
  - If it doesn't (visible regression): revert is just deleting the `.markdown` case branch — no plumbing to undo.
  - Estimated time: 20-30 min including manual testing on a heavy session.

- **Local TTS backend (researched 2026-06-11; see commit history for the time-stretch groundwork).**
  - Best current option: Qwen3-TTS (Apache 2.0, Jan 2026) — 0.6B/1.7B, voice design from text descriptions, 3 s cloning, streaming. MLX numbers on M4-class: 1.7B ≈ 1.6× realtime generation, ~60 ms TTFB, 3.5 GB resident (4-bit); 0.6B ≈ 2× faster at ~2 GB. Kokoro-82M remains the speed floor (~350 MB, flatter prosody). At 400 wpm playback (2.35×), the 0.6B comfortably outruns consumption; the 1.7B relies on buffer-ahead.
  - Integration paths: (a) `mlx-audio` Python sidecar (MIT, 7k+ stars, active; HTTP server; also serves Kokoro/MOSS for ear-testing) — recommended first; (b) `swift-qwen3-tts` SwiftPM package (native MLX Swift, streaming API that feeds straight into `StreamingAudioPlayer`) — blocked on the repo having NO license file as of 2026-06; ask the author or port from mlx-audio ourselves before shipping anything.
  - Architecture: third `SpeechBackend` case + driver conforming to `SpeechBackendDriver`, lazy model load (~2-4 GB resident only while backend active), voice list = built-in speakers + saved voice designs.
  - First step when picked up: ear-test Qwen3-0.6B vs 1.7B vs Kokoro via the mlx-audio server before writing any Swift.

- **Replace `TranscriptDetailView`'s queued bottom-pin with a `.scrollPosition(id:anchor:)` + bottom-sentinel approach.**
  - Context: the view currently scrolls to the latest message via a generation-counter `Task` that runs `proxy.scrollTo` three times (Task.yield + 20 ms + 120 ms) to catch row-height re-measurement after the parent layout claims to be done. Works reliably under Codex's computer-use testing but the magic-number delays are ugly.
  - Spike: add a `Color.clear.frame(height: 1).id("bottom")` sentinel at the end of the VStack, bind `@State var scrollAnchorID: String? = "bottom"` via `.scrollPosition(id: $scrollAnchorID, anchor: .bottom)`, drive auto-pin off the same `userSetAtBottom` gate. The `.scrollPosition` binding-based API was previously avoided because it was broken with LazyVStack — now that we're on eager VStack (commit `fc89db9`, after the 50-message cap), it's worth retrying.
  - Success criteria: the sentinel approach reliably lands at the latest message on cold-load click, warm-load click, and across cross-source switches (Claude → Codex and back). Same correctness as the current shim with materially less code.
  - If it works: delete `bottomPinGeneration` / `bottomPinTargetID` state, `requestBottomPin` / `scrollToBottomIfStillPinned` helpers, the `.task(id:)` with three passes, and the magic-number delays. Net ~5 lines instead of ~30. CLAUDE.md scroll-to-bottom entry shrinks back to a paragraph.
  - If it doesn't: revert. The current pragmatic shim works.
  - Estimated time: 30 min focused work + manual testing across the cases above.
  - Source bug: SwiftUI lacks a working "stick to bottom while content settles" primitive on macOS — Apple Developer Forums thread 741406, open since 2023. Both alternatives ultimately work around the same gap; this spike just bets on `.scrollPosition` being a cleaner work-around than the timing shim.
