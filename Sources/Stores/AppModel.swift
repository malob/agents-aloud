import AVFoundation
import Foundation
import FoundationModels
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
    private static let preferredSpeechBackendKey = "preferredSpeechBackend"
    private static let preferredVoiceIdentifierKey = "preferredVoiceIdentifier"
    private static let preferredSpeechRateKey = "preferredSpeechRate"
    private static let preferredElevenLabsVoiceIDKey = "preferredElevenLabsVoiceID"
    private static let speechTextOptimizationEnabledKey = "speechTextOptimizationEnabled"
    private static let speechTextOptimizationModeKey = "speechTextOptimizationMode"
    static let defaultKeychainService = "local.claudecodevoice"
    static let elevenLabsAPIKeyAccount = "elevenlabs_api_key"
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
            // Clear playback queue + active audio too; the user
            // switching sessions is a clear intent change.
            speechController.stop()
            updateSelectedTranscriptObservation()

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

                await refreshTranscript(for: id, allowLiveRead: false, showLoadingState: true)
            }
        }
    }
    var transcriptState: TranscriptState = .none
    var errorMessage: String?
    var liveReadSessionID: ClaudeSessionSummary.ID?

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
            // Don't normalize preferredVoiceIdentifier here — it's the
            // AVSpeech-scoped pref. Resolving it against the new backend
            // would overwrite it with a voice from a different backend's
            // ID space, destroying the user's App Voices choice. Per-backend
            // voice selection happens via `currentVoiceIdentifier`.
        }
    }
    var preferredVoiceIdentifier: String? {
        didSet {
            guard oldValue != preferredVoiceIdentifier else {
                return
            }

            if let preferredVoiceIdentifier {
                userDefaults.set(preferredVoiceIdentifier, forKey: Self.preferredVoiceIdentifierKey)
            } else {
                userDefaults.removeObject(forKey: Self.preferredVoiceIdentifierKey)
            }
        }
    }
    var preferredSpeechRate: Double {
        didSet {
            guard oldValue != preferredSpeechRate else {
                return
            }

            userDefaults.set(preferredSpeechRate, forKey: Self.preferredSpeechRateKey)
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

    let speechController: SpeechController

    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedTranscriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let selectedTranscriptWatcher: any TranscriptFileWatching
    @ObservationIgnored private var transcriptMessagesBySession: [ClaudeSessionSummary.ID: [TranscriptMessage]] = [:]
    @ObservationIgnored private var knownAssistantMessageIDsBySession: [ClaudeSessionSummary.ID: Set<TranscriptMessage.ID>] = [:]

    init(
        storageService: ClaudeStorageService = ClaudeStorageService(),
        speechController: SpeechController = SpeechController(),
        userDefaults: UserDefaults = .standard,
        selectedTranscriptWatcher: any TranscriptFileWatching = TranscriptFileWatcher(),
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
        self.keychain = keychain
        let explicitProcessor = speechTextProcessor
        self.speechTextProcessor = explicitProcessor ?? PassthroughSpeechProcessor()

        if let storedValue = userDefaults.string(forKey: Self.preferredSpeechBackendKey),
           let backend = SpeechBackend(rawValue: storedValue) {
            preferredSpeechBackend = backend
        } else {
            preferredSpeechBackend = .avSpeech
        }

        let storedRate = userDefaults.double(forKey: Self.preferredSpeechRateKey)
        preferredSpeechRate = storedRate == 0 ? Double(AVSpeechUtteranceDefaultSpeechRate) : storedRate

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

        // Read the new enum setting; fall back to deriving from the old
        // Bool key for users upgrading from the pre-enum build. If the
        // old Bool was true we pick `.claudeCLI` as the recommended
        // default; the FoundationModel option underperformed enough
        // that auto-migrating users onto it would be a regression.
        if let modeRaw = userDefaults.string(forKey: Self.speechTextOptimizationModeKey),
           let mode = SpeechTextOptimization(rawValue: modeRaw) {
            speechTextOptimizationMode = mode
        } else if userDefaults.bool(forKey: Self.speechTextOptimizationEnabledKey) {
            speechTextOptimizationMode = .claudeCLI
        } else {
            speechTextOptimizationMode = .off
        }

        speechController.backend = preferredSpeechBackend
        preferredVoiceIdentifier = speechController.resolveVoiceIdentifier(
            userDefaults.string(forKey: Self.preferredVoiceIdentifierKey)
        )

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
            speechTextProcessor = ClaudeCLISpeechProcessor()
        case .foundationModel:
            let processor = FoundationModelSpeechProcessor()
            speechTextProcessor = processor
            processor.prewarm()
        }
        // Forward the selection into SpeechController so its rewriter
        // pipeline uses the right backend for subsequent inserts.
        speechController.setSpeechTextProcessor(speechTextProcessor)
    }

    // Whether the on-device Apple Intelligence model is available.
    // Surfaced in Settings so the FM option can be disabled with an
    // explanatory message when unavailable.
    var foundationModelAvailability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
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

    // Voice IDs are backend-scoped (AVSpeech identifiers and ElevenLabs
    // voice IDs don't overlap). Routed through the driver's
    // `resolveVoiceIdentifier` so a nil / unknown pref falls back to the
    // first loaded voice — otherwise a first-time ElevenLabs user with a
    // valid key but no voice picked would hit "No voice selected" on play.
    // SystemVoice ignores identifiers entirely.
    var currentVoiceIdentifier: String? {
        switch preferredSpeechBackend {
        case .avSpeech:
            return speechController.resolveVoiceIdentifier(preferredVoiceIdentifier)
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

    func setLiveReadEnabled(_ isEnabled: Bool) {
        guard let selectedSessionID else {
            liveReadSessionID = nil
            return
        }

        if isEnabled {
            liveReadSessionID = selectedSessionID
            knownAssistantMessageIDsBySession[selectedSessionID] = Set(
                transcriptMessages
                    .filter(\.isAssistant)
                    .map(\.id)
            )
        } else if liveReadSessionID == selectedSessionID {
            liveReadSessionID = nil
            selectedTranscriptRefreshTask?.cancel()
            // Drop auto-queued Live Speak arrivals so "Stop Live Speak"
            // actually stops reading new messages — but keep manual
            // clicks in the queue, since disabling the auto feature
            // shouldn't undo the user's explicit Speak actions. The
            // current utterance also keeps playing so the user isn't
            // cut off mid-sentence.
            speechController.drainAutoQueue()
        }
    }

    func playMessage(_ message: TranscriptMessage) {
        speechController.insertManual(
            messageID: message.id,
            sourceText: message.text,
            voiceIdentifier: currentVoiceIdentifier,
            rate: Float(preferredSpeechRate),
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

        let voice = currentVoiceIdentifier
        let rate = Float(preferredSpeechRate)

        speechController.insertManualSequence(
            fromHere.map { m in
                (
                    messageID: m.id,
                    sourceText: m.text,
                    voiceIdentifier: voice,
                    rate: rate,
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

            if let selectedSessionID, loadedSessions.contains(where: { $0.id == selectedSessionID }) {
                updateSelectedTranscriptObservation()
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

    private func refreshTranscript(
        for sessionID: ClaudeSessionSummary.ID,
        allowLiveRead: Bool,
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

            if allowLiveRead, let previousIDs {
                let newAssistantMessages = assistantMessages.filter { !previousIDs.contains($0.id) }
                for message in newAssistantMessages {
                    guard selectedSessionID == sessionID, liveReadSessionID == sessionID else {
                        break
                    }
                    // Live Speak integration in full: append to the
                    // speech queue. The queue's own serial rewriter
                    // handles transformation; playback picks up when
                    // the rewrite is ready.
                    speechController.insertAuto(
                        messageID: message.id,
                        sourceText: message.text,
                        voiceIdentifier: currentVoiceIdentifier,
                        rate: Float(preferredSpeechRate),
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

            await refreshTranscript(
                for: sessionID,
                allowLiveRead: liveReadSessionID == sessionID
            )
        }
    }

    private func cachedTranscriptMessages(for sessionID: ClaudeSessionSummary.ID) -> [TranscriptMessage] {
        transcriptMessagesBySession[sessionID] ?? []
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
