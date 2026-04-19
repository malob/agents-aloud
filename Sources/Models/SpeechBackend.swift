import Foundation

enum SpeechBackend: String, CaseIterable, Identifiable {
    case avSpeech = "av_speech"
    case systemVoice = "system_voice"
    case elevenLabs = "eleven_labs"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .avSpeech:
            return "App Voices"
        case .systemVoice:
            return "System Voice (Experimental)"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    var detailText: String {
        switch self {
        case .avSpeech:
            return "Uses AVSpeechSynthesizer with the app's curated English voice list."
        case .systemVoice:
            return "Routes through macOS system speech with no explicit voice override. If your Read & Speak system voice is a Siri voice, this may piggyback on it on recent macOS versions."
        case .elevenLabs:
            return "Streams cloud TTS from ElevenLabs. Requires an API key (configured below)."
        }
    }

    var supportsVoicePicker: Bool {
        switch self {
        case .avSpeech, .elevenLabs:
            return true
        case .systemVoice:
            return false
        }
    }
}
