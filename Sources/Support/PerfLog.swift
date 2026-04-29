import Foundation
import OSLog

enum PerfLog {
    static let logger = Logger(subsystem: "local.claudecodevoice", category: "Perf")

    @discardableResult
    static func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            logger.info("\(name, privacy: .public) \(elapsed, format: .fixed(precision: 1), privacy: .public)ms")
        }
        return try body()
    }

    // Async overload — body can `await` (e.g. iterate a `URL.lines`
    // AsyncSequence). Same elapsed-ms log shape as the sync version.
    //
    // The `isolation: #isolation` parameter inherits the caller's
    // actor isolation, which lets us pass body closures that capture
    // actor-isolated state without Swift 6 strict-concurrency
    // complaining about non-Sendable sends. See the proposal at
    // SE-0420 "Inheritance of actor isolation."
    @discardableResult
    static func time<T>(
        _ name: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            logger.info("\(name, privacy: .public) \(elapsed, format: .fixed(precision: 1), privacy: .public)ms")
        }
        return try await body()
    }

    static func mark(_ name: String) {
        logger.info("\(name, privacy: .public)")
    }
}
