import Darwin
import Foundation

@MainActor
final class SystemVoiceBackendDriver: SpeechBackendDriver {
    private static let defaultWordsPerMinute = 400

    private final class SystemVoiceJob {
        let playbackID: UUID
        let process: Process
        let inputPipe: Pipe
        private var hasClosedInput = false
        private(set) var wasInterruptedByApp = false

        init(playbackID: UUID, process: Process, inputPipe: Pipe) {
            self.playbackID = playbackID
            self.process = process
            self.inputPipe = inputPipe
        }

        func write(_ text: String) throws {
            guard let data = text.data(using: .utf8) else {
                return
            }

            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            closeInput()
        }

        func closeInput() {
            guard !hasClosedInput else {
                return
            }

            hasClosedInput = true
            try? inputPipe.fileHandleForWriting.close()
        }

        func pause() {
            guard process.isRunning else {
                return
            }

            // `say` has no pause API, so we suspend the subprocess directly.
            kill(process.processIdentifier, SIGSTOP)
        }

        func resume() {
            guard process.isRunning else {
                return
            }

            kill(process.processIdentifier, SIGCONT)
        }

        func terminate() {
            wasInterruptedByApp = true
            closeInput()

            if process.isRunning {
                process.terminate()
            }
        }
    }

    private var eventHandler: (@MainActor @Sendable (SpeechDriverEvent) -> Void)?
    private var currentJob: SystemVoiceJob?

    var availableVoices: [SpeechVoiceOption] {
        []
    }

    // This matches the speed the user preferred while prototyping against `say`.
    var wordsPerMinute: Int? {
        Self.defaultWordsPerMinute
    }

    func resolveVoiceIdentifier(_ identifier: String?) -> String? {
        identifier
    }

    func start(
        request: SpeechRequest,
        eventHandler: @escaping @MainActor @Sendable (SpeechDriverEvent) -> Void
    ) throws {
        stop()

        let process = Process()
        let inputPipe = Pipe()
        let job = SystemVoiceJob(
            playbackID: request.playbackID,
            process: process,
            inputPipe: inputPipe
        )

        self.eventHandler = eventHandler
        currentJob = job

        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", String(wordsPerMinute ?? Self.defaultWordsPerMinute)]
        process.standardInput = inputPipe
        process.terminationHandler = { [weak self] process in
            let terminationStatus = process.terminationStatus
            let terminationReason = process.terminationReason

            Task { @MainActor in
                self?.handleTermination(
                    playbackID: request.playbackID,
                    terminationReason: terminationReason,
                    terminationStatus: terminationStatus
                )
            }
        }

        do {
            try process.run()
            emit(.didStart(request.playbackID))
            try job.write(request.text)
        } catch {
            job.terminate()
            if currentJob?.playbackID == request.playbackID {
                currentJob = nil
            }
            emit(.didFail(request.playbackID, description: error.localizedDescription))
            throw error
        }
    }

    func pause() {
        guard let currentJob else {
            return
        }

        currentJob.pause()
        emit(.didPause(currentJob.playbackID))
    }

    func resume() {
        guard let currentJob else {
            return
        }

        currentJob.resume()
        emit(.didResume(currentJob.playbackID))
    }

    func stop() {
        currentJob?.terminate()
        currentJob = nil
    }

    private func handleTermination(
        playbackID: UUID,
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32
    ) {
        guard let currentJob, currentJob.playbackID == playbackID else {
            return
        }

        self.currentJob = nil

        guard !currentJob.wasInterruptedByApp else {
            return
        }

        if terminationReason == .exit, terminationStatus == 0 {
            emit(.didFinish(playbackID))
        } else {
            emit(
                .didFail(
                    playbackID,
                    description: "System voice playback exited with reason \(String(describing: terminationReason)) and status \(terminationStatus)"
                )
            )
        }
    }

    private func emit(_ event: SpeechDriverEvent) {
        eventHandler?(event)
    }
}
