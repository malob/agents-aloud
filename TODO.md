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
