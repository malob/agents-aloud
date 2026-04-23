import SwiftUI

// Equatable + `.equatable()` at the call site lets SwiftUI skip re-rendering
// unchanged rows when the parent invalidates — required for smooth scroll
// perf with long transcripts. The custom `==` deliberately ignores `onPlay`
// (closures aren't Equatable and its identity changes on every parent body
// eval); message identity + active state determine whether the row needs to
// redraw.
@MainActor
struct MessageRowView: View, Equatable {
    let message: TranscriptMessage
    let isActive: Bool
    let isPreparing: Bool
    let onPlay: () -> Void
    let onPlayFromHere: () -> Void

    @State private var isHoveringSpeakButton = false
    @State private var isOptionHeld = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.isActive == rhs.isActive
            && lhs.isPreparing == rhs.isPreparing
    }

    private var roleAppearance: RoleAppearance {
        RoleAppearance(role: message.role)
    }

    // When the user hovers the Speak button with Option held, the button
    // offers the batch action instead of single-message playback.
    private var useFromHereAction: Bool {
        isHoveringSpeakButton && isOptionHeld
    }

    // Border and tinted button foreground apply whenever the row is
    // "owning attention" — actively speaking, or being rewritten in
    // preparation to speak.
    private var isHighlighted: Bool {
        isActive || isPreparing
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
                    Button {
                        if useFromHereAction {
                            onPlayFromHere()
                        } else {
                            onPlay()
                        }
                    } label: {
                        Label(speakButtonTitle, systemImage: speakButtonIcon)
                            .font(.caption.weight(.medium))
                            .symbolEffect(
                                .variableColor.iterative.reversing,
                                isActive: isActive || isPreparing
                            )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.8))
                    .help(speakButtonHelp)
                    .onHover { hovering in
                        isHoveringSpeakButton = hovering
                    }
                    // initial: true seeds isOptionHeld with the current modifier
                    // state on view appear — handles the case where Option is
                    // already held before the pointer enters the button, so we
                    // don't need NSEvent.modifierFlags peeks from view code.
                    .onModifierKeysChanged(mask: .option, initial: true) { _, new in
                        isOptionHeld = new.contains(.option)
                    }
                }
            }

            TranscriptMarkdownView(
                content: message.content
            )
                .equatable()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(roleAppearance.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isHighlighted)
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

    // Label-precedence order: hover-override first (so Option+hover
    // always wins), then preparing (because preparing implies the user
    // just clicked and deserves immediate feedback), then speaking, else
    // idle. Never both "Speaking" and "Rewriting…" on the same row —
    // preparing clears as soon as the TTS engine fires .didStart.
    private var speakButtonTitle: String {
        if useFromHereAction { return "Speak from Here" }
        if isPreparing { return "Rewriting…" }
        if isActive { return "Speaking" }
        return "Speak"
    }

    private var speakButtonIcon: String {
        if isPreparing { return "wand.and.sparkles" }
        if isActive { return "speaker.wave.3.fill" }
        return "speaker.wave.2.fill"
    }

    private var speakButtonHelp: String {
        if useFromHereAction { return "Speak this message and every message after." }
        if isPreparing { return "Rewriting this message for speech before playback." }
        if isActive { return "This message is being spoken aloud." }
        return "Speak this assistant message aloud. Hold ⌥ for ‘from here’."
    }

    private func copyMessageText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
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

#Preview("MessageRowView — idle / preparing / speaking") {
    VStack(spacing: 0) {
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-user",
                role: .user,
                text: "What does SpeechController do when the user switches backend mid-playback?",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            isActive: false,
            isPreparing: false,
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-assistant-preparing",
                role: .assistant,
                text: "It stops the outgoing driver and drops the queue. The new backend starts clean.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            isActive: false,
            isPreparing: true,  // show the "Rewriting…" label + border
            onPlay: {},
            onPlayFromHere: {}
        )
        MessageRowView(
            message: TranscriptMessage(
                id: "preview-assistant-active",
                role: .assistant,
                text: "Once the driver acknowledges .didStart the preparing state clears and the row flips to Speaking.",
                timestamp: .now,
                sessionID: "preview-session"
            ),
            isActive: true,
            isPreparing: false,
            onPlay: {},
            onPlayFromHere: {}
        )
    }
    .padding()
    .frame(width: 720)
}
