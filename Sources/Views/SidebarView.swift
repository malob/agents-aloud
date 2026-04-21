import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSessionID) {
            ForEach(model.sessions) { session in
                SessionRowView(
                    session: session,
                    isSelected: model.selectedSessionID == session.id,
                    isLiveSpeakSession: model.liveReadSessionID == session.id
                )
                .tag(Optional(session.id))
            }
        }
        .listStyle(.sidebar)
        .overlay {
            switch model.sessionsState {
            case let .loading(sessions) where sessions.isEmpty:
                ProgressView("Loading Claude sessions…")
            case let .loaded(sessions) where sessions.isEmpty,
                let .failed(sessions, _) where sessions.isEmpty:
                ContentUnavailableView(
                    "No Claude Sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Recent Claude Code sessions will appear here once transcripts are available.")
                )
            default:
                EmptyView()
            }
        }
    }
}

private struct SessionRowView: View {
    let session: ClaudeSessionSummary
    let isSelected: Bool
    let isLiveSpeakSession: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isLiveSpeakSession {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(liveIndicatorColor)
                        .help("Live Speak is enabled for this session.")
                }

                Text(session.summary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }

            Text(session.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                SidebarMetadataBadge(text: session.messageCountLabel, systemImage: "text.bubble")

                if let modifiedAt = session.modifiedAt {
                    SidebarMetadataBadge(
                        text: modifiedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)),
                        systemImage: "clock"
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var liveIndicatorColor: some ShapeStyle {
        if isSelected {
            return Color.primary
        }

        return Color.accentColor
    }
}

private struct SidebarMetadataBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quinary, in: Capsule())
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}
