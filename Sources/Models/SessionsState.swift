import Foundation

enum SessionsState: Equatable {
    case loading([SessionSummary])
    case loaded([SessionSummary])
    case failed([SessionSummary], message: String)

    var sessions: [SessionSummary] {
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
}
