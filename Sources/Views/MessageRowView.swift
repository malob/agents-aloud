import AppKit
import SwiftUI

struct MessageRowView: View {
    let message: TranscriptMessage
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(roleTitle, systemImage: roleSymbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)

                Text(DateFormatting.messageTimestamp.string(from: message.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if message.isAssistant {
                    Button(action: onPlay) {
                        Label("Listen", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Read this assistant message aloud.")
                }
            }

            Text(message.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(roleBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    Button("Copy Message") {
                        copyMessageText()
                    }
                }
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        }
    }

    private var roleSymbolName: String {
        switch message.role {
        case .user:
            return "person"
        case .assistant:
            return "waveform"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            return .secondary
        case .assistant:
            return .accentColor
        }
    }

    private var roleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(.quinary)
        case .assistant:
            return AnyShapeStyle(.quaternary)
        }
    }

    private func copyMessageText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}
