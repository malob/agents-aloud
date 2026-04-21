import AVFoundation
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppModel {
    private static let preferredSpeechBackendKey = "preferredSpeechBackend"
    private static let preferredVoiceIdentifierKey = "preferredVoiceIdentifier"
    private static let preferredSpeechRateKey = "preferredSpeechRate"
    private static let preferredElevenLabsVoiceIDKey = "preferredElevenLabsVoiceID"
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
        speechTextProcessor: any SpeechTextProcessor = PassthroughSpeechProcessor()
    ) {
        self.storageService = storageService
        self.speechController = speechController
        self.userDefaults = userDefaults
        self.selectedTranscriptWatcher = selectedTranscriptWatcher
        self.keychain = keychain
        self.speechTextProcessor = speechTextProcessor

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

        speechController.backend = preferredSpeechBackend
        preferredVoiceIdentifier = speechController.resolveVoiceIdentifier(
            userDefaults.string(forKey: Self.preferredVoiceIdentifierKey)
        )

        applyElevenLabsAPIKey()
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
            // Drop queued messages so "Stop Live Speak" actually stops
            // reading new messages; the current utterance is allowed
            // to finish so the user isn't cut off mid-sentence.
            speechController.drainQueue()
        }
    }

    func playMessage(_ message: TranscriptMessage) {
        Task { [weak self] in
            guard let self else { return }
            let processed = await speechTextProcessor.process(text: message.text)
            speechController.playNow(
                text: processed,
                messageID: message.id,
                voiceIdentifier: currentVoiceIdentifier,
                rate: Float(preferredSpeechRate)
            )
        }
    }

    // If `message` is a user prompt, start at the next assistant; otherwise
    // start at `message`. Enqueues every following assistant message.
    func playMessagesFromHere(_ message: TranscriptMessage) {
        let messages = transcriptState.messages
        guard let startIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let fromHere = messages[startIndex...].filter(\.isAssistant)
        guard let first = fromHere.first else { return }

        let voice = currentVoiceIdentifier
        let rate = Float(preferredSpeechRate)

        Task { [weak self] in
            guard let self else { return }
            let processedFirst = await speechTextProcessor.process(text: first.text)
            speechController.playNow(
                text: processedFirst,
                messageID: first.id,
                voiceIdentifier: voice,
                rate: rate
            )

            // Process subsequent messages serially and enqueue as each
            // becomes ready. Serial (not parallel) keeps peak model load
            // bounded and hides later-message latency behind playback of
            // earlier ones.
            for next in fromHere.dropFirst() {
                let processedNext = await speechTextProcessor.process(text: next.text)
                speechController.enqueue(
                    text: processedNext,
                    messageID: next.id,
                    voiceIdentifier: voice,
                    rate: rate
                )
            }
        }
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
            let previousIDs = knownAssistantMessageIDsBySession[sessionID] ?? []
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

            if allowLiveRead, !previousIDs.isEmpty {
                let newAssistantMessages = assistantMessages.filter { !previousIDs.contains($0.id) }
                for message in newAssistantMessages {
                    guard selectedSessionID == sessionID, liveReadSessionID == sessionID else {
                        break
                    }

                    let processed = await speechTextProcessor.process(text: message.text)
                    guard selectedSessionID == sessionID, liveReadSessionID == sessionID else {
                        break
                    }

                    speechController.enqueue(
                        text: processed,
                        messageID: message.id,
                        voiceIdentifier: currentVoiceIdentifier,
                        rate: Float(preferredSpeechRate)
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
