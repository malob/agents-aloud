import Foundation

struct TranscriptMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
        case user
        case assistant
    }

    enum Content: Hashable {
        case literal(String)
        case plainText(String)
        case markdown(String)

        var text: String {
            switch self {
            case let .literal(text), let .plainText(text), let .markdown(text):
                return text
            }
        }
    }

    let id: String
    let role: Role
    let content: Content
    let timestamp: Date
    let sessionID: String

    var text: String {
        content.text
    }

    var isAssistant: Bool {
        role == .assistant
    }
}
