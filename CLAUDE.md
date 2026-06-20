# Agents Aloud — Project Context

macOS SwiftUI app that reads agent transcripts aloud. Surfaces a
unified sidebar of recent Claude Code (`~/.claude/projects/`) and
Codex (`~/.codex/sessions/`, indexed via `~/.codex/sqlite/state_5.sqlite`)
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
│   ├── ClaudeSessionRegistry     reads ~/.claude/sessions/ (live CLI processes; sidebar source)
│   ├── ClaudeStorageService      actor; summarizes live sessions' JSONL (walk fallback), mtime/size-cached
│   ├── ClaudeTranscriptParser    nonisolated; Claude JSONL → TranscriptMessage[]
│   ├── CodexStorageService       actor; reads ~/.codex/sessions/, mtime-cached
│   ├── CodexThreadDatabase       SQLite reader over ~/.codex/sqlite/state_5.sqlite (session index; legacy ~/.codex/state_5.sqlite fallback)
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

- **Codex sessions are indexed via SQLite, snapshotted before every
  read.** The `threads` table is the authoritative session list;
  titles and archive state live ONLY there (the rollout JSONL has no
  title field), so we can't fall back to walking the filesystem for
  sidebar parity with `codex` itself. **The DB path is version-
  dependent and has moved BOTH ways**: Codex.app v149 relocated it from
  `~/.codex/state_5.sqlite` to `~/.codex/sqlite/state_5.sqlite` (2026-06),
  then a later release moved it BACK to `~/.codex/state_5.sqlite`
  (2026-06-19). Each move leaves the old file behind to go stale, so
  LOCATION is an unreliable signal. `CodexThreadDatabase.preferredDatabaseURL`
  therefore picks whichever candidate was **written most recently**
  (max mtime of the `.sqlite` and its `-wal`), NOT a fixed preferred
  path — an earlier "prefer the `sqlite/` subdir when present" heuristic
  silently froze the sidebar on a 5-day-stale DB after the move-back,
  since the stale subdir file still existed. If the Codex sidebar goes
  stale again after a Codex update, first confirm
  `preferredDatabaseURL` is resolving to the freshest file (the DB may
  have moved to a brand-new third location not in the candidate list).
  We can't read the live DB directly either — plain
  `SQLITE_OPEN_READONLY` fails with `SQLITE_CANTOPEN` because SQLite
  needs to write the -shm file for WAL lock coordination and Codex's
  writers hold those locks; `?mode=ro&immutable=1` succeeds but
  silently misses every write still in the -wal (observed: a 3.8 MB
  WAL containing hours of unflushed activity, causing renamed
  sessions to display the original first user prompt and stale
  updated_at to drop sessions out of the `since:` cutoff entirely).
  Each loadThreads call therefore copies main + -wal + -shm into a
  per-call temp dir under `FileManager.default.temporaryDirectory`
  and reads the copy with full WAL semantics. APFS clones the files
  via copy-on-write, so the cost is metadata-only. The snapshot is
  opened READ-WRITE, not read-only: SQLite refuses to open a
  WAL-mode database on a read-only connection unless a valid -shm
  already exists, and a cleanly-exited Codex checkpoints and deletes
  the sidecars — a read-only open of the bare snapshot then fails
  with SQLITE_CANTOPEN at the first statement (this bug shipped:
  every poll tick fell back to the title-less filesystem walk
  whenever Codex wasn't running).
  See: [CodexThreadDatabase.swift](Sources/Services/CodexThreadDatabase.swift),
  [CodexStorageService.swift](Sources/Services/CodexStorageService.swift)

- **No sidebar floor, no padding — sparse is correct.** The old
  minimum-5 floor padded quiet periods with stale relics (seen in the
  wild as five ancient Codex sessions at the bottom of the sidebar);
  it's gone on purpose. Each source enforces its own window and the
  merge is a pure sort: Claude is live-only (registry; windowless by
  construction, 24h walk window only as the no-registry fallback),
  Codex gets a tight 1-hour window — researched 2026-06: there is no
  Codex live-process signal (the app-server protocol only covers
  threads a client itself owns; every third-party viewer falls back
  to recency), so a short window is the honest approximation of
  "live". The services' `minimumCount` walk-floor parameters survive
  for API compatibility but AppModel passes 0.

- **Claude has no authoritative HISTORICAL session index** — the JSONL
  filesystem is the source of truth for past sessions. We've checked:
  Anthropic GitHub issues #9898, #29150, #14124 confirm there's no
  equivalent of Codex's `state_5.sqlite`. But there IS a live-process
  registry (next bullet), and the sidebar's Claude side is built on
  it.

- **The Claude sidebar is live-only, sourced from
  `~/.claude/sessions/`** (one JSON file per running process — the
  same data `claude agents --json` prints, read directly). Product
  decision: the app is a companion for conversations the user is
  actively having; a recency window of closed sessions is noise. The
  24h walk survives only as the fallback when the registry directory
  doesn't exist (older CLI versions). Hard-won registry facts,
  verified empirically (claude CLI 2.1.17x, 2026-06):
  - `entrypoint` is the discriminator, NOT `kind`: terminal sessions
    are "cli", the desktop app is "claude-desktop", and
    `claude --print` runs register as "sdk-cli" while still claiming
    `kind: "interactive"`. This app's own rewriter spawns
    `claude --print` per message — without the sdk-cli exclusion the
    sidebar flashes a phantom session on every rewrite.
  - Terminal `/name` lands in the entry's `name`; desktop-app names
    do NOT propagate (the desktop entry has no name field). Fall back
    to transcript-derived titles.
  - Entries can outlive crashed processes; validate with
    `kill(pid, 0)` before trusting.
  - cwd → `~/.claude/projects/` directory mapping replaces every
    non-alphanumeric with '-' (so `/.config` produces a double dash).
  - Live sessions bypass the recency window in AppModel's floor
    logic, and a registry-directory watcher makes launches/exits
    appear instantly; busy/idle flips rewrite files in place (no
    directory vnode event) and ride the 5s poll instead.
  See: [ClaudeSessionRegistry.swift](Sources/Services/ClaudeSessionRegistry.swift)

- **Transcript tail-signature check before incremental parse.** Claude
  Code writes JSONL append-only but rewind / edit / session-fork can
  rewrite the prefix. Comparing the last ~128 cached bytes against
  what's now on disk guards the fast path; mismatch → full reparse.

- **Transcripts hold a rolling window of 10 or 50 messages depending
  on the intermediate-message filter, never the full JSONL.** Cold
  loads tail-read in widening chunks (256 KB initial, doubles on
  miss) until they have enough post-filter messages — the whole file
  is never parsed regardless of session length. The filter is
  controlled by `AppModel.showOnlyFinalAssistantMessages` (default
  FALSE — the full stream is the first-run experience; final-only is
  opt-in): when on, assistant messages with `stop_reason == "tool_use"`
  (Claude) or `phase != "final_answer"` (Codex) are dropped, and the
  cap is `messageCapFinalOnly = 10`. When off (the default), all
  assistant turns pass through and the cap is
  `messageCapIncludingIntermediates = 50`.
  Both storage caches key on `(path, filterToFinalOnly)` so toggling
  the mode triggers a fresh tail-load. There is intentionally no
  "load earlier" affordance — the app's job is reading current
  messages aloud, not historical scrollback. Don't lift either cap
  "because we have the bytes" without re-running the cold-load
  timing on a long session.
  See: [Sources/Models/TranscriptDisplayLimits.swift](Sources/Models/TranscriptDisplayLimits.swift),
  [Sources/Support/TranscriptTailReader.swift](Sources/Support/TranscriptTailReader.swift),
  [Sources/Models/TranscriptMessage.swift](Sources/Models/TranscriptMessage.swift)
  (the `isIntermediate` field).

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
  `SessionSummary.transcriptURL: URL` refactor we had to add
  `removeAllCachedResourceValues()` before re-reading mtime/fileSize,
  or the incremental-tail path sees stale values and skips newly-
  appended content. The existing test
  `loadTranscriptIncorporatesAppendedJSONLLines` will catch regressions.

- **Scroll-to-bottom is a four-part pragmatic shim around SwiftUI's
  poor chat-UI scroll story.** The framework simply does not have a
  reliable "stick to bottom while content settles" primitive, and
  multiple iterations have all leaked at different seams. Current
  layered mechanisms in `TranscriptDetailView` (none of them
  optional — each catches a different real failure mode):

  1. **Eager VStack**, not LazyVStack. The 50-message cap
     (`TranscriptDisplayLimits`) keeps eager layout cheap. With
     LazyVStack, `.defaultScrollAnchor(.bottom)` and
     `proxy.scrollTo(id, anchor: .bottom)` reliably landed "one or
     two messages short of the true bottom" because cell-height
     estimates diverged from actuals (Apple Forums thread 741406,
     still open). Don't switch back unless raising the cap.
  2. **`.defaultScrollAnchor(.bottom)`** on the ScrollView lands at
     bottom on initial mount.
  3. **`.id(session.id)` on `TranscriptDetailView` in ContentView**
     rebuilds the whole view on session switch. Resets @State and
     gives mechanism 2 a fresh mount to fire on.
  4. **Generation-counter pin task** (`bottomPinGeneration` /
     `bottomPinTargetID`). `requestBottomPin()` is called from
     `.onAppear`, `transcriptMessages.last?.id` change, and
     `onScrollGeometryChange(contentSize)` change. Each call bumps
     the generation; `.task(id: bottomPinGeneration)` cancels the
     prior task and runs three no-animation `proxy.scrollTo`
     passes (after a `Task.yield()`, then 20 ms, then 120 ms) to
     catch row-height re-measurement that happens after the
     initial layout settles. Each pass re-checks both
     `userSetAtBottom` AND `transcriptMessages.last?.id ==
     targetID` so stale tasks can't fight a newer pin or yank a
     user who has scrolled away.

  The 20 ms / 120 ms intervals are empirical and ugly — they
  account for `Text(verbatim:)` rows finalizing height a frame or
  two after the parent layout claims to be done. A cleaner
  alternative — `.scrollPosition(id:anchor:)` against a bottom-
  sentinel view — is on the [TODO.md](TODO.md) Later Ideas list
  with the spike plan, success criteria, and revert path.

  `userSetAtBottom` is sampled ONLY when `ScrollPhase` transitions
  to `.idle` from a user-initiated phase
  (`.tracking` / `.decelerating` / `.interacting`). Updating it
  from `.animating` (programmatic scrolls) or content-growth-
  driven idle transitions would latch it false and break auto-pin
  silently — that trap was seen in the logs.

  The 250 px "at bottom" threshold is empirical: with
  `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` the scroll
  physics reserve ~165 px for the blur edge, so the user's visual
  bottom lands at `remaining ≈ 165`, not 0.

- **`TranscriptMarkdownView` renders markdown via the parse-time
  `Content` classification** (restored 2026-06-11 after the original
  perf concern — unbounded transcripts + LazyVStack re-parsing on
  scroll — was retired by the message cap and eager VStack).
  `.literal` (Claude's XML-ish envelopes) and `.plainText` stay
  `Text(verbatim:)`; `.markdown` renders through Textual's
  `StructuredText`. Collapsed rows height-cap + clip the markdown
  instead of using `lineLimit` — StructuredText sets `.lineLimit(nil)`
  internally because an environment line limit applies PER text
  fragment (a three-paragraph doc would show 3× the lines).

- **ElevenLabs output format is `pcm_48000` — and the tier gating is
  weirder than it looks.** Verified empirically against the live API
  (2026-06, pay-as-you-go account): `pcm_44100` is rejected with
  "Pro tier and above" while `pcm_48000` succeeds. Don't "fix" the
  format to 44.1kHz for roundness — it's the one that's gated. If a
  403 `output_format_not_allowed` ever surfaces for a lower-tier
  user, the fallback is `pcm_24000` (available on every tier; the
  app shipped on it before the 48k discovery).

- **ElevenLabs speed: generation is pinned to 1.0; the WPM slider is
  applied as on-device playback time-stretch.**
  `voice_settings.speed` only accepts 0.7–1.2 (verified against the
  current API schema + help center, 2026-06; anything outside is a
  400), which capped audible speed at ~1.2× and made the backend
  useless at the top of the slider. The slider maps to
  `rate = wpm / 175` (175 wpm ≈ ElevenLabs voices' natural pace, so
  slider position ≈ audible wpm, matching `say -r` semantics),
  applied by StreamingAudioPlayer at playback. Generation streams
  faster than realtime, so accelerated playback doesn't starve
  mid-utterance. Don't reintroduce a generation-side speed mapping:
  squeezing prosody at generation sounds worse than stretching at
  playback, and the API range can't cover the slider anyway.

- **StreamingAudioPlayer is AVSampleBufferAudioRenderer +
  `AVAudioTimePitchAlgorithm.timeDomain`, not an AVAudioEngine
  graph.** Two prior iterations are knowingly retired:
  `AVAudioUnitTimePitch` is a phase-vocoder stretcher whose
  signature artifact at 2×+ made speech hollow / tinny / phone-line
  ("phasiness") even with its overlap parameter maxed at 32 — and
  effect AUs reject raw Int16 connection formats anyway (NSException
  at connect time). The renderer stack exposes Apple's
  voice-optimized time-domain (WSOLA-family) stretcher, which avoids
  phasiness on single-voice speech. Two load-bearing details: the
  synchronizer's timebase starts on the FIRST enqueued chunk, not in
  play() — the clock runs in real time, so starting it before the
  network's first byte would clip the start of every utterance by
  the TTFB — and completion is a boundary-time observer at the
  end-of-media time, which is media-time based and therefore
  inherently "played back, not consumed" as well as rate- and
  pause-aware. If 2.3× speech still disappoints by ear, the
  escalation path is Signalsmith Stretch (MIT, C++ interop) inside
  the same player surface.
  See: [StreamingAudioPlayer.swift](Sources/Services/StreamingAudioPlayer.swift)

- **The renderer is rebuilt per utterance and recovers from macOS
  auto-flushes — don't go back to one reused renderer.** macOS
  silently flushes an idle/paused `AVSampleBufferAudioRenderer` on
  sleep/wake and output-device/route changes; crucially its `status`
  stays `.rendering` (NOT `.failed`), so the `.failed` KVO observer
  never fires — the synchronizer clock keeps advancing and playback
  "completes" while emitting pure silence. With a single renderer
  reused for the app's lifetime (the original design) one such flush
  wedged ALL subsequent playback until relaunch. Two defenses, both
  load-bearing: (1) `play()` rebuilds the renderer + synchronizer
  fresh each utterance, so a wedge can't outlive the current one;
  (2) each utterance's PCM chunks are retained, and on the
  `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification`
  the player rebuilds, re-enqueues the retained audio, and restores
  the timebase to the pre-flush position so a paused utterance
  resumes from where it left off instead of going silent. Confirmed
  empirically via `log stream` capture (the flush fires on sleep AND
  wake; recovery replayed ~1531 chunks and re-seated the clock at the
  27.1s pause point) plus listening — this layer can't be unit-tested
  (needs real audio hardware; it's also why the audio-clock test
  suite can't run headless). The notification is referenced by raw
  name string because the Swift-imported symbol isn't stable across
  SDKs.
  See: [StreamingAudioPlayer.swift](Sources/Services/StreamingAudioPlayer.swift)

- **Apple Dev signing also enables stable Keychain ACLs** — re-entering
  the API key once after switching from adhoc to Apple Dev is
  expected; future rebuilds don't prompt.

## Tooling / workflow

- **Prerequisites:** Xcode 26+ (provides `swift`, `xcrun actool`, and
  the macOS 26 SDK targeted in `Package.swift`). `gh` for PR work.
  No other system tools are required by the build itself.
- **Build + run:** `./script/build_and_run.sh` wraps `swift build`,
  stages SPM resource bundles into the `.app`, runs `xcrun actool`
  on the asset catalog, and codesigns. Accepts `run` (default),
  `--debug`, `--logs`, `--telemetry`, `--verify`.
- **Tests:** `swift test`. `waitUntil` (in `Tests/TestHelpers.swift`)
  beats fixed `Task.sleep` for "wait for an async side effect"
  scenarios. Test targets are scoped per service / driver / store;
  add new tests next to the closest existing suite. Run one suite
  with `swift test --filter ClaudeStorageServiceTests` (or any
  suite name). Storage-layer tests follow the temp-directory-fixture
  pattern (write a small JSONL into `FileManager.temporaryDirectory`,
  load via the service, `defer { try? fileManager.removeItem(...) }`);
  see `ClaudeStorageServiceTests` for the canonical shape.
- **OSLog:** subsystem is `me.malob.agentsaloud`; one category per
  service (`Storage`, `CodexStorage`, `TranscriptParser`,
  `CodexTranscriptParser`, `Speech`, `ElevenLabsDriver`,
  `StreamingAudioPlayer`, `AppModel`, `Perf`, …). Stream with
  `log stream --info --style compact --predicate 'subsystem == "me.malob.agentsaloud"'`,
  scope further with `&& category == "X"` as needed.
- **Timing instrumentation:** wrap measurable hot-path work with
  `PerfLog.time("Service.operation") { … }` (sync or async; the
  async overload inherits caller actor isolation via `#isolation`)
  and emit phase markers with `PerfLog.mark(...)`. Both stream as
  the `Perf` OSLog category.

## Style

- Swift 6 strict concurrency. Lean on `@MainActor @Observable` for
  app-level state; use `actor` for I/O services; mark helper
  formatters `nonisolated` when they touch no actor state.
- **Models/ stays SwiftUI-free.** Domain types are pure Foundation +
  Swift stdlib. SwiftUI-typed extensions (e.g. `Color`-returning
  helpers per source) live alongside the View that owns the
  rendering — see `Sources/Views/SourceBrandIcon.swift` for the
  pattern.
- Prefer `@Bindable var model` in SwiftUI views that need bindings
  over hand-rolled `Binding(get:set:)`.
- Comments: WHY, not WHAT. Default is no comment; only add one when
  the non-obvious constraint or past-incident context can't be read
  off the code itself.
- No emojis in code or docs unless explicitly requested.
- No inline `?:` chains more than one level deep — break into a
  computed property or `switch`.

## Deferred refactors

Two substantive refactors that have been considered and parked
because the benefit didn't justify the scope at the time. Documented
here so they don't get re-derived from scratch:

- **5 s polling sidebar refresh → FSEvents.** `AppModel.swift`
  currently re-enumerates `~/.claude/projects/` every 5 s (search for
  `Task.sleep(for: .seconds(5))`). FSEvents on the projects root
  would eliminate the idle poll, but the current behavior is quiet
  enough that the win is invisible.
- **`SessionSelection` enum fusion.** A handful of optionals
  (`selectedSessionID`, `liveReadSessionID`, etc.) could be unified
  into a single state enum that makes invalid combinations
  unrepresentable. Real refactor, nothing currently broken because
  of the loose representation.
