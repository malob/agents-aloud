import Darwin
import Foundation

@MainActor
protocol TranscriptFileWatching: AnyObject {
    func startWatching(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (TranscriptFileWatcherError) -> Void
    )
    func stop()
}

enum TranscriptFileWatcherError: LocalizedError, Equatable {
    case openFailed(fileName: String, errorNumber: Int32)

    var errorDescription: String? {
        switch self {
        case let .openFailed(fileName, errorNumber):
            let systemMessage = String(cString: strerror(errorNumber))
            return "\(fileName) (\(systemMessage))"
        }
    }
}

@MainActor
final class TranscriptFileWatcher: TranscriptFileWatching {
    private var watchedURL: URL?
    private var source: DispatchSourceFileSystemObject?
    private var retryTask: Task<Void, Never>?

    func startWatching(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (TranscriptFileWatcherError) -> Void
    ) {
        guard watchedURL != fileURL else {
            return
        }

        armWatcher(
            fileURL: fileURL,
            onChange: onChange,
            onFailure: onFailure
        )
    }

    private func armWatcher(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (TranscriptFileWatcherError) -> Void,
        retryCount: Int = 0
    ) {
        stop()

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        let openErrorNumber = errno
        guard fileDescriptor >= 0 else {
            // Brief retry window: Claude Code writes transcripts via atomic
            // temp-file rename, so open() can hit ENOENT in the millisecond
            // gap between the old file being unlinked and the new one
            // appearing. Three tries at 100ms covers that race; anything
            // persistent after 300ms is a real missing-file and surfaces
            // via onFailure.
            if openErrorNumber == ENOENT, retryCount < 3 {
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.armWatcher(
                        fileURL: fileURL,
                        onChange: onChange,
                        onFailure: onFailure,
                        retryCount: retryCount + 1
                    )
                }
                return
            }

            onFailure(.openFailed(fileName: fileURL.lastPathComponent, errorNumber: openErrorNumber))
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else {
                return
            }

            let events = source.data

            if events.contains(.rename) || events.contains(.delete) {
                // Rearm against the original path because rename/delete can orphan the current
                // file descriptor even when a replacement file shows up at the same location.
                self.armWatcher(
                    fileURL: fileURL,
                    onChange: onChange,
                    onFailure: onFailure
                )
                return
            }

            onChange()
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()

        watchedURL = fileURL
        self.source = source
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        watchedURL = nil
        source?.cancel()
        source = nil
    }

    deinit {
        retryTask?.cancel()
        source?.cancel()
    }
}
