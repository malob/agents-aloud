import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let session = model.selectedSession {
                TranscriptDetailView(model: model, session: session)
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
            if let errorMessage = model.errorMessage {
                ErrorBannerView(message: errorMessage)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
    }
}

private struct ErrorBannerView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
