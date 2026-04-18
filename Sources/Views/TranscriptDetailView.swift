import SwiftUI

struct TranscriptDetailView: View {
    let model: AppModel
    let session: ClaudeSessionSummary
    @State private var pendingInitialScrollSessionID: ClaudeSessionSummary.ID?
    @State private var scrolledMessageID: TranscriptMessage.ID?

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.transcriptMessages) { message in
                        MessageRowView(message: message) {
                            model.playMessage(message)
                        }
                        .id(message.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
            }
            .id(session.id)
            .background(.clear)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition(id: $scrolledMessageID, anchor: .bottom)
            .onAppear {
                pendingInitialScrollSessionID = session.id

                if model.selectedSessionID == session.id,
                   let latestMessageID = model.transcriptMessages.last?.id {
                    scrollToMessage(latestMessageID)
                }
            }
            .onChange(of: model.transcriptMessages.map(\.id)) { oldIDs, newIDs in
                let previousLastMessageID = oldIDs.last
                let latestMessageID = newIDs.last
                let appendedMessagesAtEnd =
                    !oldIDs.isEmpty &&
                    newIDs.count > oldIDs.count &&
                    Array(newIDs.prefix(oldIDs.count)) == oldIDs
                let wasPinnedToBottom = previousLastMessageID != nil && scrolledMessageID == previousLastMessageID

                if pendingInitialScrollSessionID == session.id {
                    scrollToMessage(latestMessageID)
                } else if appendedMessagesAtEnd && wasPinnedToBottom {
                    scrollToMessage(latestMessageID)
                }
            }
            .onChange(of: session.id) { _, newSessionID in
                pendingInitialScrollSessionID = newSessionID
                scrolledMessageID = nil
            }

            if model.isLoadingTranscript {
                ProgressView("Loading transcript…")
                    .controlSize(.regular)
            } else if model.transcriptMessages.isEmpty {
                ContentUnavailableView(
                    "No Speakable Messages Yet",
                    systemImage: "text.word.spacing",
                    description: Text("This view shows your prompts and assistant text messages from the selected Claude session.")
                )
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            SessionHeaderView(model: model, session: session)
        }
    }

    private func scrollToMessage(_ messageID: TranscriptMessage.ID?) {
        scrolledMessageID = messageID

        if pendingInitialScrollSessionID == session.id {
            pendingInitialScrollSessionID = nil
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

    private var displayedMessageCount: Int {
        model.selectedSessionID == session.id && !model.transcriptMessages.isEmpty
            ? model.transcriptMessages.count
            : session.messageCount
    }

    private let liveSpeakButtonWidth: CGFloat = 188
    
    private var liveSpeakTitle: String {
        isLiveReadEnabled ? "Live Speak On" : "Start Live Speak"
    }
    
    private var liveSpeakSymbolName: String {
        isLiveReadEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
    }
    
    private var liveSpeakHelpText: String {
        isLiveReadEnabled
            ? "Stop automatically speaking new assistant messages for this session."
            : "Automatically speak new assistant messages for this session."
    }
    
    private var liveSpeakIconColor: Color {
        isLiveReadEnabled ? .accentColor : .secondary
    }
    
    private var liveSpeakGlass: Glass {
        if isLiveReadEnabled {
            return .regular.tint(.accentColor.opacity(0.18)).interactive()
        }
        
        return .regular.interactive()
    }
    
    private var liveSpeakBorderColor: Color {
        isLiveReadEnabled ? .accentColor.opacity(0.28) : .white.opacity(0)
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
                        Image(systemName: liveSpeakSymbolName)
                            .foregroundStyle(liveSpeakIconColor)
                        
                        Text(liveSpeakTitle)
                            .foregroundStyle(.primary)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(width: liveSpeakButtonWidth)
                    .glassEffect(liveSpeakGlass, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(liveSpeakBorderColor, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .controlSize(.large)
                .help(liveSpeakHelpText)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 8) {
                    if let modifiedAt = session.modifiedAt {
                        SessionStatusBadge(
                            title: DateFormatting.sessionTimestamp.string(from: modifiedAt),
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
