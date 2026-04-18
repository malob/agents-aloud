import Darwin
import Foundation

@MainActor
final class TranscriptFileWatcher {
    private var watchedURL: URL?
    private var source: DispatchSourceFileSystemObject?

    func startWatching(
        fileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
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
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        stop()

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        let openErrorNumber = errno
        guard fileDescriptor >= 0 else {
            onFailure(Self.errorDescription(for: fileURL, errorNumber: openErrorNumber))
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
        watchedURL = nil
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }

    private static func errorDescription(for fileURL: URL, errorNumber: Int32) -> String {
        let systemMessage = String(cString: strerror(errorNumber))
        return "\(fileURL.lastPathComponent) (\(systemMessage))"
    }
}
