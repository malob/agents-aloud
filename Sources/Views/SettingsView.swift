import AVFoundation
import FoundationModels
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var apiKeyDraft: String = ""
    @FocusState private var apiKeyFocused: Bool

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

            if model.preferredSpeechBackend == .elevenLabs {
                elevenLabsAPIKeySection
            }

            Section("Voice") {
                voicePickerForCurrentBackend
            }

            speechRateSection
            speechOptimizationSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKeyDraft = model.elevenLabsAPIKey ?? ""
        }
    }

    @ViewBuilder
    private var speechOptimizationSection: some View {
        Section("Speech Text Optimization") {
            Toggle(
                "Rewrite messages for speech (Apple Intelligence)",
                isOn: $model.speechTextOptimizationEnabled
            )
            .disabled(!isSpeechOptimizationAvailable)

            Text(speechOptimizationHelperText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isSpeechOptimizationAvailable: Bool {
        if case .available = model.speechTextOptimizationAvailability {
            return true
        }
        return false
    }

    private var speechOptimizationHelperText: String {
        switch model.speechTextOptimizationAvailability {
        case .available:
            return "Rewrites code blocks, tables, and dense structures into speech-friendly prose before playback. Runs entirely on-device. Adds about 1–3 seconds of latency per message the first time it's spoken."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, so on-device speech optimization isn't available."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri to enable on-device speech optimization."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Speech optimization will become available once it's ready."
        case .unavailable:
            return "On-device speech optimization isn't available right now."
        }
    }

    private var elevenLabsAPIKeySection: some View {
        Section("API Key") {
            SecureField("ElevenLabs API Key", text: $apiKeyDraft, prompt: Text("sk_…"))
                .textFieldStyle(.roundedBorder)
                .focused($apiKeyFocused)
                .onSubmit { saveAPIKey() }
                .onChange(of: apiKeyFocused) { _, focused in
                    if !focused {
                        saveAPIKey()
                    }
                }

            Text("Stored in the macOS Keychain. Press Return or click away to save.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voicePickerForCurrentBackend: some View {
        switch model.preferredSpeechBackend {
        case .avSpeech:
            Picker("Preferred Voice", selection: $model.preferredVoiceIdentifier) {
                ForEach(model.speechController.availableVoices) { voice in
                    Text(voice.displayName)
                        .tag(Optional(voice.id))
                }
            }

            Text("English voices only for now. Showing Apple’s modern system voices and hiding legacy Eloquence and novelty voices.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .systemVoice:
            Text("This engine ignores the app voice picker and uses the voice you set in macOS Accessibility > Read & Speak > System Voice.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .elevenLabs:
            let voices = model.speechController.availableVoices
            if voices.isEmpty {
                Text(model.elevenLabsAPIKey?.isEmpty == false
                     ? "Voices couldn’t be loaded — check your API key or your network connection."
                     : "Enter an API key above to load your ElevenLabs voices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: $model.preferredElevenLabsVoiceID) {
                    ForEach(voices) { voice in
                        Text(voice.name)
                            .tag(Optional(voice.id))
                    }
                }

                Text("Voices come from your ElevenLabs account. Create or clone more at elevenlabs.io.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var speechRateSection: some View {
        switch model.preferredSpeechBackend {
        case .avSpeech, .elevenLabs:
            Section("Speech Rate") {
                Slider(
                    value: $model.preferredSpeechRate,
                    in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                )

                Text(String(format: "Current rate: %.2f", model.preferredSpeechRate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .systemVoice:
            Section("Speech Rate") {
                Text("System Voice currently uses `say -r \(model.speechController.systemVoiceWordsPerMinute)`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard newValue != model.elevenLabsAPIKey else {
            return
        }

        model.elevenLabsAPIKey = newValue
    }
}
