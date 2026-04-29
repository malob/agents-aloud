import Foundation

struct SpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String

    var displayName: String {
        let localeIdentifier = language.replacingOccurrences(of: "-", with: "_")
        let languageDescription = Locale.current.localizedString(forIdentifier: localeIdentifier) ?? language
        return "\(name) (\(languageDescription))"
    }
}
