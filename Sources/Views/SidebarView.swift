import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    // Drives the source-filter highlight's emphasis so it desaturates
    // with the rest of the window when it resigns key — the hand-rolled
    // button can't inherit the automatic muting native controls get.
    @Environment(\.controlActiveState) private var controlActiveState

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
                        isLiveSpeakSession: model.liveReadSessionIDs.contains(session.id),
                        isCurrentlySpeaking: model.speechController.isSpeaking
                            && model.speechController.currentSessionID == session.id,
                        hasUnseenActivity: model.hasUnseenActivity(session)
                    )
                    .tag(Optional(session.id))
                }
            }
            .listStyle(.sidebar)
            // macOS List preserves its underlying scroll view across
            // filtered data swaps. When the source filter shrinks the
            // list and then expands back to All, that stale scroll
            // offset can leave the first row clipped under the filter
            // control. Remounting per filter gives each scope its own
            // clean initial scroll position.
            .id(model.sidebarSourceFilter?.rawValue ?? "all")
            .overlay { sidebarStateOverlay }
        }
    }

    // Three-segment filter: All / Claude / Codex. Icons-only with
    // tooltips per macOS HIG guidance for icon-only segmented
    // controls. Bound to `sidebarSourceFilter`; nil = All.
    //
    // The "All" segment stays on a system SF Symbol (it's a
    // generic UI affordance, not a brand). The Claude / Codex
    // segments use bundled custom symbols.
    //
    // Hand-rolled rather than `Picker(...).pickerStyle(...)` because
    // both .segmented AND .palette flatten our custom multicolor
    // .symbolset assets through their AppKit bridge:
    //   - .segmented: Claude/Codex render as flat templates tinted
    //     with secondaryLabelColor; in dark mode this desaturates to
    //     a gray smudge.
    //   - .palette (tried 2026-04-29): same template-tinting failure
    //     mode AND path winding gets re-interpreted, so the Codex
    //     hex outline renders as a filled shape instead of hollow.
    // SwiftUI-native plain Buttons sidestep both bridges and
    // preserve symbolRenderingMode(.multicolor) end-to-end. Don't
    // re-spike this without a fresh OS-level test.
    private static let pickerIconSize: CGFloat = 14

    private var sourceFilterPicker: some View {
        HStack(spacing: 2) {
            sourceFilterButton(source: nil) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: Self.pickerIconSize, weight: .medium))
            }
            .help("Show sessions from both Claude and Codex")
            .accessibilityLabel("All sources")

            ForEach(TranscriptSource.allCases) { source in
                sourceFilterButton(source: source) {
                    SourceBrandIcon(
                        source: source,
                        size: Self.pickerIconSize,
                        palette: .adaptive
                    )
                }
                .help("Show only \(source.displayName) sessions")
                .accessibilityLabel(source.displayName)
            }
        }
        .padding(3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // VoiceOver: present the group as a single named control so
        // users hear "Source filter" once instead of three unlabeled
        // buttons. .contain keeps each segment individually focusable
        // (with .isSelected applied to the active one), matching how
        // sidebar toolbar groups read in Mail / Finder.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source filter")
        // Arrow-key cycling within the group, mirroring the native
        // segmented Picker's behavior. Wraps at both ends. Only fires
        // when the focus is on one of our buttons, so it doesn't
        // collide with the List below.
        .onKeyPress(.leftArrow) {
            cycleFilter(direction: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            cycleFilter(direction: 1)
            return .handled
        }
    }

    // Order for arrow-key cycling. Sourced from TranscriptSource.allCases
    // so adding a new source case automatically extends the cycle without
    // touching this file.
    private static let filterCycle: [TranscriptSource?] =
        [nil] + TranscriptSource.allCases.map(Optional.init)

    private func cycleFilter(direction: Int) {
        guard let idx = Self.filterCycle.firstIndex(of: model.sidebarSourceFilter) else { return }
        let count = Self.filterCycle.count
        let next = (idx + direction + count) % count
        model.sidebarSourceFilter = Self.filterCycle[next]
    }

    private func sourceFilterButton<Label: View>(
        source: TranscriptSource?,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let isSelected = model.sidebarSourceFilter == source
        // Match the List row selection: accent fill + white glyph while
        // the window is key, muted gray + primary glyph once it goes
        // inactive. unemphasizedSelectedContentBackgroundColor is the
        // same gray AppKit paints behind an inactive table selection.
        let isEmphasized = controlActiveState != .inactive
        let selectedFill = isEmphasized
            ? Color.accentColor
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

        return Button {
            model.sidebarSourceFilter = source
        } label: {
            label()
                .foregroundStyle(isSelected && isEmphasized ? .white : .primary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedFill)
                    }
                }
        }
        .buttonStyle(.plain)
        // VoiceOver pairs this with the parent's "Source filter" group
        // label so users hear e.g. "Source filter, Claude, selected".
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
    let session: SessionSummary
    let isSelected: Bool
    let isLiveSpeakSession: Bool
    let isCurrentlySpeaking: Bool
    let hasUnseenActivity: Bool

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
                SourceBrandIcon(source: session.source, size: 14)
                    .frame(width: Self.iconColumnWidth, alignment: .leading)
                    .help("\(session.source.displayName) session")

                Text(session.summary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Spacer(minLength: 8)

                // Unseen-activity badge, Mail-style: the session's
                // file advanced since the user last had it selected.
                // Clears the moment the row is clicked (selection is
                // what "seen" means).
                if hasUnseenActivity {
                    Circle()
                        .fill(unseenBadgeColor)
                        .frame(width: 7, height: 7)
                        .help("New activity since you last viewed this session.")
                        .accessibilityLabel("New activity")
                }

                if let modifiedAt = session.modifiedAt {
                    // TimelineView so the label ticks while the app idles.
                    // Rows only re-render when sessionsState actually
                    // changes (refreshSessions skips equal writes), so a
                    // bare Text computed at render time would freeze —
                    // "12s" sat unchanged until some other state moved.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.compactRelative(from: modifiedAt, now: context.date))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }

                // Speaker icon marks Live-Speak-enabled sessions and
                // animates on whichever session is producing audio right
                // now — a glanceable "who's talking" cue for when the
                // spoken "From <session>" callout was missed. Shown for
                // the speaking session even without Live Speak (manual
                // playback): the question it answers is "which session is
                // speaking," not "which will auto-read."
                if isLiveSpeakSession || isCurrentlySpeaking {
                    // Matches the per-message pill (MessageRowView):
                    // two waves when idle, three + a forward variable-
                    // color sweep while actually speaking.
                    Image(systemName: isCurrentlySpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(liveIndicatorColor)
                        .symbolEffect(.variableColor.iterative, isActive: isCurrentlySpeaking)
                        .help(isCurrentlySpeaking
                            ? "Now speaking this session's messages."
                            : "Live Speak is enabled for this session.")
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

    private var unseenBadgeColor: Color {
        isSelected ? .primary : .accentColor
    }
}
