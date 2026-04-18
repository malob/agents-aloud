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

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var queuedRequests: [SpeechRequest] = []
    @ObservationIgnored private var currentSayProcess: Process?
    @ObservationIgnored private var currentSayInputPipe: Pipe?
    @ObservationIgnored private lazy var supportedVoices = Self.loadSupportedVoices()
    @ObservationIgnored private lazy var supportedVoiceIdentifiers = Set(supportedVoices.map(\.id))

    var backend: SpeechBackend = .avSpeech {
        didSet {
            guard oldValue != backend else {
                return
            }

            stop()
        }
    }
    var isSpeaking = false
    var isPaused = false
    var currentMessageID: String?

    override init() {
        super.init()
        synthesizer.delegate = self
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
        if isSpeaking || isPaused {
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

        if isSpeaking || isPaused {
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
            guard let process = currentSayProcess, process.isRunning else {
                return
            }

            kill(process.processIdentifier, SIGSTOP)
            isPaused = true
            isSpeaking = false
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
            guard let process = currentSayProcess, isPaused, process.isRunning else {
                return
            }

            kill(process.processIdentifier, SIGCONT)
            isPaused = false
            isSpeaking = true
        }
    }

    func stop() {
        queuedRequests.removeAll()
        interruptCurrentPlayback()
        isSpeaking = false
        isPaused = false
        currentMessageID = nil
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

            currentMessageID = request.messageID
            synthesizer.speak(utterance)

        case .systemVoice:
            speakWithSystemVoice(request)
        }
    }

    private func playNextQueuedRequestIfNeeded() {
        guard !queuedRequests.isEmpty else {
            currentMessageID = nil
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", String(systemVoiceWordsPerMinute)]
        process.standardInput = inputPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.currentSayProcess = nil
                self.currentSayInputPipe = nil
                self.isSpeaking = false
                self.isPaused = false
                self.playNextQueuedRequestIfNeeded()
            }
        }

        do {
            try process.run()
            currentSayProcess = process
            currentSayInputPipe = inputPipe
            currentMessageID = request.messageID
            isSpeaking = true
            isPaused = false

            if let data = request.text.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
        } catch {
            currentSayProcess = nil
            currentSayInputPipe = nil
            currentMessageID = nil
            isSpeaking = false
            isPaused = false
        }
    }

    private func stopSystemVoiceProcess() {
        currentSayInputPipe?.fileHandleForWriting.closeFile()
        currentSayInputPipe = nil

        guard let process = currentSayProcess else {
            return
        }

        if process.isRunning {
            process.terminate()
        }

        currentSayProcess = nil
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
            self.isSpeaking = true
            self.isPaused = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.playNextQueuedRequestIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.playNextQueuedRequestIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPaused = true
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPaused = false
            self.isSpeaking = true
        }
    }
}
