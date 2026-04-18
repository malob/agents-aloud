import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let session = model.selectedSession {
                TranscriptDetailView(model: model, session: session)
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
                    ErrorBannerView(
                        message: errorMessage,
                        onDismiss: model.dismissErrorMessage
                    )
                }

                if let playbackError = model.speechController.playbackError {
                    PlaybackErrorToastView(
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

private struct PlaybackErrorToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash.fill")

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
            .help("Dismiss playback status")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.red.opacity(0.16)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
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
            .help("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
