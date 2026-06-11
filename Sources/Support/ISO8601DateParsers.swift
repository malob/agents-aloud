import Foundation

// Reusable pair of ISO8601 parsers (with and without fractional
// seconds — transcript timestamps appear in both forms). Construct
// ONE of these per parse pass and reuse it across lines:
// ISO8601DateFormatter construction costs ~1ms, which dominates the
// per-line work when paid for every record in a 256 KB tail window.
struct ISO8601DateParsers {
    let fractionalSeconds: ISO8601DateFormatter
    let standard: ISO8601DateFormatter

    init() {
        let fractionalSeconds = ISO8601DateFormatter()
        fractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalSeconds = fractionalSeconds

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        self.standard = standard
    }

    func date(from value: String) -> Date? {
        fractionalSeconds.date(from: value) ?? standard.date(from: value)
    }
}
