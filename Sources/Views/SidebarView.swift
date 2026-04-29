import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            sourceFilterPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            List(selection: $model.selectedSessionID) {
                ForEach(model.visibleSessions) { session in
                    SessionRowView(
                        session: session,
                        isSelected: model.selectedSessionID == session.id,
                        isLiveSpeakSession: model.liveReadSessionID == session.id
                    )
                    .tag(Optional(session.id))
                }
            }
            .listStyle(.sidebar)
            .overlay { sidebarStateOverlay }
        }
    }

    // Three-segment filter: All / Claude / Codex. Icons-only with
    // tooltips per macOS HIG guidance for icon-only segmented
    // controls. Bound to `sidebarSourceFilter`; nil = All.
    private var sourceFilterPicker: some View {
        Picker("Source", selection: Binding(
            get: { model.sidebarSourceFilter },
            set: { model.sidebarSourceFilter = $0 }
        )) {
            Image(systemName: "tray.full.fill")
                .help("Show sessions from both Claude and Codex")
                .tag(TranscriptSource?.none)
            ForEach(TranscriptSource.allCases) { source in
                Image(systemName: source.symbolName)
                    .help("Show only \(source.displayName) sessions")
                    .tag(Optional(source))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var sidebarStateOverlay: some View {
        switch model.sessionsState {
        case let .loading(sessions) where sessions.isEmpty:
            ProgressView("Loading sessions…")
        case let .loaded(sessions) where sessions.isEmpty,
            let .failed(sessions, _) where sessions.isEmpty:
            ContentUnavailableView(
                "No Sessions",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Recent Claude Code and Codex sessions will appear here once transcripts are available.")
            )
        default:
            // Filter is set but produced no rows: clearer message
            // than the generic empty state.
            if !model.sessions.isEmpty && model.visibleSessions.isEmpty {
                ContentUnavailableView(
                    "No \(model.sidebarSourceFilter?.displayName ?? "") Sessions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Switch the source filter above to see sessions from the other CLI.")
                )
            } else {
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
                // Source icon on the left — same SF Symbol as the
                // filter picker uses, so the visual mapping is
                // consistent across sidebar surfaces.
                Image(systemName: session.source.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("\(session.source.displayName) session")

                Text(session.summary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Spacer(minLength: 4)

                // Live Speak indicator now on the right edge —
                // makes room for the source icon on the left and
                // gives the live-speak signal its own dedicated
                // visual zone.
                if isLiveSpeakSession {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(liveIndicatorColor)
                        .help("Live Speak is enabled for this session.")
                }
            }

            Text(session.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                // Skip the message-count badge when the source
                // doesn't expose a cheap count (e.g. Codex DB rows).
                if !session.messageCountLabel.isEmpty {
                    SidebarMetadataBadge(text: session.messageCountLabel, systemImage: "text.bubble")
                }

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
