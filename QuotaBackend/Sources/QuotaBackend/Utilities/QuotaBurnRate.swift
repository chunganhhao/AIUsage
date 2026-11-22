import Foundation

public struct QuotaBurnRate: Sendable, Equatable {
    public let multiplier: Double
    public let exhaustionAfter: TimeInterval?
    public var isAtRisk: Bool { exhaustionAfter != nil }

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
