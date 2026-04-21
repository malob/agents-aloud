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
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // File > New doesn't apply — this app doesn't create documents.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Playback") {
                Button(playPauseLabel) {
                    togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.speechController.isSpeaking && !model.speechController.isPaused)

                Button("Stop") {
                    model.speechController.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.speechController.isSpeaking && !model.speechController.isPaused)
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 480)
        }
    }

    private var playPauseLabel: String {
        model.speechController.isPaused ? "Resume" : "Pause"
    }

    private func togglePlayPause() {
        if model.speechController.isPaused {
            model.speechController.resume()
        } else if model.speechController.isSpeaking {
            model.speechController.pause()
        }
    }
}
