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
    private static let sessionListLimit = 30

    private let storageService = ClaudeStorageService()
    private let logger = Logger(subsystem: "local.claudecodevoice", category: "AppModel")
    @ObservationIgnored private let userDefaults = UserDefaults.standard

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

    let speechController = SpeechController()

    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedTranscriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let selectedTranscriptWatcher = TranscriptFileWatcher()
    @ObservationIgnored private var knownAssistantMessageIDsBySession: [ClaudeSessionSummary.ID: Set<TranscriptMessage.ID>] = [:]

    init() {
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

        if let selectedSessionID {
            if transcriptState == .none {
                transcriptState = .loading(sessionID: selectedSessionID, messages: [])
            }
            await refreshTranscript(for: selectedSessionID, allowLiveRead: false, showLoadingState: true)
        }

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

        selectionRefreshTask?.cancel()
        selectedSessionID = id
        updateSelectedTranscriptObservation()

        guard let id else {
            transcriptState = .none
            return
        }

        transcriptState = .loading(sessionID: id, messages: [])

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
            let loadedSessions = try await storageService.loadSessions(limit: Self.sessionListLimit)
            if sessionsState != .loaded(loadedSessions) {
                sessionsState = .loaded(loadedSessions)
            }
            let currentSessionIDs = Set(loadedSessions.map(\.id))
            knownAssistantMessageIDsBySession = knownAssistantMessageIDsBySession.filter { currentSessionIDs.contains($0.key) }

            if let selectedSessionID, loadedSessions.contains(where: { $0.id == selectedSessionID }) {
                updateSelectedTranscriptObservation()
                return
            }

            selectedSessionID = loadedSessions.first?.id
            if let selectedSessionID {
                transcriptState = .loading(sessionID: selectedSessionID, messages: [])
            } else {
                transcriptState = .none
            }
            updateSelectedTranscriptObservation()
        } catch {
            let newErrorMessage = "Unable to load Claude sessions: \(error.localizedDescription)"
            sessionsState = .failed(existingSessions, message: newErrorMessage)
            errorMessage = newErrorMessage
        }
    }

    private func refreshTranscript(
        for sessionID: ClaudeSessionSummary.ID,
        allowLiveRead: Bool,
        showLoadingState: Bool = false
    ) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        let existingMessages = transcriptState.messages(for: sessionID)

        if showLoadingState, selectedSessionID == sessionID {
            transcriptState = .loading(sessionID: sessionID, messages: existingMessages)
        }

        do {
            let loadedTranscript = try await storageService.loadTranscript(for: session)
            guard !Task.isCancelled else {
                return
            }

            let previousIDs = knownAssistantMessageIDsBySession[sessionID] ?? []
            let assistantMessages = loadedTranscript.filter(\.isAssistant)
            let latestAssistantIDs = Set(assistantMessages.map(\.id))

            if selectedSessionID == sessionID,
               transcriptState != .loaded(sessionID: sessionID, messages: loadedTranscript) {
                transcriptState = .loaded(sessionID: sessionID, messages: loadedTranscript)
            }

            if allowLiveRead, !previousIDs.isEmpty {
                let newAssistantMessages = assistantMessages.filter { !previousIDs.contains($0.id) }
                for message in newAssistantMessages {
                    speechController.enqueue(
                        text: message.text,
                        messageID: message.id,
                        voiceIdentifier: preferredVoiceIdentifier,
                        rate: Float(preferredSpeechRate)
                    )
                }
            }

            knownAssistantMessageIDsBySession[sessionID] = latestAssistantIDs
            if errorMessage != nil {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if selectedSessionID == sessionID {
                transcriptState = .failed(
                    sessionID: sessionID,
                    messages: existingMessages,
                    message: "Unable to load transcript: \(error.localizedDescription)"
                )
            }

            let newErrorMessage = "Unable to load transcript: \(error.localizedDescription)"
            if errorMessage != newErrorMessage {
                errorMessage = newErrorMessage
            }
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
            onFailure: { [weak self] message in
                guard let self, self.selectedSessionID == sessionID else {
                    return
                }

                self.logger.error("Transcript watcher error for \(transcriptURL.path, privacy: .public): \(message, privacy: .public)")
                self.errorMessage = "Unable to watch transcript for live updates: \(message)"
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

}
