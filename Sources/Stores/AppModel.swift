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
    // How far back to show sessions in the sidebar. The session list is for
    // recent work — anything older you can still dig up, but we don't try to
    // keep weeks of history in the main view.
    private static let sessionLookback: TimeInterval = 24 * 60 * 60  // 24 hours

    private let storageService: ClaudeStorageService
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "AppModel")
    @ObservationIgnored private let userDefaults: UserDefaults

    var sessionsState: SessionsState = .loading([])
    var selectedSessionID: ClaudeSessionSummary.ID?
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
            preferredVoiceIdentifier = speechController.resolveVoiceIdentifier(preferredVoiceIdentifier)
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
        selectedTranscriptWatcher: any TranscriptFileWatching = TranscriptFileWatcher()
    ) {
        self.storageService = storageService
        self.speechController = speechController
        self.userDefaults = userDefaults
        self.selectedTranscriptWatcher = selectedTranscriptWatcher

        if let storedValue = userDefaults.string(forKey: Self.preferredSpeechBackendKey),
           let backend = SpeechBackend(rawValue: storedValue) {
            preferredSpeechBackend = backend
        } else {
            preferredSpeechBackend = .avSpeech
        }

        let storedRate = userDefaults.double(forKey: Self.preferredSpeechRateKey)
        preferredSpeechRate = storedRate == 0 ? Double(AVSpeechUtteranceDefaultSpeechRate) : storedRate
        speechController.backend = preferredSpeechBackend
        preferredVoiceIdentifier = speechController.resolveVoiceIdentifier(
            userDefaults.string(forKey: Self.preferredVoiceIdentifierKey)
        )
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
    }

    func start() async {
        guard sessionRefreshTask == nil else {
            return
        }

        sessionsState = .loading(sessionsState.sessions)
        await refreshSessions()

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

    func selectSession(id: ClaudeSessionSummary.ID?) {
        guard selectedSessionID != id else {
            return
        }

        PerfLog.mark("AppModel.selectSession start id=\(id ?? "nil")")

        selectionRefreshTask?.cancel()
        selectedTranscriptRefreshTask?.cancel()
        selectedSessionID = id
        updateSelectedTranscriptObservation()

        guard let id else {
            transcriptState = .none
            return
        }

        let cached = cachedTranscriptMessages(for: id)
        PerfLog.mark("AppModel.selectSession setLoading cached=\(cached.count)")
        transcriptState = .loading(sessionID: id, messages: cached)

        selectionRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            await refreshTranscript(for: id, allowLiveRead: false, showLoadingState: true)
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
        }
    }

    func playMessage(_ message: TranscriptMessage) {
        speechController.playNow(
            text: message.text,
            messageID: message.id,
            voiceIdentifier: preferredVoiceIdentifier,
            rate: Float(preferredSpeechRate)
        )
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

            // Clear selection when the previously selected session is no longer available.
            // The user picks which session to view from the sidebar.
            selectedSessionID = nil
            transcriptState = .none
            updateSelectedTranscriptObservation()
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

                    speechController.enqueue(
                        text: message.text,
                        messageID: message.id,
                        voiceIdentifier: preferredVoiceIdentifier,
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
        let transcriptURL = URL(fileURLWithPath: selectedSession.transcriptPath)

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

            // Debounce rapid file-system events while Claude is still appending to the transcript.
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
