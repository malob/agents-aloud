import SwiftUI

@main
struct AgentsAloudApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Agents Aloud") {
            ContentView(model: model)
                .frame(minWidth: 1020, minHeight: 720)
                .task {
                    await model.start()
                }
                // Space as play/pause via .onKeyPress rather than a
                // menu .keyboardShortcut(.space, modifiers: []) — bare
                // Space as a menu shortcut is intercepted by whatever
                // control is first responder (sidebar List, buttons, etc.)
                // and silently no-ops. onKeyPress bubbles from the first
                // responder and catches Space at the view level.
                .onKeyPress(.space) {
                    guard model.speechController.isSpeaking || model.speechController.isPaused else {
                        return .ignored
                    }
                    togglePlayPause()
                    return .handled
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
        // showsTitle: true so the session's navigationTitle +
        // navigationSubtitle render in the window chrome. An earlier
        // version hid the title because the in-body SessionHeaderView
        // was showing the session name; with that header removed, the
        // native toolbar title area is where identity lives now.
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // File > New doesn't apply — this app doesn't create documents.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Playback") {
                // Menu entry without a keyboard shortcut: Space is handled
                // by the onKeyPress above (menu shortcuts require modifiers
                // on macOS to avoid clobbering text input and first-responder
                // Space handling).
                Button(playPauseLabel) {
                    togglePlayPause()
                }
                .disabled(!model.speechController.isSpeaking && !model.speechController.isPaused)

                Button("Stop") {
                    model.stopPlayback()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(
                    !model.speechController.isSpeaking
                        && !model.speechController.isPaused
                        && !model.isPreparingPlayback
                )
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
