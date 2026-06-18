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

- **"Listening stream" roadmap — steering playback across multiple sessions.** The
  queue is already cross-session (every `PendingSpeechItem` carries `sessionID`); these
  build on that to make the app a multi-source stream you steer rather than a
  one-conversation reader. Sequenced so each step ships independently:
  - **A2 — cross-session attribution cue. DONE (2026-06-18).** SpeechController prepends
    "From <session>." when the next item's session differs from the last spoken one.
    Zero-noise single-session (no cue on stream start, within a session, or after stop()).
    Ear-test pending: tune wording / label source / whether to announce the first
    utterance. See `attributedText` in SpeechController + `attributionLabel` in AppModel.
  - **A1 — multi-session Live Speak. DONE (2026-06-18), ear-test pending.** Live Speak
    is now non-exclusive: `liveReadSessionIDs: Set<ID>`; sidebar icon + toolbar toggle
    use `.contains`; enabling is additive (no transfer). The single live-read watcher
    became a per-session pool via `liveReadWatcherFactory`, with per-session debounce
    tasks so two chatty sessions can't cancel each other's refresh. Cold-start
    attribution edge handled: `shouldAttributeFirstUtteranceProvider` attributes the
    first utterance only when >1 session is live. No new UI. Shipped alone (B deferred
    until the amplified interruption is shown to actually bite).
  - **B — Hold / interruption gate.** Explicit Hold where `.auto` items still enqueue
    but don't auto-promote; manual still plays; a "N waiting" badge; flush on Resume.
    Optional opt-in: a manual Speak auto-engages Hold. Reframed away from the
    window-focus idea (fiddly + surprising) toward an explicit, predictable gate.
  - **C — control without leaving the terminal.** `MenuBarExtra` (`.window` style) with
    transport + the live queue + a unified reverse-chronological, session-tagged
    "pick-to-speak" list across all live sessions; global hotkeys for transport via
    Carbon `RegisterEventHotKey` (no Accessibility prompt, works over full-screen);
    optional floating non-activating `NSPanel` HUD as the ambitious follow-on.

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
