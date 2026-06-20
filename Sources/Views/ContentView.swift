import SwiftUI

struct ContentView: View {
    let model: AppModel

    private var liveReadIsOnForSelectedSession: Bool {
        guard let selectedID = model.selectedSession?.id else { return false }
        return model.liveReadSessionIDs.contains(selectedID)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            detailContent
                .overlay(alignment: .top) {
                    if hasActiveBanner {
                        BannerStackView(
                            errorMessage: model.errorMessage,
                            playbackErrorMessage: model.speechController.playbackError?.message,
                            onDismissError: model.dismissErrorMessage,
                            onDismissPlaybackError: model.speechController.dismissPlaybackError
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
        }
        // No navigationTitle here — TranscriptDetailView sets a
        // session-scoped title + subtitle via navigationTitle +
        // navigationSubtitle. When no session is selected SwiftUI
        // falls back to the window's default title.
        //
        // The toolbar background is left visible (default) so the
        // window chrome renders the title/subtitle region properly.
        // An earlier version of this file hid it to let the in-body
        // header visually flow into the chrome; now that the header
        // is gone we want the standard macOS toolbar strip back.
        .toolbar {
            if model.selectedSession != nil {
                ToolbarItem(placement: .primaryAction) {
                    PlaybackControlsView(model: model)
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Binding(
                        get: { liveReadIsOnForSelectedSession },
                        set: { model.setLiveReadEnabled($0) }
                    )) {
                        Label("Live Speak", systemImage: "speaker.wave.2.fill")
                    }
                    .toggleStyle(.button)
                    .help(
                        liveReadIsOnForSelectedSession
                            ? "Stop automatically speaking new assistant messages for this session."
                            : "Automatically speak new assistant messages for this session."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let session = model.selectedSession {
            // `.id(session.id)` is load-bearing: it forces SwiftUI to tear
            // down and rebuild TranscriptDetailView when the user switches
            // sessions, which resets the view's scroll @State (auto-pin,
            // userSetAtBottom, etc.). Without it, scroll state from the
            // previous session leaks through and the detail view can mount
            // at the wrong position.
            TranscriptDetailView(model: model, session: session)
                .id(session.id)
        } else if case .loading = model.sessionsState {
            ContentUnavailableView(
                "Loading Sessions…",
                systemImage: "waveform",
                description: Text("Looking for recent Claude Code sessions.")
            )
        } else {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "waveform",
                description: Text("Choose a Claude Code session from the sidebar.")
            )
        }
    }

    private var hasActiveBanner: Bool {
        model.errorMessage != nil || model.speechController.playbackError != nil
    }
}

private struct BannerStackView: View {
    let errorMessage: String?
    let playbackErrorMessage: String?
    let onDismissError: () -> Void
    let onDismissPlaybackError: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let errorMessage {
                    BannerView(
                        kind: .error,
                        message: errorMessage,
                        onDismiss: onDismissError
                    )
                }

                if let playbackErrorMessage {
                    BannerView(
                        kind: .playback,
                        message: playbackErrorMessage,
                        onDismiss: onDismissPlaybackError
                    )
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .animation(.smooth, value: errorMessage)
        .animation(.smooth, value: playbackErrorMessage)
    }
}

private struct BannerView: View {
    enum Kind {
        case error
        case playback

        var title: String {
            switch self {
            case .error:
                return "Action needed"
            case .playback:
                return "Playback failed"
            }
        }

        var symbolName: String {
            switch self {
            case .error:
                return "exclamationmark.triangle.fill"
            case .playback:
                return "speaker.slash.fill"
            }
        }

        var helpText: String {
            switch self {
            case .error:
                return "Dismiss error"
            case .playback:
                return "Dismiss playback status"
            }
        }

        var tint: Color {
            switch self {
            case .error:
                return .orange
            case .playback:
                return .red
            }
        }
    }

    let kind: Kind
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(kind.tint.opacity(0.13))
                }
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(kind.helpText)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(kind.tint.opacity(0.07)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(kind.tint.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }
}
