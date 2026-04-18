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

                if model.transcriptMessages.isEmpty {
                    ContentUnavailableView(
                        "No Speakable Messages Yet",
                        systemImage: "text.word.spacing",
                        description: Text("This view shows your prompts and assistant text messages from the selected Claude session.")
                    )
                } else if model.displayedTranscriptMessages.isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                } else {
                    List {
                        ForEach(model.displayedTranscriptMessages) { message in
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
                    .onChange(of: model.displayedTranscriptMessages.map(\.id)) { oldIDs, newIDs in
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
        .safeAreaInset(edge: .top) {
            if let errorMessage = model.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.orange), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
    }

    private func scrollToLatestMessageIfNeeded(using proxy: ScrollViewProxy, reason: ScrollToLatestReason) {
        guard let lastMessageID = model.displayedTranscriptMessages.last?.id else {
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
        model.selectedSessionID == session.id && !model.displayedTranscriptMessages.isEmpty
            ? model.displayedTranscriptMessages.count
            : session.messageCount
    }

    private let liveSpeakButtonWidth: CGFloat = 188

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

                if isLiveReadEnabled {
                    Button {
                        model.setLiveReadEnabled(false)
                    } label: {
                        Label("Live Speak On", systemImage: "speaker.wave.3.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(width: liveSpeakButtonWidth)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
                    .controlSize(.large)
                    .help("Stop automatically speaking new assistant messages for this session.")
                    .glassEffectID("playback-mode", in: glassNamespace)
                } else {
                    Button {
                        model.setLiveReadEnabled(true)
                    } label: {
                        Label("Start Live Speak", systemImage: "speaker.wave.2.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(width: liveSpeakButtonWidth)
                    }
                    .buttonStyle(.glass(.regular.interactive()))
                    .controlSize(.large)
                    .help("Automatically speak new assistant messages for this session.")
                    .glassEffectID("playback-mode", in: glassNamespace)
                }
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 8) {
                    if let modifiedAt = session.modifiedAt {
                        SessionStatusBadge(
                            title: DateFormatting.sessionTimestamp.string(from: modifiedAt),
                            systemImage: "clock",
                            prominence: .neutral
                        )
                        .glassEffectID("updated-at", in: glassNamespace)
                    }

                    SessionStatusBadge(
                        title: messageCountText(displayedMessageCount),
                        systemImage: "text.bubble",
                        prominence: .neutral
                    )
                    .glassEffectID("message-count", in: glassNamespace)

                    if model.hasActiveSearch {
                        SessionStatusBadge(
                            title: "Filtered",
                            systemImage: "magnifyingglass",
                            prominence: .search
                        )
                        .glassEffectID("filtered", in: glassNamespace)
                        .glassEffectTransition(.materialize)
                    }
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
    enum Prominence {
        case neutral
        case active
        case search
    }

    let title: String
    let systemImage: String
    let prominence: Prominence

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(glassStyle, in: Capsule())
            .lineLimit(1)
    }

    private var glassStyle: Glass {
        switch prominence {
        case .neutral:
            return .regular
        case .active:
            return .regular.tint(.accentColor)
        case .search:
            return .regular.tint(.orange)
        }
    }
}
