import AVFoundation
import Darwin
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
    @ObservationIgnored private let userDefaults = UserDefaults.standard

    var sessions: [ClaudeSessionSummary] = []
    var selectedSessionID: ClaudeSessionSummary.ID?
    var transcriptMessages: [TranscriptMessage] = []
    var isLoading = false
    var isLoadingTranscript = false
    var errorMessage: String?
    var liveReadSessionID: ClaudeSessionSummary.ID?

    let speechController = SpeechController()

    @ObservationIgnored private var sessionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedTranscriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let selectedTranscriptWatcher = TranscriptFileWatcher()
    @ObservationIgnored private var knownAssistantMessageIDsBySession: [ClaudeSessionSummary.ID: Set<TranscriptMessage.ID>] = [:]

    init() {
        applyStoredSpeechPreferences()
    }

    var selectedSession: ClaudeSessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    var preferredSpeechBackend: SpeechBackend {
        get {
            if let storedValue = userDefaults.string(forKey: Self.preferredSpeechBackendKey),
               let backend = SpeechBackend(rawValue: storedValue) {
                return backend
            }

            return .avSpeech
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Self.preferredSpeechBackendKey)
            speechController.backend = newValue
        }
    }

    var preferredVoiceIdentifier: String? {
        get {
            speechController.resolveVoiceIdentifier(
                userDefaults.string(forKey: Self.preferredVoiceIdentifierKey)
            )
        }
        set {
            storePreferredVoiceIdentifier(
                speechController.resolveVoiceIdentifier(newValue)
            )
        }
    }

    var preferredSpeechRate: Double {
        get {
            let storedValue = userDefaults.double(forKey: Self.preferredSpeechRateKey)
            if storedValue == 0 {
                return Double(AVSpeechUtteranceDefaultSpeechRate)
            }

            return storedValue
        }
        set {
            userDefaults.set(newValue, forKey: Self.preferredSpeechRateKey)
        }
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

        isLoading = true
        await refreshSessions()

        if let selectedSessionID {
            await refreshTranscript(for: selectedSessionID, allowLiveRead: false, showLoadingState: true)
        }

        isLoading = false

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
        transcriptMessages = []
        isLoadingTranscript = id != nil
        updateSelectedTranscriptObservation()

        guard let id else {
            isLoadingTranscript = false
            return
        }

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

    private func refreshSessions() async {
        do {
            let loadedSessions = try await storageService.loadSessions(limit: Self.sessionListLimit)
            if sessions != loadedSessions {
                sessions = loadedSessions
            }

            if let selectedSessionID, loadedSessions.contains(where: { $0.id == selectedSessionID }) {
                updateSelectedTranscriptObservation()
                return
            }

            selectedSessionID = loadedSessions.first?.id
            updateSelectedTranscriptObservation()
        } catch {
            errorMessage = "Unable to load Claude sessions: \(error.localizedDescription)"
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
        
        if showLoadingState, selectedSessionID == sessionID {
            isLoadingTranscript = true
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
            
            if selectedSessionID == sessionID, isLoadingTranscript {
                isLoadingTranscript = false
            }
        } catch {
            if selectedSessionID == sessionID {
                if !transcriptMessages.isEmpty {
                    transcriptMessages = []
                }
                
                if isLoadingTranscript {
                    isLoadingTranscript = false
                }
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

        selectedTranscriptWatcher.startWatching(fileURL: transcriptURL) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.selectedSessionID == sessionID else {
                    return
                }

                self.scheduleSelectedTranscriptRefresh(for: sessionID)
            }
        }
    }

    private func scheduleSelectedTranscriptRefresh(for sessionID: ClaudeSessionSummary.ID) {
        selectedTranscriptRefreshTask?.cancel()
        selectedTranscriptRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

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

    private func applyStoredSpeechPreferences() {
        speechController.backend = preferredSpeechBackend
        storePreferredVoiceIdentifier(
            speechController.resolveVoiceIdentifier(
                userDefaults.string(forKey: Self.preferredVoiceIdentifierKey)
            )
        )
    }

    private func storePreferredVoiceIdentifier(_ identifier: String?) {
        if let identifier {
            userDefaults.set(identifier, forKey: Self.preferredVoiceIdentifierKey)
        } else {
            userDefaults.removeObject(forKey: Self.preferredVoiceIdentifierKey)
        }
    }
}

private final class TranscriptFileWatcher {
    private var watchedPath: String?
    private var source: DispatchSourceFileSystemObject?

    func startWatching(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        guard watchedPath != fileURL.path else {
            return
        }

        stop()

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()

        watchedPath = fileURL.path
        self.source = source
    }

    func stop() {
        watchedPath = nil
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
