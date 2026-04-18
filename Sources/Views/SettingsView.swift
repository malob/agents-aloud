import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Speech Engine") {
                Picker("Engine", selection: $model.preferredSpeechBackend) {
                    ForEach(SpeechBackend.allCases) { backend in
                        Text(backend.displayName)
                            .tag(backend)
                    }
                }

                Text(model.preferredSpeechBackend.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                if model.preferredSpeechBackend.supportsVoicePicker {
                    Picker("Preferred Voice", selection: $model.preferredVoiceIdentifier) {
                        ForEach(model.speechController.availableVoices) { voice in
                            Text(voice.displayName)
                                .tag(Optional(voice.id))
                        }
                    }

                    Text("English voices only for now. Showing Apple’s modern system voices and hiding legacy Eloquence and novelty voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This engine ignores the app voice picker and uses the voice you set in macOS Accessibility > Read & Speak > System Voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.preferredSpeechBackend == .avSpeech {
                Section("Speech Rate") {
                    Slider(
                        value: $model.preferredSpeechRate,
                        in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                    )

                    Text(String(format: "Current rate: %.2f", model.preferredSpeechRate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Speech Rate") {
                    Text("System Voice currently uses `say -r \(model.speechController.systemVoiceWordsPerMinute)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
