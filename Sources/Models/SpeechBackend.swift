import Foundation

enum SpeechBackend: String, CaseIterable, Identifiable {
    case avSpeech = "av_speech"
    case systemVoice = "system_voice"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .avSpeech:
            return "App Voices"
        case .systemVoice:
            return "System Voice (Experimental)"
        }
    }

    var detailText: String {
        switch self {
        case .avSpeech:
            return "Uses AVSpeechSynthesizer with the app's curated English voice list."
        case .systemVoice:
            return "Routes through macOS system speech with no explicit voice override. If your Read & Speak system voice is a Siri voice, this may piggyback on it on recent macOS versions."
        }
    }

    var supportsVoicePicker: Bool {
        switch self {
        case .avSpeech:
            return true
        case .systemVoice:
            return false
        }
    }
}
