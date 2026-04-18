import SwiftUI

@main
struct ClaudeCodeVoiceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Claude Code Voice") {
            ContentView(model: model)
                .frame(minWidth: 1020, minHeight: 720)
                .task {
                    await model.start()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView(model: model)
                .frame(width: 480)
        }
    }
}
