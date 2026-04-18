import SwiftUI

struct PlaybackControlsView: View {
    let controller: SpeechController

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
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!controller.isSpeaking && !controller.isPaused)
            .help("Stop speech")
        }
        .labelStyle(.iconOnly)
    }
}
