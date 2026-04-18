import Foundation

enum SessionsState: Equatable {
    case loading([ClaudeSessionSummary])
    case loaded([ClaudeSessionSummary])
    case failed([ClaudeSessionSummary], message: String)

    var sessions: [ClaudeSessionSummary] {
        switch self {
        case let .loading(sessions), let .loaded(sessions), let .failed(sessions, _):
            return sessions
        }
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }

        return false
    }

    var errorMessage: String? {
        if case let .failed(_, message) = self {
            return message
        }

        return nil
    }
}
