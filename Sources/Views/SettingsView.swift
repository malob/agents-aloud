import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Speech Engine") {
                Picker(
                    "Engine",
                    selection: Binding(
                        get: { model.preferredSpeechBackend },
                        set: { model.preferredSpeechBackend = $0 }
                    )
                ) {
                    ForEach(SpeechBackend.allCases) { backend in
                        Text(backend.displayName)
                            .tag(backend)
                    }
                }

                Text(model.preferredSpeechBackend.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.preferredSpeechBackend.supportsVoicePicker {
                Section("Voice") {
                    Picker(
                        "Preferred Voice",
                        selection: Binding(
                            get: { model.preferredVoiceIdentifier ?? "" },
                            set: { model.preferredVoiceIdentifier = $0 }
                        )
                    ) {
                        ForEach(model.speechController.availableVoices) { voice in
                            Text(voice.displayName)
                                .tag(voice.id)
                        }
                    }

                    Text("English voices only for now. Showing Apple’s modern system voices and hiding legacy Eloquence and novelty voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Voice") {
                    Text("This engine ignores the app voice picker and uses the voice you set in macOS Accessibility > Read & Speak > System Voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.preferredSpeechBackend == .avSpeech {
                Section("Speech Rate") {
                    Slider(
                        value: Binding(
                            get: { model.preferredSpeechRate },
                            set: { model.preferredSpeechRate = $0 }
                        ),
                        in: 0.2...0.6
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
