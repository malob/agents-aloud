import Foundation

enum SpeechBackend: String, CaseIterable, Identifiable {
    case systemVoice = "system_voice"
    case elevenLabs = "eleven_labs"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .systemVoice:
            return "System Voice"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    var detailText: String {
        switch self {
        case .systemVoice:
            return "Routes through macOS system speech using the voice you set in System Settings → Accessibility → Spoken Content. Local, free, and instant-start."
        case .elevenLabs:
            return "Streams cloud TTS from ElevenLabs. Requires an API key (configured below)."
        }
    }

    var supportsVoicePicker: Bool {
        switch self {
        case .systemVoice:
            return false
        case .elevenLabs:
            return true
        }
    }
}
