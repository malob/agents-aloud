import SwiftUI

// Chat-style auto-pin-to-bottom via `.defaultScrollAnchor`. Mounts at
// the bottom; re-anchors to bottom on content-size growth only while
// the user is at the bottom — SwiftUI handles the "respect user scroll
// position" contract itself. No manual scroll machinery required.
//
// An earlier iteration of this view hand-rolled the whole pattern
// (ScrollViewReader + onScrollGeometryChange + userSetAtBottom +
// onScrollPhaseChange) around a 2023 LazyVStack bug (Apple DevForums
// thread 741406). As of macOS 26 the simple path just works; dropped
// ~70 lines.
struct TranscriptDetailView: View {
    let model: AppModel
    let session: ClaudeSessionSummary

    private var transcriptMessages: [TranscriptMessage] {
        model.transcriptState.messages(for: session.id)
    }

    private var isLoadingTranscript: Bool {
        model.transcriptState.isLoading(for: session.id)
    }

    private var transcriptErrorMessage: String? {
        model.transcriptState.errorMessage(for: session.id)
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcriptMessages) { message in
                        MessageRowView(
                            message: message,
                            isActive: model.speechController.currentMessageID == message.id,
                            onPlay: { model.playMessage(message) },
                            onPlayFromHere: { model.playMessagesFromHere(message) }
                        )
                        .equatable()
                        .id(message.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.clear)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])

            if isLoadingTranscript {
                ProgressView("Loading transcript…")
                    .controlSize(.regular)
            } else if transcriptMessages.isEmpty {
                if let transcriptErrorMessage {
                    ContentUnavailableView(
                        "Unable to Load Transcript",
                        systemImage: "exclamationmark.triangle",
                        description: Text(transcriptErrorMessage)
                    )
                } else {
                    ContentUnavailableView(
                        "No Speakable Messages Yet",
                        systemImage: "text.word.spacing",
                        description: Text("This view shows your prompts and assistant text messages from the selected Claude session.")
                    )
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            SessionHeaderView(model: model, session: session)
        }
    }
}

private struct SessionHeaderView: View {
    let model: AppModel
    let session: ClaudeSessionSummary
    @Namespace private var glassNamespace

    private var isLiveReadEnabled: Bool {
        model.liveReadSessionID == session.id
    }

    private var selectedTranscriptMessages: [TranscriptMessage] {
        model.transcriptState.messages(for: session.id)
    }

    private var displayedMessageCount: Int {
        model.selectedSessionID == session.id && !selectedTranscriptMessages.isEmpty
            ? selectedTranscriptMessages.count
            : session.messageCount
    }

    private var liveSpeakAppearance: LiveSpeakAppearance {
        LiveSpeakAppearance(isEnabled: isLiveReadEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.summary)
                        .font(.title2.weight(.semibold))

                    Text(session.projectPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Button {
                    model.setLiveReadEnabled(!isLiveReadEnabled)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: liveSpeakAppearance.symbolName)
                            .foregroundStyle(liveSpeakAppearance.iconColor)
                        
                        Text(liveSpeakAppearance.title)
                            .foregroundStyle(.primary)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(liveSpeakAppearance.glass, in: Capsule())
                    .overlay {
                        if liveSpeakAppearance.borderColor != .clear {
                            Capsule()
                                .stroke(liveSpeakAppearance.borderColor, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .controlSize(.large)
                .help(liveSpeakAppearance.helpText)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 8) {
                    if let modifiedAt = session.modifiedAt {
                        SessionStatusBadge(
                            title: modifiedAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock"
                        )
                        .glassEffectID("updated-at", in: glassNamespace)
                    }

                    SessionStatusBadge(
                        title: messageCountText(displayedMessageCount),
                        systemImage: "text.bubble"
                    )
                    .glassEffectID("message-count", in: glassNamespace)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func messageCountText(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }
}

private struct LiveSpeakAppearance {
    let title: String
    let symbolName: String
    let helpText: String
    let iconColor: Color
    let glass: Glass
    let borderColor: Color

    init(isEnabled: Bool) {
        title = isEnabled ? "Live Speak On" : "Start Live Speak"
        symbolName = isEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
        helpText = isEnabled
            ? "Stop automatically speaking new assistant messages for this session."
            : "Automatically speak new assistant messages for this session."
        iconColor = isEnabled ? .accentColor : .secondary
        glass = isEnabled ? .regular.tint(.accentColor.opacity(0.18)).interactive() : .regular.interactive()
        borderColor = isEnabled ? .accentColor.opacity(0.28) : .clear
    }
}

private struct SessionStatusBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .lineLimit(1)
    }
}
