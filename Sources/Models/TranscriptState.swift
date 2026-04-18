import Foundation

enum TranscriptState: Equatable {
    case none
    case loading(sessionID: ClaudeSessionSummary.ID, messages: [TranscriptMessage])
    case loaded(sessionID: ClaudeSessionSummary.ID, messages: [TranscriptMessage])
    case failed(sessionID: ClaudeSessionSummary.ID, messages: [TranscriptMessage], message: String)

    var sessionID: ClaudeSessionSummary.ID? {
        switch self {
        case .none:
            return nil
        case let .loading(sessionID, _),
            let .loaded(sessionID, _),
            let .failed(sessionID, _, _):
            return sessionID
        }
    }

    var messages: [TranscriptMessage] {
        switch self {
        case .none:
            return []
        case let .loading(_, messages),
            let .loaded(_, messages),
            let .failed(_, messages, _):
            return messages
        }
    }

    func messages(for sessionID: ClaudeSessionSummary.ID) -> [TranscriptMessage] {
        self.sessionID == sessionID ? messages : []
    }

    func isLoading(for sessionID: ClaudeSessionSummary.ID) -> Bool {
        if case let .loading(currentSessionID, _) = self {
            return currentSessionID == sessionID
        }

        return false
    }

    func errorMessage(for sessionID: ClaudeSessionSummary.ID) -> String? {
        if case let .failed(currentSessionID, _, message) = self,
           currentSessionID == sessionID {
            return message
        }

        return nil
    }
}
