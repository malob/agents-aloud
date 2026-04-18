import Foundation

struct TranscriptMessage: Identifiable, Hashable {
    enum RenderingMode: String, Hashable {
        case literal
        case plainText
        case markdown
    }

    enum Role: String, Hashable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let renderingMode: RenderingMode
    let timestamp: Date
    let sessionID: String

    var isAssistant: Bool {
        role == .assistant
    }
}
