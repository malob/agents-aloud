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

            Button {
                // Skip the currently-playing message. Same surface
                // MPRemoteCommandCenter.nextTrackCommand uses — stops
                // the active utterance and promotes the next ready
                // item from the queue. If the queue is empty it
                // collapses to a stop, matching Music / Podcasts
                // "next track" behavior.
                guard let currentID = controller.currentMessageID else { return }
                controller.cancel(messageID: currentID)
            } label: {
                Label("Next", systemImage: "forward.end.fill")
            }
            // Enabled as long as there's a current message to skip
            // past. Paused utterances are skippable too — the user's
            // "move on from this" intent still maps to cancel-then-
            // advance.
            .disabled(controller.currentMessageID == nil)
            .help("Skip to the next message")
        }
        .labelStyle(.iconOnly)
    }
}
