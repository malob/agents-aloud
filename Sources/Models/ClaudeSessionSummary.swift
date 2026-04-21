import Foundation

struct ClaudeSessionSummary: Identifiable, Hashable {
    let id: String
    let summary: String
    let firstPrompt: String?
    let modifiedAt: Date?
    let projectPath: String
    let transcriptURL: URL
    let messageCount: Int

    var projectName: String {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "Unknown Project"
        }

        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }

    var messageCountLabel: String {
        messageCount == 1 ? "1 msg" : "\(messageCount) msgs"
    }
}
