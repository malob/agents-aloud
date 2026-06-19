import Foundation
import MediaPlayer
import OSLog

// Bridges SpeechController state into the macOS Now Playing system
// (Control Center, menu-bar Now Playing widget, AirPods squeeze,
// keyboard media keys) so controlling playback from outside the app
// Just Works. We only handle the control surface + display metadata
// here; the audio itself continues to come out of whichever speech
// backend is active (/usr/bin/say or ElevenLabs streaming).
//
// Per Apple's HIG "Playing audio": only respond to controls the app
// can actually honor. We register play / pause / togglePlayPause /
// stop / nextTrack — everything we have a real mapping for. Seek
// and previous-track aren't registered because we don't support
// them; the system won't offer those controls as a result.
//
// macOS doesn't need AVAudioSession setup or Background Modes
// entitlements (those are iOS-only per Apple's "Configuring your
// app for media playback" doc). MPRemoteCommandCenter +
// MPNowPlayingInfoCenter are sufficient on their own.
@MainActor
final class NowPlayingCoordinator {
    private let logger = Logger(subsystem: "me.malob.agentsaloud", category: "NowPlaying")
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        registerRemoteCommands()
        // Kick off the observation loop — any change to currentMessageID,
        // isSpeaking, or isPaused will retrigger updateNowPlayingInfo.
        trackPlaybackState()
    }

    deinit {
        // Leave no orphan "Now Playing" entry behind after the app
        // terminates. Without this, the macOS Control Center widget
        // can show a ghost track with our title for a few seconds
        // after quit.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote command registration

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlayCommand() ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePauseCommand() ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPauseCommand() ?? .commandFailed
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.handleStopCommand() ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleNextTrackCommand() ?? .commandFailed
        }

        // Explicitly disable commands we don't handle so the system
        // doesn't route stray input at us and get a no-op (which
        // confuses users — the HIG warns against silently swallowing
        // controls).
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func handlePlayCommand() -> MPRemoteCommandHandlerStatus {
        guard let controller = model?.speechController else { return .commandFailed }
        if controller.isPaused {
            controller.resume()
            return .success
        }
        return .noActionableNowPlayingItem
    }

    private func handlePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard let controller = model?.speechController else { return .commandFailed }
        if controller.isSpeaking {
            controller.pause()
            return .success
        }
        return .noActionableNowPlayingItem
    }

    private func handleTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        guard let controller = model?.speechController else { return .commandFailed }
        if controller.isPaused {
            controller.resume()
            return .success
        }
        if controller.isSpeaking {
            controller.pause()
            return .success
        }
        return .noActionableNowPlayingItem
    }

    private func handleStopCommand() -> MPRemoteCommandHandlerStatus {
        guard let model else { return .commandFailed }
        model.stopPlayback()
        return .success
    }

    private func handleNextTrackCommand() -> MPRemoteCommandHandlerStatus {
        // "Next" in our queue semantics = skip the currently-speaking
        // message. The speech controller's per-item cancel on the
        // active message stops it and promotes the next queued item,
        // which matches Podcasts / Music "skip track" behavior.
        guard let controller = model?.speechController,
              let currentID = controller.currentMessageID else {
            return .noActionableNowPlayingItem
        }
        controller.cancel(messageID: currentID)
        return .success
    }

    // MARK: - State observation

    // Uses withObservationTracking + re-subscription: the `apply`
    // closure captures reads of @Observable properties, `onChange`
    // fires on the next mutation of ANY of them, and we re-register
    // inside the handler. This is the standard non-SwiftUI pattern
    // for observing @Observable objects without polling.
    private func trackPlaybackState() {
        withObservationTracking { [weak self] in
            self?.updateNowPlayingInfo()
        } onChange: { [weak self] in
            // The onChange closure runs synchronously off the main
            // thread as part of Observation's notification; hop back
            // to MainActor to re-register and update.
            Task { @MainActor [weak self] in
                self?.trackPlaybackState()
            }
        }
    }

    // MARK: - Metadata update

    private func updateNowPlayingInfo() {
        guard let model else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let controller = model.speechController

        // Reading these three drives the observation subscription —
        // future mutations re-fire `trackPlaybackState`.
        let currentID = controller.currentMessageID
        let isSpeaking = controller.isSpeaking
        let isPaused = controller.isPaused

        guard let currentID,
              let (message, session) = model.findMessage(id: currentID) else {
            // Nothing playing (or message dropped from the transcript
            // cache). Clear so the Now Playing widget doesn't cling to
            // stale metadata.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = Self.snippet(from: message.text)
        info[MPMediaItemPropertyArtist] = session.summary
        info[MPMediaItemPropertyAlbumTitle] = session.projectPath
        // Playback rate: 1.0 = playing, 0.0 = paused. If neither —
        // i.e. the item's in the queue but not actively speaking —
        // we still surface metadata (so Control Center shows "what's
        // next") with rate 0.
        let playing = isSpeaking && !isPaused
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        // Use the generic audio media type. Control Center tweaks
        // chrome details based on this but the difference is minor;
        // .audio is the safest cross-platform choice for TTS.
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Truncate long messages to a reasonable Title length. Control
    // Center shows ~50 chars before eliding; we give ourselves
    // more room so the display has something to scroll or elide
    // gracefully rather than clipping mid-word.
    nonisolated private static func snippet(from text: String, max: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        // Trim at a word boundary when possible for readable elision.
        let prefix = trimmed.prefix(max - 1)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
