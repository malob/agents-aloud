import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let preferredSpeechBackendKey = "preferredSpeechBackend"
    private static let preferredVoiceIdentifierKey = "preferredVoiceIdentifier"
    private static let preferredSpeechRateKey = "preferredSpeechRate"
    private static let sessionListLimit = 30

    private let storageService = ClaudeStorageService()

    var sessions: [ClaudeSessionSummary] = []
    var selectedSessionID: ClaudeSessionSummary.ID?
    var transcriptMessages: [TranscriptMessage] = []
    var searchQuery = ""
    var isLoading = false
    var errorMessage: String?
    var liveReadSessionID: ClaudeSessionSummary.ID?

    let speechController = SpeechController()

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var knownAssistantMessageIDsBySession: [ClaudeSessionSummary.ID: Set<TranscriptMessage.ID>] = [:]

    var selectedSession: ClaudeSessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    var hasActiveSearch: Bool {
        !normalizedSearchQuery.isEmpty
    }

    var displayedSessions: [ClaudeSessionSummary] {
        guard !normalizedSearchQuery.isEmpty else {
            return sessions
        }

        return sessions.filter { session in
            searchMatches(session.summary) ||
            searchMatches(session.projectName) ||
            searchMatches(session.projectPath) ||
            searchMatches(session.firstPrompt)
        }
    }

    var displayedTranscriptMessages: [TranscriptMessage] {
        guard !normalizedSearchQuery.isEmpty else {
            return transcriptMessages
        }

        return transcriptMessages.filter { message in
            searchMatches(message.text) ||
            searchMatches(message.role.rawValue)
        }
    }

    var preferredSpeechBackend: SpeechBackend {
        get {
            if let storedValue = UserDefaults.standard.string(forKey: Self.preferredSpeechBackendKey),
               let backend = SpeechBackend(rawValue: storedValue) {
                return backend
            }

            return .avSpeech
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferredSpeechBackendKey)
            speechController.backend = newValue
        }
    }

    var preferredVoiceIdentifier: String? {
        get {
            speechController.resolveVoiceIdentifier(
                UserDefaults.standard.string(forKey: Self.preferredVoiceIdentifierKey)
            )
        }
        set {
            let resolvedVoiceIdentifier = speechController.resolveVoiceIdentifier(newValue)

            if let resolvedVoiceIdentifier {
                UserDefaults.standard.set(resolvedVoiceIdentifier, forKey: Self.preferredVoiceIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredVoiceIdentifierKey)
            }
        }
    }

    var preferredSpeechRate: Double {
        get {
            let storedValue = UserDefaults.standard.double(forKey: Self.preferredSpeechRateKey)
            if storedValue == 0 {
                return Double(AVSpeechUtteranceDefaultSpeechRate)
            }

            return storedValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferredSpeechRateKey)
        }
    }

    deinit {
        pollingTask?.cancel()
        selectionRefreshTask?.cancel()
    }

    func start() async {
        guard pollingTask == nil else {
            return
        }

        preferredSpeechBackend = preferredSpeechBackend
        preferredVoiceIdentifier = preferredVoiceIdentifier
        isLoading = true
        await refreshSessions()

        if let selectedSessionID {
            await refreshTranscript(for: selectedSessionID, allowLiveRead: false)
        }

        isLoading = false

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            var loopCount = 0

            while !Task.isCancelled {
                loopCount += 1

                if loopCount % 5 == 0 {
                    await self.refreshSessions()
                }

                if let selectedSessionID = self.selectedSessionID {
                    await self.refreshTranscript(
                        for: selectedSessionID,
                        allowLiveRead: self.liveReadSessionID == selectedSessionID
                    )
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func selectSession(id: ClaudeSessionSummary.ID?) {
        guard selectedSessionID != id else {
            return
        }

        selectionRefreshTask?.cancel()
        selectedSessionID = id
        transcriptMessages = []

        guard let id else {
            return
        }

        selectionRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            await refreshTranscript(for: id, allowLiveRead: false)
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

    private func refreshSessions() async {
        do {
            let loadedSessions = try await storageService.loadSessions(limit: Self.sessionListLimit)
            if sessions != loadedSessions {
                sessions = loadedSessions
            }

            if let selectedSessionID, loadedSessions.contains(where: { $0.id == selectedSessionID }) {
                return
            }

            selectedSessionID = loadedSessions.first?.id
        } catch {
            errorMessage = "Unable to load Claude sessions: \(error.localizedDescription)"
        }
    }

    private func refreshTranscript(for sessionID: ClaudeSessionSummary.ID, allowLiveRead: Bool) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        do {
            let loadedTranscript = try await storageService.loadTranscript(for: session)
            guard !Task.isCancelled else {
                return
            }

            let previousIDs = knownAssistantMessageIDsBySession[sessionID] ?? []
            let assistantMessages = loadedTranscript.filter(\.isAssistant)
            let latestAssistantIDs = Set(assistantMessages.map(\.id))

            if selectedSessionID == sessionID, transcriptMessages != loadedTranscript {
                transcriptMessages = loadedTranscript
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
        } catch {
            if selectedSessionID == sessionID {
                if !transcriptMessages.isEmpty {
                    transcriptMessages = []
                }
            }

            let newErrorMessage = "Unable to load transcript: \(error.localizedDescription)"
            if errorMessage != newErrorMessage {
                errorMessage = newErrorMessage
            }
        }
    }

    private var normalizedSearchQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
    }

    private func searchMatches(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        return value.localizedLowercase.contains(normalizedSearchQuery)
    }
}
