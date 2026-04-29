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

            // Voice picker is only meaningful for ElevenLabs — SystemVoice
            // routes through the voice the user picked in System Settings.
            if model.preferredSpeechBackend == .elevenLabs {
                Section("Voice") {
                    voicePickerForCurrentBackend
                }
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

            if model.speechTextOptimizationMode == .claudeCLI {
                Picker("Model", selection: $model.claudeCLIModel) {
                    ForEach(ClaudeCLIModel.allCases) { claudeModel in
                        Text(claudeModel.displayName).tag(claudeModel)
                    }
                }

                Text(model.claudeCLIModel.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Effort", selection: $model.claudeCLIEffort) {
                    ForEach(ClaudeCLIEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }

                Text(model.claudeCLIEffort.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.speechTextOptimizationMode == .codexCLI {
                Picker("Model", selection: $model.codexCLIModel) {
                    ForEach(CodexCLIModel.allCases) { codexModel in
                        Text(codexModel.displayName).tag(codexModel)
                    }
                }

                Text(model.codexCLIModel.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Effort", selection: $model.codexCLIEffort) {
                    ForEach(CodexCLIEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }

                Text(model.codexCLIEffort.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Verbosity", selection: $model.codexCLIVerbosity) {
                    ForEach(CodexCLIVerbosity.allCases) { verbosity in
                        Text(verbosity.displayName).tag(verbosity)
                    }
                }

                Text(model.codexCLIVerbosity.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        case .codexCLI:
            guard !model.isCodexCLIAvailable else { return nil }
            return "`codex` CLI not found on PATH. Install from developers.openai.com/codex or add its directory to PATH; until then, messages will be spoken unchanged."
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
        // SystemVoice has no app-level voice picker; the parent gates
        // this section so we only render the ElevenLabs branch here.
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

    @ViewBuilder
    private var speechRateSection: some View {
        Section("Speech Rate") {
            // Bound to an Int slider — wpm is the unit the surviving
            // backends share (SystemVoice passes it to `say -r`;
            // ElevenLabs maps it onto its 0.7-1.2 speed). step:25
            // makes the slider feel snappy on macOS where the trackpad
            // gives a fairly fine value resolution otherwise.
            Slider(
                value: Binding(
                    get: { Double(model.preferredWordsPerMinute) },
                    set: { model.preferredWordsPerMinute = Int($0.rounded()) }
                ),
                in: Double(AppModel.minimumWordsPerMinute)...Double(AppModel.maximumWordsPerMinute),
                step: 25
            ) {
                Text("Speech Rate")
            } minimumValueLabel: {
                Text("Slower")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Faster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(model.preferredWordsPerMinute) words / min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.preferredWordsPerMinute != AppModel.defaultWordsPerMinute {
                    Button("Reset to Default") {
                        model.preferredWordsPerMinute = AppModel.defaultWordsPerMinute
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if model.preferredSpeechBackend == .elevenLabs {
                Text("ElevenLabs caps speed at 1.2× — settings above the upper third may sound similar.")
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
