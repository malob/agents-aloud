import SwiftUI

// Equatable + `.equatable()` at the call site lets SwiftUI skip re-rendering
// unchanged rows when the parent invalidates — required for smooth scroll
// perf with long transcripts. The custom `==` deliberately ignores `onPlay`
// (closures aren't Equatable and its identity changes on every parent body
// eval); message identity + status determine whether the row needs to
// redraw.
@MainActor
struct MessageRowView: View, Equatable {
    let message: TranscriptMessage
    let status: SpeechController.MessageStatus
    let onPlay: () -> Void
    let onPlayFromHere: () -> Void

    @State private var isHoveringSpeakButton = false
    @State private var isOptionHeld = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.status == rhs.status
    }

    private var roleAppearance: RoleAppearance {
        RoleAppearance(role: message.role)
    }

    // When the user hovers the Speak button with Option held, the button
    // offers the batch action instead of single-message playback.
    private var useFromHereAction: Bool {
        isHoveringSpeakButton && isOptionHeld
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(roleAppearance.title, systemImage: roleAppearance.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleAppearance.color)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if message.isAssistant {
                    statusAffordance
                }
            }

            TranscriptMarkdownView(
                content: message.content
            )
                .equatable()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(roleAppearance.background)
                        if case .speaking = status {
                            // Subtle accent tint layered on top of the
                            // role background — makes the speaking row
                            // visibly "the one you're listening to"
                            // without painting the whole transcript blue.
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.08))
                        }
                    }
                }
                .overlay {
                    if showBorder {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showBorder)
                .contextMenu {
                    Button("Copy Message") {
                        copyMessageText()
                    }
                    Button("Speak from Here", systemImage: "speaker.wave.2.fill") {
                        onPlayFromHere()
                    }
                }
        }
    }

    // The right-corner affordance. Idle rows render a plain Speak
    // button; any other status renders a pill showing the queue state.
    // When Option is held while hovering the button, the action flips
    // to "Speak from Here" — hover override trumps the current status.
    @ViewBuilder
    private var statusAffordance: some View {
        if case .idle = status, !useFromHereAction {
            Button(action: onPlay) {
                Label("Speak", systemImage: "speaker.wave.2.fill")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(Color.accentColor.opacity(0.8))
            .help("Speak this assistant message aloud. Hold ⌥ for ‘from here’.")
            .onHover { isHoveringSpeakButton = $0 }
            .onModifierKeysChanged(mask: .option, initial: true) { _, new in
                isOptionHeld = new.contains(.option)
            }
        } else {
            statusPill
        }
    }

    // Glass-capsule pill used for all non-idle row states (rewriting,
    // queued, up-next, speaking) and for the Option-hover "Speak from
    // Here" override. Uses the same glassEffect + capsule pattern as
    // the toolbar Live Speak indicator, scaled down for a row.
    @ViewBuilder
    private var statusPill: some View {
        Button {
            if useFromHereAction { onPlayFromHere() } else { onPlay() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pillIcon)
                    .symbolEffect(
                        .variableColor.iterative.reversing,
                        isActive: pillShouldAnimateIcon
                    )
                    .foregroundStyle(pillAccent ? Color.accentColor : .secondary)
                Text(pillTitle)
                    .foregroundStyle(pillAccent ? .primary : .secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .overlay {
                if pillAccent {
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(pillHelp)
        .onHover { isHoveringSpeakButton = $0 }
        .onModifierKeysChanged(mask: .option, initial: true) { _, new in
            isOptionHeld = new.contains(.option)
        }
    }

    // MARK: - Pill content derivation

    // Option-hover "Speak from Here" override always wins over the
    // current status — it's the most immediate user intent.
    private var pillTitle: String {
        if useFromHereAction { return "Speak from Here" }
        switch status {
        case .idle: return "Speak"  // shouldn't render via pill, but safe default
        case .rewriting: return "Rewriting…"
        case .speaking: return "Speaking"
        case .queued(let position):
            return position == 0 ? "Up next" : Self.ordinal(position + 1) + " in queue"
        }
    }

    private var pillIcon: String {
        if useFromHereAction { return "forward.fill" }
        switch status {
        case .idle: return "speaker.wave.2.fill"
        case .rewriting: return "wand.and.sparkles"
        case .speaking: return "speaker.wave.3.fill"
        case .queued: return "text.line.first.and.arrowtriangle.forward"
        }
    }

    private var pillHelp: String {
        if useFromHereAction { return "Speak this message and every message after." }
        switch status {
        case .idle: return "Speak this assistant message aloud. Hold ⌥ for ‘from here’."
        case .rewriting: return "Rewriting this message for speech before playback."
        case .speaking: return "This message is being spoken aloud."
        case .queued(let position):
            if position == 0 { return "This message will play after the current one." }
            return "This message is \(Self.ordinal(position + 1)) in the queue."
        }
    }

    // Accent styling for "in motion" states (actively rewriting or
    // speaking, plus the hover override); muted secondary for the
    // "waiting in line" states.
    private var pillAccent: Bool {
        if useFromHereAction { return true }
        switch status {
        case .rewriting, .speaking: return true
        case .queued, .idle: return false
        }
    }

    private var pillShouldAnimateIcon: Bool {
        switch status {
        case .rewriting, .speaking: return true
        case .queued, .idle: return false
        }
    }

    // MARK: - Body border

    // Border shows for both rewriting and speaking — "something is
    // actively happening for this row." Queued rows stay borderless;
    // the pill carries their signal.
    private var showBorder: Bool {
        switch status {
        case .rewriting, .speaking: return true
        case .queued, .idle: return false
        }
    }

    // MARK: - Helpers

    private func copyMessageText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // Use a fresh NumberFormatter per call — allocation is microseconds
    // and avoiding the static side-steps the @MainActor isolation we'd
    // otherwise have to thread through the Equatable / nonisolated path.
    private static func ordinal(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct RoleAppearance {
    let title: String
    let symbolName: String
    let color: Color
    let background: Color

    init(role: TranscriptMessage.Role) {
        switch role {
        case .user:
            title = "You"
            symbolName = "person"
            color = .secondary
            background = Color.secondary.opacity(0.08)
        case .assistant:
            title = "Assistant"
            symbolName = "waveform"
            color = .accentColor
            background = Color.secondary.opacity(0.14)
        }
    }
}

#Preview("MessageRowView — all states") {
    VStack(spacing: 0) {
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-user",
                role: .user,
                text: "What does SpeechController do when the user switches backend mid-playback?",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            status: .idle,
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-rewriting",
                role: .assistant,
                text: "Being rewritten before playback.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            status: .rewriting,
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-speaking",
                role: .assistant,
                text: "This one is currently speaking.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            status: .speaking,
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-upnext",
                role: .assistant,
                text: "Up next after the currently speaking one.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            status: .queued(position: 0),
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-queued-3",
                role: .assistant,
                text: "Third in line.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            status: .queued(position: 2),
            onPlay: {},
            onPlayFromHere: {}
        )
    }
    .padding()
    .frame(width: 720)
}
