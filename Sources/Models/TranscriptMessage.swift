import Foundation

struct TranscriptMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let timestamp: Date
    let sessionID: String

    var isAssistant: Bool {
        role == .assistant
    }
}
