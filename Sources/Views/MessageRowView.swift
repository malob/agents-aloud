import AppKit
import SwiftUI

@MainActor
struct MessageRowView: View, Equatable {
    let message: TranscriptMessage
    let onPlay: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }

    private var roleAppearance: RoleAppearance {
        RoleAppearance(role: message.role)
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
                    Button(action: onPlay) {
                        Label("Speak", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Speak this assistant message aloud.")
                }
            }

            TranscriptMarkdownView(
                content: message.content
            )
                .equatable()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(roleAppearance.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    Button("Copy Message") {
                        copyMessageText()
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
