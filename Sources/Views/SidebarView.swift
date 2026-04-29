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

    // Width of the source-icon column on the title row. We pin this
    // explicitly so the project text on row 2 can use the same value
    // for its leading padding and the two rows align perfectly. Pure
    // SF-Symbol intrinsic widths vary per glyph (sparkles is narrower
    // than bubble.left.and.bubble.right.fill), so without this the
    // project line would shift left or right by a couple of points
    // per source.
    private static let iconColumnWidth: CGFloat = 16
    private static let iconTitleSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Row 1: source icon, title, time (right-aligned),
            // optional live-speak indicator. Time anchors to the
            // row's right edge regardless of title length, so all
            // times line up vertically when scanning the sidebar
            // — Mail-style. firstTextBaseline keeps the time
            // glued to the title's first line even when the title
            // wraps to two lines.
            HStack(alignment: .firstTextBaseline, spacing: Self.iconTitleSpacing) {
                Image(systemName: session.source.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth, alignment: .leading)
                    .help("\(session.source.displayName) session")

                Text(session.summary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let modifiedAt = session.modifiedAt {
                    Text(Self.compactRelative(from: modifiedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if isLiveSpeakSession {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(liveIndicatorColor)
                        .help("Live Speak is enabled for this session.")
                }
            }

            // Row 2: project name only, indented to align with the
            // title (skip past the source-icon column).
            Text(session.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Self.iconColumnWidth + Self.iconTitleSpacing)
        }
        .padding(.vertical, 4)
    }

    // Compact relative-time formatter. "5s" / "3m" / "4h" / "5d".
    // Lowercase, no space, no "ago" — the sidebar context makes
    // "ago" implicit. Preferred over Foundation's .abbreviated
    // RelativeDateTimeFormatter because that produces "5 sec. ago"
    // / "4 hr. ago" with periods + spaces + ago, which fights
    // visual density.
    private static func compactRelative(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private var liveIndicatorColor: some ShapeStyle {
        if isSelected {
            return Color.primary
        }

        return Color.accentColor
    }
}
