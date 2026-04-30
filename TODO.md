# TODOs and Known Bugs

This is a lightweight holding pen for non-urgent issues that are real enough to remember but not worth derailing active work.

## Known Bugs

- Toolbar chrome can remain transparent after hiding and showing the sidebar.
  - Repro: select a session, hide the sidebar from the toolbar, then show it again.
  - Expected: reopened sidebar state restores the original unified toolbar material and separator.
  - Observed: the titlebar/toolbar can stay visually transparent and lose the separator until relaunch.
  - Status: parked. Prior experiments with toolbar background modifiers, scroll-edge tweaks, explicit column visibility, and a small AppKit chrome shim did not produce a satisfying fix.

## Later Ideas

- Revisit the sidebar toolbar issue only if it becomes more noticeable or if a broader AppKit/window-chrome pass happens anyway.

- **Replace `TranscriptDetailView`'s queued bottom-pin with a `.scrollPosition(id:anchor:)` + bottom-sentinel approach.**
  - Context: the view currently scrolls to the latest message via a generation-counter `Task` that runs `proxy.scrollTo` three times (Task.yield + 20 ms + 120 ms) to catch row-height re-measurement after the parent layout claims to be done. Works reliably under Codex's computer-use testing but the magic-number delays are ugly.
  - Spike: add a `Color.clear.frame(height: 1).id("bottom")` sentinel at the end of the VStack, bind `@State var scrollAnchorID: String? = "bottom"` via `.scrollPosition(id: $scrollAnchorID, anchor: .bottom)`, drive auto-pin off the same `userSetAtBottom` gate. The `.scrollPosition` binding-based API was previously avoided because it was broken with LazyVStack — now that we're on eager VStack (commit `fc89db9`, after the 50-message cap), it's worth retrying.
  - Success criteria: the sentinel approach reliably lands at the latest message on cold-load click, warm-load click, and across cross-source switches (Claude → Codex and back). Same correctness as the current shim with materially less code.
  - If it works: delete `bottomPinGeneration` / `bottomPinTargetID` state, `requestBottomPin` / `scrollToBottomIfStillPinned` helpers, the `.task(id:)` with three passes, and the magic-number delays. Net ~5 lines instead of ~30. CLAUDE.md scroll-to-bottom entry shrinks back to a paragraph.
  - If it doesn't: revert. The current pragmatic shim works.
  - Estimated time: 30 min focused work + manual testing across the cases above.
  - Source bug: SwiftUI lacks a working "stick to bottom while content settles" primitive on macOS — Apple Developer Forums thread 741406, open since 2023. Both alternatives ultimately work around the same gap; this spike just bets on `.scrollPosition` being a cleaner work-around than the timing shim.
