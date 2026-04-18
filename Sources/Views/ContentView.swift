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
    }
}
