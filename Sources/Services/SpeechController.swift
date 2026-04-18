import AVFoundation
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class SpeechController: NSObject {
    private static let experimentalSystemVoiceWordsPerMinute = 400

    private struct SpeechRequest {
        let messageID: String
        let text: String
        let voiceIdentifier: String?
        let rate: Float
    }

    private final class SystemVoiceJob {
        let process: Process
        let inputPipe: Pipe

        init(process: Process, inputPipe: Pipe) {
            self.process = process
            self.inputPipe = inputPipe
        }
    }

    private struct ActivePlayback {
        let request: SpeechRequest
        let systemVoiceJob: SystemVoiceJob?
    }

    private enum PlaybackState {
        case idle
        case speaking(ActivePlayback)
        case paused(ActivePlayback)

        var activePlayback: ActivePlayback? {
            switch self {
            case .idle:
                return nil
            case let .speaking(activePlayback), let .paused(activePlayback):
                return activePlayback
            }
        }

        var currentMessageID: String? {
            activePlayback?.request.messageID
        }

        var isSpeaking: Bool {
            if case .speaking = self {
                return true
            }

            return false
        }

        var isPaused: Bool {
            if case .paused = self {
                return true
            }

            return false
        }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var queuedRequests: [SpeechRequest] = []
    @ObservationIgnored private lazy var supportedVoices = Self.loadSupportedVoices()
    @ObservationIgnored private lazy var supportedVoiceIdentifiers = Set(supportedVoices.map(\.id))
    private var playbackState: PlaybackState = .idle

    var backend: SpeechBackend = .avSpeech {
        didSet {
            guard oldValue != backend else {
                return
            }

            stop()
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        playbackState.isSpeaking
    }

    var isPaused: Bool {
        playbackState.isPaused
    }

    var currentMessageID: String? {
        playbackState.currentMessageID
    }

    var availableVoices: [SpeechVoiceOption] {
        supportedVoices
    }

    var systemVoiceWordsPerMinute: Int {
        Self.experimentalSystemVoiceWordsPerMinute
    }

    var defaultVoiceIdentifier: String? {
        guard !supportedVoices.isEmpty else {
            return nil
        }

        let preferredEnglishLanguages = preferredEnglishLanguageCodes()

        for languageCode in preferredEnglishLanguages {
            if let exactMatch = supportedVoices.first(where: { $0.language == languageCode }) {
                return exactMatch.id
            }
        }

        if let usEnglishVoice = supportedVoices.first(where: { $0.language == "en-US" }) {
            return usEnglishVoice.id
        }

        return supportedVoices.first?.id
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        if let identifier, supportedVoiceIdentifiers.contains(identifier) {
            return identifier
        }

        return defaultVoiceIdentifier
    }

    func playNow(text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        if playbackState.activePlayback != nil {
            queuedRequests = [
                SpeechRequest(
                    messageID: messageID,
                    text: text,
                    voiceIdentifier: voiceIdentifier,
                    rate: rate
                )
            ]
            interruptCurrentPlayback()
            return
        }

        speak(
            SpeechRequest(
                messageID: messageID,
                text: text,
                voiceIdentifier: voiceIdentifier,
                rate: rate
            )
        )
    }

    func enqueue(text: String, messageID: String, voiceIdentifier: String?, rate: Float) {
        let request = SpeechRequest(
            messageID: messageID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )

        if playbackState.activePlayback != nil {
            queuedRequests.append(request)
        } else {
            speak(request)
        }
    }

    func pause() {
        switch backend {
        case .avSpeech:
            guard synthesizer.isSpeaking else {
                return
            }

            synthesizer.pauseSpeaking(at: .word)

        case .systemVoice:
            guard case let .speaking(activePlayback) = playbackState,
                  let process = activePlayback.systemVoiceJob?.process,
                  process.isRunning else {
                return
            }

            kill(process.processIdentifier, SIGSTOP)
            playbackState = .paused(activePlayback)
        }
    }

    func resume() {
        switch backend {
        case .avSpeech:
            guard synthesizer.isPaused else {
                return
            }

            synthesizer.continueSpeaking()

        case .systemVoice:
            guard case let .paused(activePlayback) = playbackState,
                  let process = activePlayback.systemVoiceJob?.process,
                  process.isRunning else {
                return
            }

            kill(process.processIdentifier, SIGCONT)
            playbackState = .speaking(activePlayback)
        }
    }

    func stop() {
        queuedRequests.removeAll()
        interruptCurrentPlayback()
        playbackState = .idle
    }

    private func speak(_ request: SpeechRequest) {
        switch backend {
        case .avSpeech:
            let utterance = AVSpeechUtterance(string: request.text)
            utterance.rate = request.rate

            if let voiceIdentifier = resolveVoiceIdentifier(request.voiceIdentifier),
               let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }

            playbackState = .speaking(
                ActivePlayback(
                    request: request,
                    systemVoiceJob: nil
                )
            )
            synthesizer.speak(utterance)

        case .systemVoice:
            speakWithSystemVoice(request)
        }
    }

    private func playNextQueuedRequestIfNeeded() {
        guard !queuedRequests.isEmpty else {
            playbackState = .idle
            return
        }

        let nextRequest = queuedRequests.removeFirst()
        speak(nextRequest)
    }

    private func interruptCurrentPlayback() {
        switch backend {
        case .avSpeech:
            if synthesizer.isSpeaking || synthesizer.isPaused {
                synthesizer.stopSpeaking(at: .immediate)
            }

        case .systemVoice:
            stopSystemVoiceProcess()
        }
    }

    private func speakWithSystemVoice(_ request: SpeechRequest) {
        stopSystemVoiceProcess()

        let process = Process()
        let inputPipe = Pipe()
        let job = SystemVoiceJob(process: process, inputPipe: inputPipe)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", String(systemVoiceWordsPerMinute)]
        process.standardInput = inputPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.finishCurrentPlayback()
            }
        }

        do {
            try process.run()
            playbackState = .speaking(
                ActivePlayback(
                    request: request,
                    systemVoiceJob: job
                )
            )

            if let data = request.text.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
        } catch {
            playbackState = .idle
        }
    }

    private func stopSystemVoiceProcess() {
        guard let activePlayback = playbackState.activePlayback,
              let job = activePlayback.systemVoiceJob else {
            return
        }

        job.inputPipe.fileHandleForWriting.closeFile()

        if job.process.isRunning {
            job.process.terminate()
        }
    }

    private func finishCurrentPlayback() {
        switch playbackState {
        case .idle:
            playNextQueuedRequestIfNeeded()
        case let .speaking(activePlayback), let .paused(activePlayback):
            if let job = activePlayback.systemVoiceJob {
                job.inputPipe.fileHandleForWriting.closeFile()
            }

            playbackState = .idle
            playNextQueuedRequestIfNeeded()
        }
    }

    private func setPlaybackStateToSpeaking() {
        guard let activePlayback = playbackState.activePlayback else {
            return
        }

        playbackState = .speaking(activePlayback)
    }

    private func setPlaybackStateToPaused() {
        guard let activePlayback = playbackState.activePlayback else {
            return
        }

        playbackState = .paused(activePlayback)
    }

    private func handleSpeechSynthesizerEvent(_ event: SpeechSynthesizerEvent) {
        switch event {
        case .didStart, .didContinue:
            setPlaybackStateToSpeaking()
        case .didPause:
            setPlaybackStateToPaused()
        case .didFinish, .didCancel:
            finishCurrentPlayback()
        }
    }

    private enum SpeechSynthesizerEvent {
        case didStart
        case didFinish
        case didCancel
        case didPause
        case didContinue
    }

    private static func loadSupportedVoices() -> [SpeechVoiceOption] {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix("en-") || voice.language == "en"
            }
            .filter { voice in
                voice.identifier.hasPrefix("com.apple.voice.")
            }

        let voicesToExpose: [AVSpeechSynthesisVoice]
        if englishVoices.contains(where: { $0.quality == .enhanced }) {
            voicesToExpose = englishVoices.filter { $0.quality == .enhanced }
        } else {
            voicesToExpose = englishVoices
        }

        return voicesToExpose
            .map { voice in
                SpeechVoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: voice.quality
                )
            }
            .sorted(by: compareVoiceOptions)
    }

    private static func compareVoiceOptions(_ lhs: SpeechVoiceOption, _ rhs: SpeechVoiceOption) -> Bool {
        let lhsScore = voicePriority(for: lhs)
        let rhsScore = voicePriority(for: rhs)

        if lhsScore != rhsScore {
            return lhsScore < rhsScore
        }

        if lhs.language != rhs.language {
            return lhs.language < rhs.language
        }

        return lhs.name < rhs.name
    }

    private static func voicePriority(for voice: SpeechVoiceOption) -> Int {
        switch voice.language {
        case "en-US":
            return 0
        case "en-GB":
            return 1
        case "en-AU":
            return 2
        case "en-IE":
            return 3
        case "en-IN":
            return 4
        case "en-ZA":
            return 5
        case "en":
            return 6
        default:
            return 10
        }
    }

    private func preferredEnglishLanguageCodes() -> [String] {
        Locale.preferredLanguages
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { language in
                language == "en" || language.hasPrefix("en-")
            }
            .reduce(into: [String]()) { result, language in
                if !result.contains(language) {
                    result.append(language)
                }
            }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleSpeechSynthesizerEvent(.didStart)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleSpeechSynthesizerEvent(.didFinish)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleSpeechSynthesizerEvent(.didCancel)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleSpeechSynthesizerEvent(.didPause)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleSpeechSynthesizerEvent(.didContinue)
        }
    }
}
