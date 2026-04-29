import Darwin
import Foundation
import Synchronization

@MainActor
final class SystemVoiceBackendDriver: SpeechBackendDriver {
    // Accumulates stderr chunks from /usr/bin/say. The readability
    // handler fires on a DispatchQueue (not an actor), and we read the
    // accumulated output from the main actor after the process exits —
    // Mutex gives us the write-from-any-thread + Sendable conformance
    // without `@unchecked Sendable` and without manual NSLock dance.
    private final class StandardErrorBuffer: Sendable {
        private let data = Mutex(Data())

        func append(_ newData: Data) {
            guard !newData.isEmpty else {
                return
            }
            data.withLock { $0.append(newData) }
        }

        func output() -> String? {
            let snapshot = data.withLock { $0 }
            guard let output = String(data: snapshot, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                return nil
            }

            return output.replacingOccurrences(of: "\n", with: " ")
        }
    }

    private final class SystemVoiceJob {
        enum Outcome {
            case running
            case interruptedByApp
        }

        let playbackID: UUID
        let process: Process
        let inputPipe: Pipe
        private var hasClosedInput = false
        private(set) var outcome: Outcome = .running

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
            outcome = .interruptedByApp
            closeInput()

            if process.isRunning {
                process.terminate()
            }
        }
    }

    private struct SystemVoiceStartError: LocalizedError {
        let description: String

        var errorDescription: String? {
            description
        }
    }

    // Injectable so tests can swap /usr/bin/say for a shell that
    // simulates lifecycle (exits normally, exits with error, runs
    // until stopped) without actually playing audio. The closure
    // receives the per-request wpm so production paths still get
    // `say -r <wpm>`; tests substitute a closure that builds the
    // shell-runner args and ignores the wpm input.
    private let executableURL: URL
    private let argumentsForWordsPerMinute: @MainActor (Int) -> [String]

    private var eventHandler: (@MainActor @Sendable (SpeechDriverEvent) -> Void)?
    private var currentJob: SystemVoiceJob?

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/say"),
        argumentsForWordsPerMinute: @escaping @MainActor (Int) -> [String] = { wpm in
            ["-r", String(wpm)]
        }
    ) {
        self.executableURL = executableURL
        self.argumentsForWordsPerMinute = argumentsForWordsPerMinute
    }

    var availableVoices: [SpeechVoiceOption] {
        []
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
        let errorPipe = Pipe()
        let errorBuffer = StandardErrorBuffer()
        let job = SystemVoiceJob(
            playbackID: request.playbackID,
            process: process,
            inputPipe: inputPipe
        )

        self.eventHandler = eventHandler
        currentJob = job

        process.executableURL = executableURL
        // Args derived per-request from wpm so the Settings slider
        // takes effect on the next utterance — we no longer freeze
        // the rate at construction time.
        process.arguments = argumentsForWordsPerMinute(request.wordsPerMinute)
        process.standardInput = inputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            let terminationStatus = process.terminationStatus
            let terminationReason = process.terminationReason
            let standardErrorOutput = errorBuffer.output()
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task { @MainActor in
                self?.handleTermination(
                    playbackID: request.playbackID,
                    terminationReason: terminationReason,
                    terminationStatus: terminationStatus,
                    standardErrorOutput: standardErrorOutput
                )
            }
        }

        do {
            try process.run()
            Self.configurePipeForNoSigPipe(inputPipe.fileHandleForWriting)
            try job.write(request.text)
            emit(.didStart(request.playbackID))
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let standardErrorOutput = process.isRunning ? nil : errorBuffer.output()
            let failureDescription = Self.failureDescription(
                standardErrorOutput: standardErrorOutput,
                fallback: error.localizedDescription
            )
            job.terminate()
            if currentJob?.playbackID == request.playbackID {
                currentJob = nil
            }
            throw SystemVoiceStartError(description: failureDescription)
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
        terminationStatus: Int32,
        standardErrorOutput: String?
    ) {
        guard let currentJob, currentJob.playbackID == playbackID else {
            return
        }

        self.currentJob = nil

        guard currentJob.outcome != .interruptedByApp else {
            return
        }

        if terminationReason == .exit, terminationStatus == 0 {
            emit(.didFinish(playbackID))
        } else {
            emit(
                .didFail(
                    playbackID,
                    description: Self.failureDescription(
                        standardErrorOutput: standardErrorOutput,
                        fallback: "Playback failed."
                    )
                )
            )
        }
    }

    private func emit(_ event: SpeechDriverEvent) {
        eventHandler?(event)
    }

    nonisolated private static func failureDescription(
        standardErrorOutput: String?,
        fallback: String
    ) -> String {
        if let standardErrorOutput {
            return standardErrorOutput
        }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Playback failed." : trimmedFallback
    }

    nonisolated private static func configurePipeForNoSigPipe(_ fileHandle: FileHandle) {
        _ = fcntl(fileHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
}
