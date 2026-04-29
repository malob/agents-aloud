import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
    private static let preferredSpeechBackendKey = "preferredSpeechBackend"
    private static let preferredWordsPerMinuteKey = "preferredWordsPerMinute"
    private static let preferredElevenLabsVoiceIDKey = "preferredElevenLabsVoiceID"
    private static let speechTextOptimizationEnabledKey = "speechTextOptimizationEnabled"
    private static let speechTextOptimizationModeKey = "speechTextOptimizationMode"
    private static let claudeCLIModelKey = "claudeCLIModel"
    private static let claudeCLIEffortKey = "claudeCLIEffort"
    static let defaultKeychainService = "local.claudecodevoice"
    static let elevenLabsAPIKeyAccount = "elevenlabs_api_key"
    // Default rate when the user hasn't picked one. Matches what the
    // app shipped with when SystemVoice was hardcoded — anyone who
    // updates from that build keeps the same audible cadence.
    static let defaultWordsPerMinute = 400
    // Slider bounds. 100 is intelligible-but-deliberate; 500 is `say`'s
    // upper "still understandable" range — past that it's a chipmunk.
    static let minimumWordsPerMinute = 100
    static let maximumWordsPerMinute = 500
    // How far back to show sessions in the sidebar. The session list is for
    // recent work — anything older you can still dig up, but we don't try to
    // keep weeks of history in the main view.
    private static let sessionLookback: TimeInterval = 24 * 60 * 60  // 24 hours

    private let storageService: ClaudeStorageService
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "AppModel")
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStorage
    @ObservationIgnored private var elevenLabsVoiceRefreshTask: Task<Void, Never>?
    // The text-rewrite processor. Held here only to forward to
    // SpeechController on init / setting change — AppModel itself
    // doesn't call process() directly anymore; the rewriter lives
    // inside SpeechController's queue pipeline.
    @ObservationIgnored private var speechTextProcessor: any SpeechTextProcessor

    var sessionsState: SessionsState = .loading([])
    var selectedSessionID: ClaudeSessionSummary.ID? {
        didSet {
            guard oldValue != selectedSessionID else {
                return
            }

            PerfLog.mark("AppModel.selectedSessionID change id=\(selectedSessionID ?? "nil")")
            selectionRefreshTask?.cancel()
            selectedTranscriptRefreshTask?.cancel()
            // Playback continues across session navigation. The queue
            // is cross-session by design: items enqueued from session
            // A's context stay in flight even when the user navigates
            // to B to work on something else. Stop is now reserved
            // for the explicit toolbar Stop button.
            updateSelectedTranscriptObservation()
            // Live Speak is independent of selection. If the user
            // navigates away from the Live-Speak-enabled session, the
            // live-read watcher takes over monitoring its file; if
            // they navigate to it, the selected watcher handles both
            // roles and the live-read watcher idles.
            reconcileLiveReadWatcher()

            guard let id = selectedSessionID else {
                transcriptState = .none
                return
            }

            let cached = cachedTranscriptMessages(for: id)
            PerfLog.mark("AppModel.selectedSessionID setLoading cached=\(cached.count)")
            transcriptState = .loading(sessionID: id, messages: cached)

            selectionRefreshTask = Task { [weak self] in
                guard let self else {
                    return
                }

                await refreshTranscript(for: id, showLoadingState: true)
            }
        }
    }
    var transcriptState: TranscriptState = .none
    var errorMessage: String?
    var liveReadSessionID: ClaudeSessionSummary.ID? {
        didSet {
            guard oldValue != liveReadSessionID else { return }
            reconcileLiveReadWatcher()
        }
    }

    // True while the speech controller has anything in its queue — a
    // rewrite in progress, or ready items waiting for playback.
    // Drives the toolbar Stop button's enabled state so users can
    // cancel even before audio starts emitting.
    var isPreparingPlayback: Bool {
        !speechController.queue.isEmpty
    }
    var preferredSpeechBackend: SpeechBackend {
        didSet {
            guard oldValue != preferredSpeechBackend else {
                return
            }

            userDefaults.set(preferredSpeechBackend.rawValue, forKey: Self.preferredSpeechBackendKey)
            speechController.backend = preferredSpeechBackend
            // Per-backend voice selection happens via `currentVoiceIdentifier`,
            // which dispatches on the active backend. SystemVoice has no
            // app-level voice ID; ElevenLabs has its own pref.
        }
    }
    var preferredWordsPerMinute: Int {
        didSet {
            guard oldValue != preferredWordsPerMinute else {
                return
            }
            userDefaults.set(preferredWordsPerMinute, forKey: Self.preferredWordsPerMinuteKey)
        }
    }

    // ElevenLabs API key. Stored in the Keychain (not UserDefaults) since
    // it's a credential. Setting it rebuilds the driver's client with the
    // new key and kicks off a voice-list refresh so the Settings picker
    // can populate.
    var elevenLabsAPIKey: String? {
        didSet {
            guard oldValue != elevenLabsAPIKey else {
                return
            }

            do {
                try keychain.set(elevenLabsAPIKey, for: Self.elevenLabsAPIKeyAccount)
            } catch {
                logger.error("Failed to persist ElevenLabs API key: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Couldn't save ElevenLabs API key to Keychain: \(error.localizedDescription). It will work for this session but you'll need to re-enter it next launch."
            }
            applyElevenLabsAPIKey()
        }
    }

    var preferredElevenLabsVoiceID: String? {
        didSet {
            guard oldValue != preferredElevenLabsVoiceID else {
                return
            }

            if let preferredElevenLabsVoiceID {
                userDefaults.set(preferredElevenLabsVoiceID, forKey: Self.preferredElevenLabsVoiceIDKey)
            } else {
                userDefaults.removeObject(forKey: Self.preferredElevenLabsVoiceIDKey)
            }
        }
    }

    // Which backend (if any) rewrites assistant message text for speech
    // before handing it to the TTS engine. Off by default — opt-in so
    // users can decide whether the added latency per message is worth
    // the improved listening experience.
    var speechTextOptimizationMode: SpeechTextOptimization {
        didSet {
            guard oldValue != speechTextOptimizationMode else {
                return
            }
            userDefaults.set(speechTextOptimizationMode.rawValue, forKey: Self.speechTextOptimizationModeKey)
            applySpeechTextProcessor()
        }
    }

    // Which Claude model the CLI rewriter calls. Only meaningful when
    // speechTextOptimizationMode == .claudeCLI. Swapping it re-builds
    // the processor so subsequent rewrites use the new model; items
    // already mid-rewrite continue with their original model.
    var claudeCLIModel: ClaudeCLIModel {
        didSet {
            guard oldValue != claudeCLIModel else { return }
            userDefaults.set(claudeCLIModel.rawValue, forKey: Self.claudeCLIModelKey)
            if speechTextOptimizationMode == .claudeCLI {
                applySpeechTextProcessor()
            }
        }
    }

    // --effort level passed to the Claude CLI. Lower = faster; the
    // sweep eval at fixed model=Sonnet showed quality is
    // indistinguishable across low/medium/high for our task. Same
    // re-build-on-change semantics as claudeCLIModel.
    var claudeCLIEffort: ClaudeCLIEffort {
        didSet {
            guard oldValue != claudeCLIEffort else { return }
            userDefaults.set(claudeCLIEffort.rawValue, forKey: Self.claudeCLIEffortKey)
            if speechTextOptimizationMode == .claudeCLI {
                applySpeechTextProcessor()
            }
        }
    }

    // Per-message expansion state for the collapse/expand affordance on
    // long transcript rows. Defaults to collapsed; the user toggles via
    // the "Show more/less" button. Lives here — not as @State in the
    // row — so LazyVStack recycling a row out and back as the user
    // scrolls doesn't reset its expansion.
    var expandedMessageIDs: Set<TranscriptMessage.ID> = []

    func isMessageExpanded(_ id: TranscriptMessage.ID) -> Bool {
        expandedMessageIDs.contains(id)
    }

    func toggleMessageExpanded(_ id: TranscriptMessage.ID) {
        if expandedMessageIDs.contains(id) {
            expandedMessageIDs.remove(id)
        } else {
            expandedMessageIDs.insert(id)
        }
    }

    let speechController: SpeechController

    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedTranscriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var liveReadTranscriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let selectedTranscriptWatcher: any TranscriptFileWatching
    // Second watcher for the Live Speak session when it differs from
    // the currently-selected session — Live Speak can stay on session
    // A while the user navigates to B to work on something else, and
    // this watcher keeps A's file monitored for new assistant
    // messages to auto-enqueue.
    @ObservationIgnored private let liveReadTranscriptWatcher: any TranscriptFileWatching
    @ObservationIgnored private var transcriptMessagesBySession: [ClaudeSessionSummary.ID: [TranscriptMessage]] = [:]
    // Owned strong so it lives for the app's lifetime. Holds a weak
    // back-reference to AppModel and observes speech-controller
    // state via Observation tracking.
    @ObservationIgnored private var nowPlayingCoordinator: NowPlayingCoordinator?
    @ObservationIgnored private var knownAssistantMessageIDsBySession: [ClaudeSessionSummary.ID: Set<TranscriptMessage.ID>] = [:]

    init(
        storageService: ClaudeStorageService = ClaudeStorageService(),
        speechController: SpeechController = SpeechController(),
        userDefaults: UserDefaults = .standard,
        selectedTranscriptWatcher: any TranscriptFileWatching = TranscriptFileWatcher(),
        liveReadTranscriptWatcher: any TranscriptFileWatching = TranscriptFileWatcher(),
        keychain: KeychainStorage = KeychainStorage(service: AppModel.defaultKeychainService),
        // Tests can inject an explicit processor to control latency /
        // behavior. nil = derive from the persisted setting at init
        // (passthrough by default, FoundationModel when enabled).
        speechTextProcessor: (any SpeechTextProcessor)? = nil
    ) {
        self.storageService = storageService
        self.speechController = speechController
        self.userDefaults = userDefaults
        self.selectedTranscriptWatcher = selectedTranscriptWatcher
        self.liveReadTranscriptWatcher = liveReadTranscriptWatcher
        self.keychain = keychain
        let explicitProcessor = speechTextProcessor
        self.speechTextProcessor = explicitProcessor ?? PassthroughSpeechProcessor()

        if let storedValue = userDefaults.string(forKey: Self.preferredSpeechBackendKey),
           let backend = SpeechBackend(rawValue: storedValue) {
            preferredSpeechBackend = backend
        } else {
            // System Voice is the new default. Users who previously had
            // AVSpeech ("av_speech") in UserDefaults won't match the
            // SpeechBackend(rawValue:) lookup above and will fall here
            // — implicit one-way migration to System Voice, which is
            // the closest behavioral analog now that AVSpeech is gone.
            preferredSpeechBackend = .systemVoice
        }

        // wpm pref. Stored as an Int. UserDefaults returns 0 for missing
        // keys, which we treat as "use the default."
        let storedWPM = userDefaults.integer(forKey: Self.preferredWordsPerMinuteKey)
        preferredWordsPerMinute = storedWPM > 0 ? storedWPM : Self.defaultWordsPerMinute

        // ElevenLabs prefs. Log-then-swallow keychain read failures so init
        // still succeeds (e.g. sandboxed test run, user denied ACL). Without
        // the log, a user whose key silently "disappears" across launches
        // has no trace to debug from.
        let storedKey: String?
        do {
            storedKey = try keychain.get(Self.elevenLabsAPIKeyAccount)
        } catch {
            logger.error(
                "Failed to load ElevenLabs API key from Keychain: \(error.localizedDescription, privacy: .public)"
            )
            storedKey = nil
        }
        elevenLabsAPIKey = storedKey
        preferredElevenLabsVoiceID = userDefaults.string(forKey: Self.preferredElevenLabsVoiceIDKey)

        // Read the enum setting; fall back to the legacy Bool key for
        // users upgrading from the pre-enum build. Users who had the
        // retired `.foundationModel` value selected migrate to `.off`
        // (that backend never produced useful output and has been
        // removed).
        if let modeRaw = userDefaults.string(forKey: Self.speechTextOptimizationModeKey),
           let mode = SpeechTextOptimization(rawValue: modeRaw) {
            speechTextOptimizationMode = mode
        } else if userDefaults.bool(forKey: Self.speechTextOptimizationEnabledKey) {
            speechTextOptimizationMode = .claudeCLI
        } else {
            speechTextOptimizationMode = .off
        }

        // Claude CLI model preference: default Sonnet. Ignores unknown
        // rawValues (e.g. after a version where we renamed cases).
        if let modelRaw = userDefaults.string(forKey: Self.claudeCLIModelKey),
           let model = ClaudeCLIModel(rawValue: modelRaw) {
            claudeCLIModel = model
        } else {
            claudeCLIModel = .sonnet
        }

        // Claude CLI effort preference: default medium. Same fall-
        // through behavior as the model pref above.
        if let effortRaw = userDefaults.string(forKey: Self.claudeCLIEffortKey),
           let effort = ClaudeCLIEffort(rawValue: effortRaw) {
            claudeCLIEffort = effort
        } else {
            claudeCLIEffort = .medium
        }

        speechController.backend = preferredSpeechBackend

        applyElevenLabsAPIKey()
        // Only derive from the setting if the caller didn't inject one
        // explicitly. Tests need their injected processor to survive init.
        if explicitProcessor == nil {
            applySpeechTextProcessor()
        } else {
            // Forward the injected processor into the controller too so
            // its rewriter uses the test-supplied implementation.
            speechController.setSpeechTextProcessor(self.speechTextProcessor)
        }

        // Wire the SpeechController's voice + rate providers to read
        // our current preferences. Evaluated at speak() time, not at
        // enqueue time — keeps the queue cross-backend-safe.
        speechController.voiceIdentifierProvider = { [weak self] in
            self?.currentVoiceIdentifier
        }
        speechController.wordsPerMinuteProvider = { [weak self] in
            self?.preferredWordsPerMinute ?? Self.defaultWordsPerMinute
        }

        // Bridge speech-controller state into the macOS Now Playing
        // system (Control Center, menu-bar Now Playing widget, AirPods
        // gestures, media keys). Held weak-in / strong-out: the
        // coordinator keeps a weak ref to `self` and we retain it.
        nowPlayingCoordinator = NowPlayingCoordinator(model: self)
    }

    // Swap the speech text processor based on the user's selected mode.
    // Called from init and on setting change. Each processor handles
    // its own availability gating — if the underlying capability is
    // unavailable (Apple Intelligence disabled, claude CLI not found,
    // etc.), it falls back to passthrough internally without user
    // intervention.
    private func applySpeechTextProcessor() {
        switch speechTextOptimizationMode {
        case .off:
            speechTextProcessor = PassthroughSpeechProcessor()
        case .claudeCLI:
            speechTextProcessor = ClaudeCLISpeechProcessor(
                model: claudeCLIModel.cliArgument,
                effort: claudeCLIEffort.cliArgument
            )
        }
        // Forward the selection into SpeechController so its rewriter
        // pipeline uses the right backend for subsequent inserts.
        speechController.setSpeechTextProcessor(speechTextProcessor)
    }

    // Whether the claude CLI is currently findable on PATH. Surfaced
    // in Settings to disable the Claude CLI option + show an install
    // hint when not found.
    var isClaudeCLIAvailable: Bool {
        ClaudeCLISpeechProcessor.isAvailable
    }

    // Swap the ElevenLabs driver's client to one configured with the
    // current API key (if any) and kick off a voice-list refresh.
    private func applyElevenLabsAPIKey() {
        elevenLabsVoiceRefreshTask?.cancel()

        guard let key = elevenLabsAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            // No key: leave the driver with an empty-key client so any
            // attempt to use it fails fast with an auth error surfaced
            // through the existing playback-error banner.
            speechController.elevenLabsDriver.replaceClient(ElevenLabsClient(apiKey: ""))
            return
        }

        speechController.elevenLabsDriver.replaceClient(ElevenLabsClient(apiKey: key))
        elevenLabsVoiceRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speechController.elevenLabsDriver.refreshVoices()
            } catch is CancellationError {
                // Replaced by a newer refresh; nothing to report.
            } catch {
                // Only banner the error if ElevenLabs is actually the
                // active backend — otherwise a stale key reload in the
                // background shouldn't blast the user with a toast.
                if preferredSpeechBackend == .elevenLabs {
                    errorMessage = "Couldn't load ElevenLabs voices: \(error.localizedDescription)"
                }
            }
        }
    }

    // SystemVoice ignores app-level voice identifiers entirely — it
    // routes through the system-wide voice the user picked in System
    // Settings → Accessibility → Spoken Content. ElevenLabs has its
    // own per-account voice list with disjoint IDs; route through the
    // driver's resolver so a nil / unknown pref falls back to the
    // first loaded voice (otherwise a first-time ElevenLabs user with
    // a valid key but no voice picked would hit "No voice selected"
    // on play).
    var currentVoiceIdentifier: String? {
        switch preferredSpeechBackend {
        case .systemVoice:
            return nil
        case .elevenLabs:
            return speechController.resolveVoiceIdentifier(preferredElevenLabsVoiceID)
        }
    }

    var selectedSession: ClaudeSessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    var sessions: [ClaudeSessionSummary] {
        sessionsState.sessions
    }

    var transcriptMessages: [TranscriptMessage] {
        transcriptState.messages
    }

    var isLoading: Bool {
        sessionsState.isLoading
    }

    var isLoadingTranscript: Bool {
        guard let selectedSessionID else {
            return false
        }

        return transcriptState.isLoading(for: selectedSessionID)
    }

    deinit {
        sessionRefreshTask?.cancel()
        selectionRefreshTask?.cancel()
        selectedTranscriptRefreshTask?.cancel()
        liveReadTranscriptRefreshTask?.cancel()
        elevenLabsVoiceRefreshTask?.cancel()
    }

    func start() async {
        guard sessionRefreshTask == nil else {
            return
        }

        sessionsState = .loading(sessionsState.sessions)
        await refreshSessions()

        // 5s poll is a backstop for session additions/removals (new
        // sessions appearing on disk, deletions, renames). The per-file
        // watcher in updateSelectedTranscriptObservation handles real-time
        // updates to the selected transcript; this loop only needs to be
        // fast enough that a newly-created session shows up quickly in
        // the sidebar.
        sessionRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.refreshSessions()
            }
        }
    }

    // Toggle Live Speak. Under the one-Live-Speak-at-a-time rule the
    // toggle always targets the currently-selected session:
    //
    //  - Enable (from off): turn on for selectedSessionID. If another
    //    session had Live Speak, this TRANSFERS ownership — queued
    //    auto items from the old session are kept (they finish
    //    playing), but no new arrivals from it will auto-enqueue.
    //  - Disable (only when liveReadSessionID == selectedSessionID):
    //    explicit off. Drain this session's auto items from the
    //    queue so "stop reading me new messages" actually stops.
    //    Manual items and other sessions' items are unaffected.
    func setLiveReadEnabled(_ isEnabled: Bool) {
        guard let selectedSessionID else {
            if !isEnabled { liveReadSessionID = nil }
            return
        }

        if isEnabled {
            guard liveReadSessionID != selectedSessionID else { return }
            // Seed the known-assistant set for the new session so we
            // don't re-read history — only messages that arrive AFTER
            // this toggle should auto-enqueue.
            knownAssistantMessageIDsBySession[selectedSessionID] = Set(
                transcriptMessages
                    .filter(\.isAssistant)
                    .map(\.id)
            )
            liveReadSessionID = selectedSessionID
        } else if liveReadSessionID == selectedSessionID {
            let disabledSessionID = selectedSessionID
            liveReadSessionID = nil
            speechController.drainAutoQueue(for: disabledSessionID)
        }
    }

    func playMessage(_ message: TranscriptMessage) {
        speechController.insertManual(
            messageID: message.id,
            sourceText: message.text,
            sessionID: message.sessionID
        )
    }

    // If `message` is a user prompt, start at the next assistant;
    // otherwise start at `message`. Enqueues every following assistant
    // message as a contiguous manual block (stays together even if
    // Live Speak had items queued behind it when this fires).
    func playMessagesFromHere(_ message: TranscriptMessage) {
        let messages = transcriptState.messages
        guard let startIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let fromHere = messages[startIndex...].filter(\.isAssistant)
        guard !fromHere.isEmpty else { return }

        speechController.insertManualSequence(
            fromHere.map { m in
                (
                    messageID: m.id,
                    sourceText: m.text,
                    sessionID: m.sessionID
                )
            }
        )
    }

    // User-initiated "stop everything" — active playback + queue +
    // in-flight rewrite all go away. Views call this instead of
    // reaching into speechController.stop() directly so cancellation
    // semantics stay centralised here.
    func stopPlayback() {
        speechController.stop()
    }

    func dismissErrorMessage() {
        errorMessage = nil
    }

    private func refreshSessions() async {
        let existingSessions = sessionsState.sessions

        do {
            let loadedSessions = try await storageService.loadSessions(
                since: Date().addingTimeInterval(-Self.sessionLookback)
            )
            if sessionsState != .loaded(loadedSessions) {
                sessionsState = .loaded(loadedSessions)
            }
            let currentSessionIDs = Set(loadedSessions.map(\.id))
            transcriptMessagesBySession = transcriptMessagesBySession.filter { currentSessionIDs.contains($0.key) }
            knownAssistantMessageIDsBySession = knownAssistantMessageIDsBySession.filter { currentSessionIDs.contains($0.key) }

            // If the Live Speak session disappeared from the sidebar
            // (deleted, aged out of the lookback window), clear it.
            if let liveReadSessionID, !currentSessionIDs.contains(liveReadSessionID) {
                self.liveReadSessionID = nil
            }

            if let selectedSessionID, loadedSessions.contains(where: { $0.id == selectedSessionID }) {
                updateSelectedTranscriptObservation()
                reconcileLiveReadWatcher()
                return
            }

            // didSet on selectedSessionID handles transcriptState + watcher cleanup.
            selectedSessionID = nil
        } catch {
            let newErrorMessage = sessionLoadErrorMessage(for: error)
            sessionsState = .failed(existingSessions, message: newErrorMessage)
            errorMessage = newErrorMessage
        }
    }

    // Refresh a session's transcript state. Live Speak eligibility is
    // determined from `liveReadSessionID` at commit time, not from a
    // schedule-time hint — this avoids a race where a non-live refresh
    // scheduled just before `setLiveReadEnabled` would advance the
    // known-assistant set past messages that should have been
    // auto-enqueued, silently swallowing the first Live Speak message.
    private func refreshTranscript(
        for sessionID: ClaudeSessionSummary.ID,
        showLoadingState: Bool = false
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        PerfLog.mark("AppModel.refreshTranscript start session=\(sessionID)")
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            PerfLog.mark("AppModel.refreshTranscript end \(String(format: "%.1f", elapsed))ms")
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        let existingMessages = transcriptState.messages(for: sessionID)

        if showLoadingState, selectedSessionID == sessionID {
            transcriptState = .loading(sessionID: sessionID, messages: existingMessages)
        }

        do {
            let loadedTranscript = try await storageService.loadTranscript(for: session)
            PerfLog.mark("AppModel.refreshTranscript loaded count=\(loadedTranscript.count)")
            guard !Task.isCancelled else {
                return
            }

            transcriptMessagesBySession[sessionID] = loadedTranscript
            // Read presence explicitly (not `?? []`) so we can distinguish
            // "seeded with zero assistant messages" (Live Speak enabled on
            // a fresh session — the first reply should be spoken) from
            // "never seeded" (Live Speak not enabled — don't replay any
            // history). The old `!previousIDs.isEmpty` guard conflated the
            // two and made Live Speak miss the first response in empty
            // sessions.
            let previousIDs: Set<TranscriptMessage.ID>? = knownAssistantMessageIDsBySession[sessionID]
            let assistantMessages = loadedTranscript.filter(\.isAssistant)
            let latestAssistantIDs = Set(assistantMessages.map(\.id))

            if selectedSessionID == sessionID {
                let alreadyCurrent: Bool
                if case let .loaded(currentSessionID, currentMessages) = transcriptState,
                   currentSessionID == sessionID,
                   currentMessages.count == loadedTranscript.count,
                   currentMessages.first?.id == loadedTranscript.first?.id,
                   currentMessages.last?.id == loadedTranscript.last?.id {
                    alreadyCurrent = true
                } else {
                    alreadyCurrent = false
                }

                if !alreadyCurrent {
                    PerfLog.mark("AppModel.refreshTranscript commit count=\(loadedTranscript.count)")
                    transcriptState = .loaded(sessionID: sessionID, messages: loadedTranscript)
                } else {
                    PerfLog.mark("AppModel.refreshTranscript skip (already current)")
                }
            }

            // Decide Live Speak eligibility from the CURRENT state at
            // commit. If Live Speak was enabled between schedule and
            // commit (race), we still want to enqueue the new messages
            // we found — otherwise the unconditional known-set update
            // below would mark them seen forever and the first auto-
            // spoken message would be silently dropped.
            if liveReadSessionID == sessionID, let previousIDs {
                let newAssistantMessages = assistantMessages.filter { !previousIDs.contains($0.id) }
                for message in newAssistantMessages {
                    guard liveReadSessionID == sessionID else { break }
                    speechController.insertAuto(
                        messageID: message.id,
                        sourceText: message.text,
                        sessionID: sessionID
                    )
                }
            }

            knownAssistantMessageIDsBySession[sessionID] = latestAssistantIDs
        } catch is CancellationError {
            return
        } catch {
            if selectedSessionID == sessionID {
                transcriptState = .failed(
                    sessionID: sessionID,
                    messages: existingMessages,
                    message: transcriptLoadErrorMessage(for: error)
                )
            }
            logger.error("Failed to refresh transcript \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateSelectedTranscriptObservation() {
        guard let selectedSession else {
            selectedTranscriptWatcher.stop()
            return
        }

        let sessionID = selectedSession.id
        let transcriptURL = selectedSession.transcriptURL

        selectedTranscriptWatcher.startWatching(
            fileURL: transcriptURL,
            onChange: { [weak self] in
                guard let self, self.selectedSessionID == sessionID else {
                    return
                }

                self.scheduleSelectedTranscriptRefresh(for: sessionID)
            },
            onFailure: { [weak self] error in
                guard let self, self.selectedSessionID == sessionID else {
                    return
                }

                let message = self.watcherErrorMessage(error)
                self.logger.error("Transcript watcher error for \(transcriptURL.path, privacy: .public): \(message, privacy: .public)")
                self.errorMessage = message
            }
        )
    }

    // Keep the live-read watcher in sync with liveReadSessionID +
    // selectedSessionID. The live-read watcher is only active when
    // Live Speak is on for a session OTHER than the one currently
    // being viewed — if they match, the selected watcher handles
    // both roles, and doubling up would duplicate file-event work.
    //
    // Called from the didSet on both liveReadSessionID and
    // selectedSessionID, plus from refreshSessions when the sessions
    // list changes (the live-read session may have been renamed /
    // deleted).
    private func reconcileLiveReadWatcher() {
        guard let liveReadSessionID, liveReadSessionID != selectedSessionID else {
            liveReadTranscriptWatcher.stop()
            liveReadTranscriptRefreshTask?.cancel()
            liveReadTranscriptRefreshTask = nil
            return
        }

        guard let session = sessions.first(where: { $0.id == liveReadSessionID }) else {
            // Session not in our sidebar list (probably deleted or
            // outside the lookback window). Drop the watcher and
            // clear the ID so UI stays consistent.
            liveReadTranscriptWatcher.stop()
            liveReadTranscriptRefreshTask?.cancel()
            liveReadTranscriptRefreshTask = nil
            return
        }

        let watchedID = liveReadSessionID
        let transcriptURL = session.transcriptURL
        liveReadTranscriptWatcher.startWatching(
            fileURL: transcriptURL,
            onChange: { [weak self] in
                guard let self, self.liveReadSessionID == watchedID else { return }
                self.scheduleLiveReadTranscriptRefresh(for: watchedID)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.logger.error(
                    "Live-read watcher error for \(transcriptURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        )
        // Catch up any messages that arrived on this session's file
        // during the brief window between the previous watcher (if
        // any) stopping and this one starting. Idempotent because
        // knownAssistantMessageIDsBySession filters out already-seen
        // messages.
        scheduleLiveReadTranscriptRefresh(for: watchedID)
    }

    private func scheduleLiveReadTranscriptRefresh(for sessionID: ClaudeSessionSummary.ID) {
        liveReadTranscriptRefreshTask?.cancel()
        liveReadTranscriptRefreshTask = Task { [weak self] in
            guard let self else { return }
            // Same 150ms debounce as the selected-transcript path —
            // coalesce bursty appends from streaming assistant output.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await refreshTranscript(for: sessionID)
        }
    }

    private func scheduleSelectedTranscriptRefresh(for sessionID: ClaudeSessionSummary.ID) {
        selectedTranscriptRefreshTask?.cancel()
        selectedTranscriptRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            // Debounce rapid file-system events while Claude is still
            // appending to the transcript. 150ms balances responsiveness
            // for users watching live-read against the coalescing of
            // bursts of appends during streaming assistant output
            // (otherwise every token write would trigger a full parse).
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else {
                return
            }

            await refreshTranscript(for: sessionID)
        }
    }

    private func cachedTranscriptMessages(for sessionID: ClaudeSessionSummary.ID) -> [TranscriptMessage] {
        transcriptMessagesBySession[sessionID] ?? []
    }

    // Lookup helper so subsystems like NowPlayingCoordinator can
    // surface the text + session for whatever message the speech
    // engine is currently playing. Cross-session because the queue
    // can span sessions (manual clicks from any session land in the
    // same queue alongside Live Speak arrivals).
    func findMessage(id: TranscriptMessage.ID) -> (message: TranscriptMessage, session: ClaudeSessionSummary)? {
        for session in sessions {
            if let messages = transcriptMessagesBySession[session.id],
               let message = messages.first(where: { $0.id == id }) {
                return (message, session)
            }
        }
        return nil
    }

    private func watcherErrorMessage(_ error: TranscriptFileWatcherError) -> String {
        switch error {
        case let .openFailed(_, errorNumber) where errorNumber == EACCES || errorNumber == EPERM:
            return "Unable to watch transcript for live updates: permission denied. Check Claude transcript access permissions."
        case let .openFailed(_, errorNumber) where errorNumber == EMFILE:
            return "Unable to watch transcript for live updates: too many open files. Try restarting the app."
        case let .openFailed(fileName, errorNumber):
            let systemMessage = String(cString: strerror(errorNumber))
            return "Unable to watch transcript for live updates: \(fileName) (\(systemMessage))"
        }
    }

    private func transcriptLoadErrorMessage(for error: Error) -> String {
        "Unable to load transcript: \(error.localizedDescription)"
    }

    private func sessionLoadErrorMessage(for error: Error) -> String {
        "Unable to load Claude sessions: \(error.localizedDescription)"
    }
}
