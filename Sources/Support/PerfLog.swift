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

    static func mark(_ name: String) {
        logger.info("\(name, privacy: .public)")
    }
}
