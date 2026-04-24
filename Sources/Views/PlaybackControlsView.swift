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
                // model.stopPlayback() funnels through the
                // SpeechController so it clears the queue + cancels
                // any in-flight rewrite + stops active audio in one
                // step. Don't route through controller.stop() directly.
                model.stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            // Enabled whenever there's anything to stop — active
            // playback, paused utterance, or anything in the queue
            // (rewriting or pending). Otherwise a user who changed
            // their mind during the 5–10s CLI rewrite window has no
            // way to cancel.
            .disabled(!controller.isSpeaking && !controller.isPaused && !model.isPreparingPlayback)
            .help("Stop speech")
        }
        .labelStyle(.iconOnly)
    }
}
