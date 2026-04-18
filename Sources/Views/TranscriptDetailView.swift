import SwiftUI

struct TranscriptDetailView: View {
    let model: AppModel
    let session: ClaudeSessionSummary
    @State private var pendingInitialScrollSessionID: ClaudeSessionSummary.ID?
    @State private var isPinnedToBottom = true

    private let bottomPinThreshold: CGFloat = 40

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SessionHeaderView(model: model, session: session)

                Divider()

                ZStack {
                    List {
                        ForEach(model.transcriptMessages) { message in
                            MessageRowView(message: message) {
                                model.playMessage(message)
                            }
                            .id(message.id)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .id(session.id)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .onAppear {
                        pendingInitialScrollSessionID = session.id
                        scrollToLatestMessageIfNeeded(using: proxy, reason: .initialLoad)
                    }
                    .onChange(of: model.transcriptMessages.map(\.id)) { oldIDs, newIDs in
                        let appendedMessagesAtEnd =
                            !oldIDs.isEmpty &&
                            newIDs.count > oldIDs.count &&
                            Array(newIDs.prefix(oldIDs.count)) == oldIDs

                        let shouldScrollForInitialLoad = pendingInitialScrollSessionID == session.id
                        let shouldScrollForAppendedMessages = isPinnedToBottom && appendedMessagesAtEnd

                        guard shouldScrollForInitialLoad || shouldScrollForAppendedMessages else {
                            return
                        }

                        scrollToLatestMessageIfNeeded(
                            using: proxy,
                            reason: shouldScrollForInitialLoad ? .initialLoad : .keepPinnedToBottom
                        )
                    }
                    .onScrollGeometryChange(for: ScrollMetrics.self, of: { geometry in
                        ScrollMetrics(
                            visibleMaxY: geometry.visibleRect.maxY,
                            contentHeight: geometry.contentSize.height
                        )
                    }, action: { oldMetrics, newMetrics in
                        let visiblePositionChanged = abs(newMetrics.visibleMaxY - oldMetrics.visibleMaxY) > 1
                        let firstMeasurement = oldMetrics == .zero

                        guard visiblePositionChanged || firstMeasurement else {
                            return
                        }

                        isPinnedToBottom = bottomDistance(for: newMetrics) <= bottomPinThreshold
                    })
                    
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
            }
            .onAppear {
                pendingInitialScrollSessionID = session.id
                isPinnedToBottom = true
            }
            .onChange(of: session.id) { _, newSessionID in
                pendingInitialScrollSessionID = newSessionID
                isPinnedToBottom = true
            }
        }
    }

    private func scrollToLatestMessageIfNeeded(using proxy: ScrollViewProxy, reason: ScrollToLatestReason) {
        guard let lastMessageID = model.transcriptMessages.last?.id else {
            return
        }

        if reason == .initialLoad {
            guard pendingInitialScrollSessionID == session.id else {
                return
            }

            pendingInitialScrollSessionID = nil
        }

        isPinnedToBottom = true

        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(lastMessageID, anchor: .bottom)
        }
    }

    private func bottomDistance(for metrics: ScrollMetrics) -> CGFloat {
        max(0, metrics.contentHeight - metrics.visibleMaxY)
    }
}

private struct ScrollMetrics: Equatable {
    let visibleMaxY: CGFloat
    let contentHeight: CGFloat

    static let zero = ScrollMetrics(visibleMaxY: 0, contentHeight: 0)
}

private enum ScrollToLatestReason {
    case initialLoad
    case keepPinnedToBottom
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
                    .glassEffectID("playback-mode", in: glassNamespace)
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
