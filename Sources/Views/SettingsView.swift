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
            Picker("Rewriter", selection: $model.speechTextOptimizationMode) {
                ForEach(SpeechTextOptimization.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(model.speechTextOptimizationMode.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Surface availability problems as a second-line hint
            // beneath the picker so users who've selected an unavailable
            // backend understand why playback isn't getting rewritten.
            if let unavailabilityMessage {
                Label(unavailabilityMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var unavailabilityMessage: String? {
        switch model.speechTextOptimizationMode {
        case .off:
            return nil
        case .claudeCLI:
            guard !model.isClaudeCLIAvailable else { return nil }
            return "`claude` CLI not found on PATH. Install from claude.ai/code or add its directory to PATH; until then, messages will be spoken unchanged."
        case .foundationModel:
            switch model.foundationModelAvailability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence. Messages will be spoken unchanged."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence isn't enabled in System Settings. Messages will be spoken unchanged."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading. Messages will be spoken unchanged."
            case .unavailable:
                return "Apple Intelligence is currently unavailable. Messages will be spoken unchanged."
            }
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
