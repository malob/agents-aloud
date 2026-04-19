import AppKit
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
    let onPlay: () -> Void
    let onPlayFromHere: () -> Void

    @State private var isHoveringSpeakButton = false
    @State private var isOptionHeld = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.isActive == rhs.isActive
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

                Text(DateFormatting.messageTimestamp.string(from: message.timestamp))
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
                        Label(
                            useFromHereAction ? "Speak from Here"
                                : isActive ? "Speaking"
                                : "Speak",
                            systemImage: isActive ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
                        )
                        .font(.caption.weight(.medium))
                        .symbolEffect(.variableColor.iterative.reversing, isActive: isActive)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(isActive ? Color.accentColor : Color.accentColor.opacity(0.8))
                    .help(
                        useFromHereAction ? "Speak this message and every message after."
                            : isActive ? "This message is being spoken aloud."
                            : "Speak this assistant message aloud. Hold ⌥ for ‘from here’."
                    )
                    .onHover { hovering in
                        isHoveringSpeakButton = hovering
                        if hovering {
                            // Snapshot the modifier state at hover-start so the
                            // affordance is correct even if Option was held
                            // before the pointer entered the button.
                            isOptionHeld = NSEvent.modifierFlags.contains(.option)
                        }
                    }
                    .onModifierKeysChanged(mask: .option) { _, new in
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
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isActive)
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
