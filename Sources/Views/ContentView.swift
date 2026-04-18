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
        .searchable(
            text: Binding(
                get: { model.searchQuery },
                set: { model.searchQuery = $0 }
            ),
            placement: .toolbar,
            prompt: "Search sessions and transcript"
        )
        .navigationTitle("Claude Code Voice")
        .toolbar {
            if model.selectedSession != nil {
                ToolbarItem(placement: .automatic) {
                    PlaybackControlsView(controller: model.speechController)
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .automatic) {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Open speech and playback settings.")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}
