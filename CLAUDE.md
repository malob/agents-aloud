# Claude Code Voice — Project Context

macOS SwiftUI app that reads agent transcripts aloud. Surfaces a
unified sidebar of recent Claude Code (`~/.claude/projects/`) and
Codex (`~/.codex/sessions/`, indexed via `~/.codex/state_5.sqlite`)
sessions, renders the selected session as a chat-style transcript
view, and speaks assistant messages through one of two TTS backends
(macOS system `say`, or ElevenLabs streaming). An optional rewriter
step pre-processes message text via a CLI before TTS so spoken output
strips code blocks, formats prose, and shortens preambles.

## Architecture at a glance

```
Sources/
├── App/                  @main + scene + command menu
├── Models/               Immutable domain types (enums, DTOs)
│   ├── SessionsState           .loading / .loaded / .failed carrying last-known payload
│   ├── TranscriptState         same pattern for one session's transcript
│   ├── PlaybackState           (inside SpeechController) idle/speaking/paused + queue
│   ├── TranscriptSource        .claude / .codex — source-of-truth for source-aware UI
│   ├── TranscriptDisplayLimits the 50-message rolling-window cap
│   └── ...
├── Services/             I/O and actors
│   ├── ClaudeStorageService      actor; walks ~/.claude/projects/, parses JSONL, mtime/size-cached
│   ├── ClaudeTranscriptParser    nonisolated; Claude JSONL → TranscriptMessage[]
│   ├── CodexStorageService       actor; reads ~/.codex/sessions/, mtime-cached
│   ├── CodexThreadDatabase       SQLite reader over ~/.codex/state_5.sqlite (session index)
│   ├── CodexTranscriptParser     nonisolated; Codex rollout JSONL → TranscriptMessage[]
│   ├── TranscriptFileWatcher     DispatchSource on the selected file + retry on ENOENT
│   ├── SpeechController          @Observable; queue + routing across drivers
│   ├── SpeechBackendDriver       protocol + SystemVoice / ElevenLabs impls
│   ├── StreamingAudioPlayer      AVAudioEngine wrapper for ElevenLabs PCM streams
│   ├── ElevenLabsClient          URLSession TTS client
│   ├── ClaudeCLISpeechProcessor  optional rewriter via `claude --print`
│   ├── CodexCLISpeechProcessor   optional rewriter via `codex exec`
│   └── NowPlayingCoordinator     MPNowPlayingInfoCenter + media-key bridge
├── Stores/
│   └── AppModel          @MainActor @Observable; top-level coordinator
├── Views/                SwiftUI; one file per screen + SourceBrandIcon helper
└── Support/              KeychainStorage, PerfLog, TranscriptTailReader, small extensions
```

## Load-bearing decisions (don't re-derive these)

- **`swift build`-based adhoc signing prompts the Keychain on every
  rebuild.** The fix: `build_and_run.sh` auto-signs with the user's
  Apple Development identity so the designated requirement is stable.
  Don't "simplify" back to adhoc.
  See: [script/build_and_run.sh](script/build_and_run.sh),
  [Sources/Support/KeychainStorage.swift](Sources/Support/KeychainStorage.swift)

- **`AppModelTests` passes a UUID-scoped Keychain service** so
  `swift test` doesn't prompt the user for the real app's stored API
  key. Don't let AppModel default to the production service name
  inside tests.

- **Cold-start session load is deliberately sequential**, not
  parallelized with `withThrowingTaskGroup`. An earlier parallel
  version regressed wall time 2–4× due to Foundation / allocator
  contention under concurrent JSON parsing. The per-session summarize
  is mostly CPU-bound and Apple's allocator serializes anyway.
  See: [ClaudeStorageService.swift](Sources/Services/ClaudeStorageService.swift)
  top-of-file comment.

- **Codex sessions are indexed via SQLite, not by walking the JSONL
  filesystem.** `~/.codex/state_5.sqlite`'s `threads` table is the
  authoritative session list; we open it read-only with the
  `?mode=ro&immutable=1` URI form because plain read-only opens
  intermittently fail with `SQLITE_CANTOPEN` while Codex's writers
  hold WAL/SHM file locks. Walking `~/.codex/sessions/` directly was
  the v0 implementation but it doesn't have project metadata, custom
  titles, or archive state — the SQLite version is required for
  parity with what `codex` itself shows.
  See: [CodexThreadDatabase.swift](Sources/Services/CodexThreadDatabase.swift),
  [CodexStorageService.swift](Sources/Services/CodexStorageService.swift)

- **Claude has no authoritative session index** — the JSONL filesystem
  IS the source of truth. We've checked: Anthropic GitHub issues
  #9898, #29150, #14124 confirm there's no equivalent of Codex's
  `state_5.sqlite`. Don't go looking for one.

- **Transcript tail-signature check before incremental parse.** Claude
  Code writes JSONL append-only but rewind / edit / session-fork can
  rewrite the prefix. Comparing the last ~128 cached bytes against
  what's now on disk guards the fast path; mismatch → full reparse.

- **Transcripts hold a 50-message rolling window, never the full JSONL.**
  Cold loads tail-read in widening chunks (256 KB initial, doubles on
  miss) until they have 50 user/assistant messages — the whole file is
  never parsed regardless of session length. Claude's incremental-
  append fast path trims the merged list back to the cap on each
  append; Codex doesn't have an incremental path but caches by mtime
  so re-clicks are sub-ms. There is intentionally no "load earlier"
  affordance — the app's job is reading current messages aloud, not
  historical scrollback. Don't lift the cap "because we have the
  bytes" without re-running the cold-load timing on a long session.
  See: [Sources/Models/TranscriptDisplayLimits.swift](Sources/Models/TranscriptDisplayLimits.swift),
  [Sources/Support/TranscriptTailReader.swift](Sources/Support/TranscriptTailReader.swift)

- **The "Loading transcript…" overlay is gated on
  `transcriptMessages.isEmpty`, not just `isLoadingTranscript`.**
  `TranscriptState.loading` carries prior messages through
  deliberately so the screen doesn't flash empty during watcher
  ticks; the ForEach above the overlay is already re-rendering them.
  An unconditional spinner used to flash over already-visible content
  on every refresh — perceptible especially on Codex sessions where
  the parse cost is non-trivial (5-20 lines per visible message). The
  cold-load case still works because `transcriptMessages` is empty
  until the await completes.
  See: [Sources/Views/TranscriptDetailView.swift](Sources/Views/TranscriptDetailView.swift)

- **Custom multicolor `.symbolset` assets cannot be rendered through
  SwiftUI Picker bridges on macOS.** Both `.pickerStyle(.segmented)`
  and `.pickerStyle(.palette)` route through AppKit, which template-
  tints the image, flattens the multicolor palette to a single fill,
  and re-interprets path winding (the Codex hex outline renders
  filled, not hollow). The sidebar source filter is a hand-rolled
  HStack of plain Buttons specifically because of this. Don't
  re-spike to a Picker without a fresh OS-level test confirming
  the bridge has been fixed.
  See: [Sources/Views/SidebarView.swift](Sources/Views/SidebarView.swift)

- **SwiftPM doesn't run `actool`; `build_and_run.sh` does.** The
  `.process("Resources")` declaration in `Package.swift` ships the
  `.xcassets` source files into the SPM-emitted resource bundle but
  never compiles them. The staged-app build wrapper invokes
  `xcrun actool` against the resource bundle to produce `Assets.car`.
  Stripping that step ships an app that can't find its custom SF
  Symbols at runtime — the symbolset PNGs are there, but
  `Image("claude", bundle: …)` returns nil because there's no
  compiled catalog to look them up in.
  See: [script/build_and_run.sh](script/build_and_run.sh)

- **`URL.resourceValues` is cached on the URL instance.** After the
  `ClaudeSessionSummary.transcriptURL: URL` refactor we had to add
  `removeAllCachedResourceValues()` before re-reading mtime/fileSize,
  or the incremental-tail path sees stale values and skips newly-
  appended content. The existing test
  `loadTranscriptIncorporatesAppendedJSONLLines` will catch regressions.

- **Scroll-to-bottom:** `.defaultScrollAnchor(.bottom)` on the
  ScrollView lands correctly at initial load for sessions with
  wildly-variable message heights (the old manual `proxy.scrollTo`
  path landed mid-content because LazyVStack reports
  sum-of-estimated-heights, not actuals). Paired with manual
  machinery — `onScrollGeometryChange` + `userSetAtBottom` gate — for
  new-message auto-pin that respects "user scrolled up, don't yank."
  Both mechanisms are needed; removing either breaks a different
  case. See [TranscriptDetailView.swift](Sources/Views/TranscriptDetailView.swift)
  header comment.

- **`TranscriptMarkdownView` renders `Text(verbatim:)` deliberately.**
  Markdown rendering was disabled during a perf investigation;
  `TranscriptMessage.Content` classification + the `Textual`
  dependency are kept wired so restoring it is a matter of branching
  on `content`. Don't "fix" the verbatim render without re-running
  the perf check.

- **ElevenLabs output format is `pcm_24000`, not `pcm_44100`.**
  44.1kHz PCM is gated behind Pro+ tiers; 24kHz is available on
  Free/Starter/Creator and is more than sufficient for speech
  (Nyquist at 12kHz has plenty of headroom for a human voice topping
  out ~8kHz).

- **ElevenLabs `voice_settings.speed` accepts only 0.7–1.2.** Our
  WPM slider (100–500 wpm) is mapped linearly into that range by
  `ElevenLabsBackendDriver.mapRateToSpeed`. Anything outside returns
  400. ElevenLabs caps at 1.2× — meaningfully slower than what
  SystemVoice can do at the top of the slider — so the same WPM
  position is the same UI control across backends but not audibly
  identical playback.

- **Apple Dev signing also enables stable Keychain ACLs** — re-entering
  the API key once after switching from adhoc to Apple Dev is
  expected; future rebuilds don't prompt.

## Tooling / workflow

- **Build + run:** `./script/build_and_run.sh` wraps `swift build`,
  stages SPM resource bundles into the `.app`, runs `xcrun actool`
  on the asset catalog, and codesigns. Accepts `run` (default),
  `--debug`, `--logs`, `--telemetry`, `--verify`.
- **Tests:** `swift test`. `waitUntil` (in `Tests/TestHelpers.swift`)
  beats fixed `Task.sleep` for "wait for an async side effect"
  scenarios. Test targets are scoped per service / driver / store;
  add new tests next to the closest existing suite.
- **OSLog:** subsystem is `local.claudecodevoice`; one category per
  service (`Storage`, `CodexStorage`, `TranscriptParser`,
  `CodexTranscriptParser`, `Speech`, `ElevenLabsDriver`,
  `StreamingAudioPlayer`, `AppModel`, `Perf`, …). Stream with
  `log stream --info --style compact --predicate 'subsystem == "local.claudecodevoice"'`,
  scope further with `&& category == "X"` as needed.

## Style

- Swift 6 strict concurrency. Lean on `@MainActor @Observable` for
  app-level state; use `actor` for I/O services; mark helper
  formatters `nonisolated` when they touch no actor state.
- Prefer `@Bindable var model` in SwiftUI views that need bindings
  over hand-rolled `Binding(get:set:)`.
- Comments: WHY, not WHAT. Default is no comment; only add one when
  the non-obvious constraint or past-incident context can't be read
  off the code itself.
- No emojis in code or docs unless explicitly requested.
- No inline `?:` chains more than one level deep — break into a
  computed property or `switch`.

## Where the review backlog lives

`/Users/malo/.claude/plans/inherited-wondering-gizmo.md` has the full
agent-surfaced review. Completed items reference commit IDs; the
deferred items are the 5s poll → FSEvents refactor and the
`SessionSelection` enum fusion — both substantive refactors whose
benefit didn't justify the scope at the time.
