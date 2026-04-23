import SwiftUI

// Chat-style auto-pin-to-bottom — READ BEFORE "SIMPLIFYING".
//
// If you're reaching for `.defaultScrollAnchor(.bottom)`,
// `.defaultScrollAnchor(.bottom, for: .sizeChanges)`, or
// `.scrollPosition(id:anchor:)` to shrink this view: those APIs do not
// work with LazyVStack. Known Apple bug, reported on the Developer
// Forums in 2023 (thread 741406) and still broken in macOS 26. Symptoms:
// (a) view renders blank when content > screen height until the user
// scrolls a bit, (b) no auto-pin when new messages arrive. Multiple
// attempts to use those APIs here were reverted after observation.
//
// The pattern below is the community-verified workaround (see e.g.
// https://medium.com/@itsuki.enjoy/swiftui-2-5-reliable-ways-to-automatically-scroll-to-the-bottom-of-scrollview-1581711e957c):
//
//   1. `ScrollViewReader` + `proxy.scrollTo(id, anchor: .bottom)` —
//      the only path that reliably lands at the bottom with LazyVStack.
//   2. Listen to `contentSize` changes (not `messages.last?.id`); this
//      catches initial layout, cell materialization, new-message
//      append, and (future) streaming-edit growth under one signal.
//   3. `userSetAtBottom` gates the auto-pin. It is sampled ONLY when
//      `ScrollPhase` transitions to `.idle` FROM a user-initiated phase
//      (`.tracking` / `.decelerating` / `.interacting`). Updating it
//      from `.animating` transitions (programmatic scrolls) or from
//      content-growth-driven idle transitions would latch it to false
//      and silently break auto-pin. That trap was seen in the logs.
//   4. The 250px threshold for "at bottom" is empirical: with
//      `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` the scroll
//      physics reserve ~165px of scroll extent for the blur edge, so the
//      user's visual "bottom" lands at `remaining ≈ 165`, not 0.
//
// If this view ever feels over-engineered, the reason is that SwiftUI's
// simpler declarative primitives for chat UIs are currently broken.
struct TranscriptDetailView: View {
    let model: AppModel
    let session: ClaudeSessionSummary
    @State private var userSetAtBottom = true
    @State private var liveIsAtBottom = true

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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transcriptMessages) { message in
                            MessageRowView(
                                message: message,
                                status: model.speechController.status(for: message.id),
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
                // Initial anchor only. Without this, sessions with
                // variable-height messages (big code blocks, XML dumps)
                // land mid-transcript on first render because LazyVStack's
                // estimated cell heights diverge from actuals — summing
                // estimates gives a contentSize smaller than reality, so
                // `proxy.scrollTo(lastID, anchor: .bottom)` lands one or
                // two messages short of the true bottom. `.defaultScrollAnchor(.bottom)`
                // sidesteps this by letting SwiftUI compute the initial
                // offset against the true laid-out content. We deliberately
                // don't use `.defaultScrollAnchor(.bottom, for: .sizeChanges)`
                // because the manual machinery below handles new-message
                // auto-scroll and needs userSetAtBottom gating to respect
                // scroll-up; the sizeChanges anchor fights that.
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .onScrollGeometryChange(for: CGSize.self, of: { $0.contentSize }) { _, _ in
                    // Any content size change — initial render, cells materializing,
                    // new message appended, existing message growing — re-pin to
                    // the last message, but only if the user hasn't deliberately
                    // scrolled away from the bottom.
                    guard userSetAtBottom else { return }
                    if let lastID = transcriptMessages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .onScrollGeometryChange(for: Bool.self, of: { geo in
                    // ~165px of the natural scroll extent is reserved by
                    // .scrollEdgeEffectStyle(.soft) / scroll physics — the user's
                    // "visual bottom" lands there, not at remaining=0.
                    let remaining = geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height)
                    return remaining <= 250
                }) { _, newIsAtBottom in
                    liveIsAtBottom = newIsAtBottom
                }
                .onScrollPhaseChange { old, new in
                    // Sample userSetAtBottom ONLY when a user-driven scroll ends.
                    // Do NOT update from .animating (programmatic scroll) or .idle
                    // transitions caused by content growth — those would erroneously
                    // latch userSetAtBottom=false and break auto-pinning.
                    let userInitiated = old == .tracking || old == .decelerating || old == .interacting
                    if new == .idle && userInitiated {
                        let before = userSetAtBottom
                        userSetAtBottom = liveIsAtBottom
                        if before != userSetAtBottom {
                            PerfLog.mark("Scroll userSetAtBottom=\(userSetAtBottom)")
                        }
                    }
                }
            }

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
