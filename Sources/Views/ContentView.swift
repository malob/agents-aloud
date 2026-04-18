import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let session = model.selectedSession {
                TranscriptDetailView(model: model, session: session)
                    .id(session.id)
            } else if case .loading = model.sessionsState {
                ContentUnavailableView(
                    "Loading Sessions…",
                    systemImage: "waveform",
                    description: Text("Looking for recent Claude Code sessions.")
                )
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Choose a Claude Code session from the sidebar.")
                )
            }
        }
        .navigationTitle("Claude Code Voice")
        .toolbar {
            if model.selectedSession != nil {
                ToolbarItemGroup(placement: .navigation) {
                    PlaybackControlsView(controller: model.speechController)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                if let errorMessage = model.errorMessage {
                    BannerView(
                        kind: .error,
                        message: errorMessage,
                        onDismiss: model.dismissErrorMessage
                    )
                }

                if let playbackError = model.speechController.playbackError {
                    BannerView(
                        kind: .playback,
                        message: playbackError.message,
                        onDismiss: model.speechController.dismissPlaybackError
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
            .animation(.easeInOut(duration: 0.2), value: model.speechController.playbackError)
        }
    }
}

private struct BannerView: View {
    enum Kind {
        case error
        case playback

        var symbolName: String {
            switch self {
            case .error:
                return "exclamationmark.triangle.fill"
            case .playback:
                return "speaker.slash.fill"
            }
        }

        var helpText: String {
            switch self {
            case .error:
                return "Dismiss error"
            case .playback:
                return "Dismiss playback status"
            }
        }

        var tint: Color {
            switch self {
            case .error:
                return .orange
            case .playback:
                return .red.opacity(0.16)
            }
        }
    }

    let kind: Kind
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbolName)

            Text(message)
                .font(.caption)
                .lineLimit(2)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(kind.helpText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(kind.tint), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
