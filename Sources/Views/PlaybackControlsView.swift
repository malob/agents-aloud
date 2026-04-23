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
            .disabled(!controller.isSpeaking && !controller.isPaused)
            .help("Stop speech")
        }
        .labelStyle(.iconOnly)
    }
}
