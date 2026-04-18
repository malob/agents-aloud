import AVFoundation
import Foundation

@MainActor
final class AVSpeechBackendDriver: NSObject, SpeechBackendDriver {
    private let synthesizer = AVSpeechSynthesizer()
    private lazy var supportedVoices = Self.loadSupportedVoices()
    private lazy var supportedVoiceIdentifiers = Set(supportedVoices.map(\.id))
    private var eventHandler: (@MainActor @Sendable (SpeechDriverEvent) -> Void)?
    private var playbackIDsByUtteranceID: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var availableVoices: [SpeechVoiceOption] {
        supportedVoices
    }

    var wordsPerMinute: Int? {
        nil
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        if let identifier, supportedVoiceIdentifiers.contains(identifier) {
            return identifier
        }

        return defaultVoiceIdentifier
    }

    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws {
        self.eventHandler = eventHandler

        let utterance = AVSpeechUtterance(string: request.text)
        utterance.rate = request.rate

        if let voiceIdentifier = resolveVoiceIdentifier(request.voiceIdentifier),
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }

        playbackIDsByUtteranceID[ObjectIdentifier(utterance)] = request.playbackID
        synthesizer.speak(utterance)
    }

    func pause() {
        guard synthesizer.isSpeaking else {
            return
        }

        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        guard synthesizer.isPaused else {
            return
        }

        synthesizer.continueSpeaking()
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else {
            playbackIDsByUtteranceID.removeAll()
            return
        }

        synthesizer.stopSpeaking(at: .immediate)
    }

    private var defaultVoiceIdentifier: String? {
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

    private func playbackID(for utteranceID: ObjectIdentifier) -> UUID? {
        playbackIDsByUtteranceID[utteranceID]
    }

    private func removePlaybackID(for utteranceID: ObjectIdentifier) {
        playbackIDsByUtteranceID.removeValue(forKey: utteranceID)
    }

    private func emit(_ event: SpeechDriverEvent) {
        eventHandler?(event)
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
        var seen: Set<String> = []

        return Locale.preferredLanguages
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { language in
                language == "en" || language.hasPrefix("en-")
            }
            .filter { language in
                seen.insert(language).inserted
            }
    }

    nonisolated private func forwardEvent(
        for utterance: AVSpeechUtterance,
        removesTracking: Bool = false,
        event: @escaping @Sendable (UUID) -> SpeechDriverEvent
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let playbackID = self.playbackID(for: utteranceID) else {
                return
            }

            if removesTracking {
                self.removePlaybackID(for: utteranceID)
            }

            self.emit(event(playbackID))
        }
    }
}

extension AVSpeechBackendDriver: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        forwardEvent(for: utterance, event: SpeechDriverEvent.didStart)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        forwardEvent(for: utterance, removesTracking: true, event: SpeechDriverEvent.didFinish)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        forwardEvent(for: utterance, removesTracking: true, event: SpeechDriverEvent.didFinish)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        forwardEvent(for: utterance, event: SpeechDriverEvent.didPause)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        forwardEvent(for: utterance, event: SpeechDriverEvent.didResume)
    }
}
