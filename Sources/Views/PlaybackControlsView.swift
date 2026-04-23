import SwiftUI

struct PlaybackControlsView: View {
    let model: AppModel

    private var controller: SpeechController {
        model.speechController
    }

    var body: some View {
        ControlGroup {
            if controller.isPaused {
                Button {
                    controller.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .help("Resume speech")
            } else {
                Button {
                    controller.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(!controller.isSpeaking)
                .help("Pause speech")
            }

            Button {
                // model.stopPlayback() cancels in-flight preprocessing
                // too, so a pending FM refine can't sneak through after
                // the user hit Stop. Don't route through controller.stop()
                // directly.
                model.stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            // Enabled during FM preprocessing too — otherwise a user
            // who changed their mind during the 1-3s refine window has
            // no way to cancel.
            .disabled(!controller.isSpeaking && !controller.isPaused && !model.isPreparingPlayback)
            .help("Stop speech")
        }
        .labelStyle(.iconOnly)
    }
}
