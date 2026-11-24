import Foundation

public struct QuotaBurnRate: Sendable, Equatable {
    public let multiplier: Double
    public let exhaustionAfter: TimeInterval?
    public var isAtRisk: Bool { exhaustionAfter != nil }

    public static let defaultMaxSnapshotAge: TimeInterval = 30 * 60

    private static let strictISO8601Pattern =
        #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3])(?::?[0-5][0-9])?)\z"#

    /// Strict full-string ISO 8601 parser for burn-rate snapshot timestamps; rejects trailing junk
    /// and nonexistent Gregorian dates/times that Foundation's `ISO8601DateFormatter` silently rolls over.
    public static func parseSnapshotTimestamp(_ value: String?) -> Date? {
        guard let value,
              value.range(of: strictISO8601Pattern, options: .regularExpression) != nil else {
            return nil
        }
        let bytes = Array(value.utf8)
        func intAt(_ start: Int, _ count: Int) -> Int {
            var result = 0
            for index in start..<(start + count) {
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        let year = intAt(0, 4)
        let month = intAt(5, 2)
        let day = intAt(8, 2)
        let hour = intAt(11, 2)
        let minute = intAt(14, 2)
        let second = intAt(17, 2)
        guard year >= 1,
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }
        let isLeapYear = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
        let maxDay: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
        case 4, 6, 9, 11: maxDay = 30
        case 2: maxDay = isLeapYear ? 29 : 28
        default: return nil
        }
        guard (1...maxDay).contains(day) else { return nil }
        return SharedFormatters.parseISO8601(value)
    }

    public static func isSnapshotFresh(
        fetchedAt: Date?,
        now: Date = Date(),
        maxAge: TimeInterval = defaultMaxSnapshotAge
    ) -> Bool {
        guard let fetchedAt, maxAge.isFinite, maxAge >= 0 else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -60 && age <= maxAge
    }

    public static func estimate(
        remainingPercent: Double?,
        resetAt: String?,
        label: String,
        fetchedAt: Date?,
        isStale: Bool = false,
        now: Date = Date(),
        maxSnapshotAge: TimeInterval = defaultMaxSnapshotAge
    ) -> Self? {
        guard !isStale,
              isSnapshotFresh(fetchedAt: fetchedAt, now: now, maxAge: maxSnapshotAge),
              let fetchedAt else {
            return nil
        }
        guard let resetAt,
              let reset = SharedFormatters.parseISO8601(resetAt),
              reset.timeIntervalSince(now) > 0 else {
            return nil
        }
        let sampleTime = min(fetchedAt, now)
        guard let atCapture = estimate(
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            label: label,
            now: sampleTime
        ) else {
            return nil
        }
        let ageSinceCapture = max(0, now.timeIntervalSince(sampleTime))
        let adjustedExhaustion = atCapture.exhaustionAfter.map { max(0, $0 - ageSinceCapture) }
        return Self(multiplier: atCapture.multiplier, exhaustionAfter: adjustedExhaustion)
    }

    /// Window-average estimate, not a forecast of future demand. Unknown/expired windows stay unknown.
    public static func estimate(remainingPercent: Double?, resetAt: String?, label: String, now: Date = Date()) -> Self? {
        guard let duration = windowDuration(label: label) else { return nil }
        guard let remainingPercent, remainingPercent.isFinite, (0...100).contains(remainingPercent),
              let resetAt, let reset = SharedFormatters.parseISO8601(resetAt) else { return nil }
        let timeLeft = reset.timeIntervalSince(now)
        let elapsed = duration - timeLeft
        guard timeLeft > 0, elapsed >= 60, elapsed < duration else { return nil }
        let used = 100 - remainingPercent
        let rate = used / elapsed
        let multiplier = used / (100 * elapsed / duration)
        let exhaustion = rate > 0 ? remainingPercent / rate : .infinity
        return Self(multiplier: multiplier, exhaustionAfter: exhaustion < timeLeft ? max(0, exhaustion) : nil)
    }
    public static func windowDuration(label: String) -> TimeInterval? {
        let lower = label.lowercased()
        if ["week", "7d", "7-day", "7 days", "周", "7天", "7 天", "tuần", "7 ngày"].contains(where: lower.contains) { return 7 * 86400 }
        if ["5h", "5-hour", "5 hour", "5 小时", "5小时", "5 giờ"].contains(where: lower.contains) { return 5 * 3600 }
        return nil
    }
}
