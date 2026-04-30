import SwiftUI

// Chat-style auto-pin-to-bottom — READ BEFORE "SIMPLIFYING".
//
// History: this view used to wrap a `LazyVStack` with substantial
// workaround machinery because LazyVStack's height estimation
// reliably broke `.defaultScrollAnchor(.bottom)` and
// `.scrollPosition(id:anchor:)` (Apple Developer Forums thread
// 741406, still open in macOS 26). After capping the visible
// transcript window at 50 messages
// (`TranscriptDisplayLimits.messageCap`), eager `VStack` is well
// within budget and lets the standard SwiftUI anchor APIs work.
// This eliminated a class of "lands one or two messages short of
// the true bottom" bugs that the LazyVStack workaround couldn't
// fully suppress.
//
// What's still here:
//   1. `.defaultScrollAnchor(.bottom)` for initial-mount anchoring.
//      ContentView wraps this view in `.id(session.id)` so the
//      view (and its @State / ScrollView) is rebuilt on every
//      session switch, which means initial-mount runs on every
//      click — landing at bottom every time.
//   2. `userSetAtBottom` gate on a `proxy.scrollTo` driven by
//      `onScrollGeometryChange(contentSize)`. Pins to the latest
//      message when new content arrives (live-read append, async
//      cold load completing), but only if the user hasn't
//      deliberately scrolled away from the bottom.
//   3. `userSetAtBottom` is sampled ONLY when `ScrollPhase`
//      transitions to `.idle` FROM a user-initiated phase
//      (`.tracking` / `.decelerating` / `.interacting`). Updating
//      from `.animating` (programmatic scrolls) or from
//      content-growth-driven idle transitions would latch it to
//      false and silently break auto-pin. That trap was seen in
//      the logs.
//   4. The 250px threshold for "at bottom" is empirical: with
//      `.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` the
//      scroll physics reserve ~165px of scroll extent for the
//      blur edge, so the user's visual "bottom" lands at
//      `remaining ≈ 165`, not 0.
//
// If you're tempted to switch back to LazyVStack: don't, unless
// you're also raising the 50-message cap to a level where eager
// layout would actually hurt. Lazy comes back with the bugs
// described above.
struct TranscriptDetailView: View {
    let model: AppModel
    let session: ClaudeSessionSummary
    @State private var userSetAtBottom = true
    @State private var liveIsAtBottom = true
    @State private var bottomPinGeneration = 0
    @State private var bottomPinTargetID: TranscriptMessage.ID?

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
                    // Eager VStack rather than LazyVStack — see file
                    // header. The 50-message cap means we're rendering
                    // at most 50 cells, which is well within
                    // eager-layout budget and lets the standard
                    // anchor APIs work reliably.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(transcriptMessages) { message in
                            MessageRowView(
                                message: message,
                                source: session.source,
                                status: model.speechController.status(for: message.id),
                                isExpanded: model.isMessageExpanded(message.id),
                                onPlay: { model.playMessage(message) },
                                onPlayFromHere: { model.playMessagesFromHere(message) },
                                onCancel: { model.speechController.cancel(messageID: message.id) },
                                onToggleExpanded: { model.toggleMessageExpanded(message.id) }
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
                // Initial-mount anchor. Combined with the `.id(session.id)`
                // wrapper in ContentView, this fires on every session
                // switch (since each switch produces a fresh ScrollView)
                // and lands us at the bottom of whatever cached or
                // freshly-loaded content the new session has.
                //
                // Deliberately NOT `.defaultScrollAnchor(.bottom, for: .sizeChanges)` —
                // that would yank the user back to the bottom on every
                // new-message arrival even when they've scrolled up to
                // read older content. The manual onScrollGeometryChange
                // machinery below handles new-content pinning with the
                // userSetAtBottom gate.
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .onAppear {
                    requestBottomPin()
                }
                .onChange(of: transcriptMessages.last?.id) { _, _ in
                    requestBottomPin()
                }
                .task(id: bottomPinGeneration) {
                    guard let targetID = bottomPinTargetID else { return }

                    // Let SwiftUI finish the layout pass that triggered
                    // this pin request before asking for the final row.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToBottomIfStillPinned(proxy: proxy, targetID: targetID)

                    // Text rows can settle a frame or two later after
                    // wrapping against the final container width. These
                    // no-animation corrections turn the "old bottom" into
                    // the actual bottom without fighting a user who has
                    // deliberately scrolled away.
                    for delay in [20, 120] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        scrollToBottomIfStillPinned(proxy: proxy, targetID: targetID)
                    }
                }
                .onScrollGeometryChange(for: CGSize.self, of: { $0.contentSize }) { _, _ in
                    // Any content size change — initial render, cells materializing,
                    // new message appended, existing message growing — re-pin to
                    // the last message, but only if the user hasn't deliberately
                    // scrolled away from the bottom.
                    requestBottomPin()
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

            // Only show the loading spinner during a true cold load
            // (no prior content to keep on screen). During a refresh of
            // an already-populated session, TranscriptState.loading
            // carries the prior `messages` through unchanged, so the
            // ForEach above is already rendering them — overlaying a
            // spinner on top reads as a flash of "loading…" over content
            // the user can already see, which is what triggered this
            // gate. Cold first-loads still show the spinner because
            // `transcriptMessages` is empty until the await completes.
            if isLoadingTranscript && transcriptMessages.isEmpty {
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
        // Session identity lives in the window toolbar via
        // navigationTitle + navigationSubtitle — Preview.app pattern,
        // gives us the native two-line title treatment and frees up
        // a whole row of vertical space in the transcript view.
        .navigationTitle(session.summary)
        .navigationSubtitle(session.projectPath)
    }

    private func requestBottomPin() {
        guard userSetAtBottom, let lastID = transcriptMessages.last?.id else { return }
        bottomPinTargetID = lastID
        bottomPinGeneration += 1
    }

    private func scrollToBottomIfStillPinned(proxy: ScrollViewProxy, targetID: TranscriptMessage.ID) {
        guard userSetAtBottom, transcriptMessages.last?.id == targetID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(targetID, anchor: .bottom)
        }
    }
}
