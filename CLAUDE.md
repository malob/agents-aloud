# Claude Code Voice — Project Context

macOS SwiftUI app that reads Claude Code transcripts aloud. It watches
`~/.claude/projects/` for session JSONL files, renders a sidebar of
recent sessions + a chat-style transcript view, and speaks assistant
messages through one of three TTS backends (AVSpeech, macOS system
`say`, or ElevenLabs streaming).

## Architecture at a glance

```
Sources/
├── App/                  @main + scene + command menu
├── Models/               Immutable domain types (enums, DTOs)
│   ├── SessionsState     .loading / .loaded / .failed carrying last-known payload
│   ├── TranscriptState   same pattern for one session's transcript
│   ├── PlaybackState     (inside SpeechController) idle/speaking/paused + queue
│   └── ...
├── Services/             I/O and actors
│   ├── ClaudeStorageService   actor; enumerates JSONL, caches parsed transcripts
│   ├── ClaudeTranscriptParser nonisolated; JSONL → TranscriptMessage[]
│   ├── TranscriptFileWatcher  DispatchSource + retry on ENOENT
│   ├── SpeechController       @Observable; routes across drivers
│   ├── SpeechBackendDriver    protocol + AVSpeech/SystemVoice/ElevenLabs impls
│   ├── StreamingAudioPlayer   AVAudioEngine wrapper for ElevenLabs PCM streams
│   └── ElevenLabsClient       URLSession TTS client
├── Stores/
│   └── AppModel          @MainActor @Observable; top-level coordinator
├── Views/                SwiftUI; one file per screen
└── Support/              KeychainStorage, PerfLog, small extensions
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

- **Transcript tail-signature check before incremental parse.** Claude
  Code writes JSONL append-only but rewind / edit / session-fork can
  rewrite the prefix. Comparing the last ~128 cached bytes against
  what's now on disk guards the fast path; mismatch → full reparse.

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
  0.2–0.6 AVSpeech-calibrated slider is mapped linearly into that
  range by `ElevenLabsBackendDriver.mapRateToSpeed`. Anything outside
  returns 400.

- **Apple Dev signing also enables stable Keychain ACLs** — re-entering
  the API key once after switching from adhoc to Apple Dev is
  expected; future rebuilds don't prompt.

## Tooling / workflow

- **Build + run:** `./script/build_and_run.sh` wraps `swift build` and
  codesigns the bundle. Accepts `run` (default), `--debug`, `--logs`,
  `--telemetry`, `--verify`.
- **Tests:** `swift test`. 62 tests across 11 suites as of this
  writing. `waitUntil` (in `Tests/TestHelpers.swift`) beats fixed
  `Task.sleep` for "wait for an async side effect" scenarios.
- **OSLog subsystem:** `local.claudecodevoice`. Categories include
  `Perf`, `Speech`, `Storage`, `TranscriptParser`, `ElevenLabsDriver`,
  `AppModel`. Stream with
  `log stream --info --style compact --predicate 'subsystem == "local.claudecodevoice"'`.

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
