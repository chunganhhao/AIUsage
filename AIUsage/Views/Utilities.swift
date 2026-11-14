import Foundation
import SwiftUI
import Combine
import QuotaBackend

// MARK: - Global Time Manager (单例，所有 View 共享一个 Timer)
// Relative time display is minute-granularity; 30s refresh is sufficient.

class GlobalTimeManager: ObservableObject {
    static let shared = GlobalTimeManager()

    @Published var currentTime = Date()
    private var timer: AnyCancellable?
    private var activeViewCount = 0

    private init() {}

    func startIfNeeded() {
        activeViewCount += 1
        if timer == nil {
            timer = Timer.publish(every: 30, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] time in
                    self?.currentTime = time
                }
        }
    }

    func stopIfNeeded() {
        activeViewCount -= 1
        if activeViewCount <= 0 {
            timer?.cancel()
            timer = nil
            activeViewCount = 0
        }
    }
}

// MARK: - Refreshable Time Views

struct RefreshableTimeView: View {
    enum Style {
        /// 「几分钟前 · 18:52:43」
        case relativeWithClock
        /// 仅「几分钟前」——卡片底栏用，避免信息重复
        case relativeOnly
    }

    let date: Date
    let language: String
    let font: Font
    let foregroundStyle: Color
    var style: Style = .relativeWithClock

    @ObservedObject private var timeManager = GlobalTimeManager.shared

    init(
        date: Date,
        language: String,
        font: Font = .caption2,
        foregroundStyle: Color = .secondary,
        style: Style = .relativeWithClock
    ) {
        self.date = date
        self.language = language
        self.font = font
        self.foregroundStyle = foregroundStyle
        self.style = style
    }

    private var formattedTime: String {
        _ = timeManager.currentTime
        switch style {
        case .relativeWithClock:
            return formatRefreshTimestamp(date, language: language)
        case .relativeOnly:
            return formatRelativeRefreshTime(date, language: language)
        }
    }

    var body: some View {
        Text(formattedTime)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .help(formatRefreshTimestamp(date, language: language))
            .onAppear {
                timeManager.startIfNeeded()
            }
            .onDisappear {
                timeManager.stopIfNeeded()
            }
    }
}

// MARK: - Shared Formatting Utilities

private func formatRelativeInterval(_ interval: TimeInterval, language: String) -> String {
    let clamped = max(0, interval)
    if clamped < 60 {
        switch language {
        case "zh": return "刚刚"
        case "vi": return "Vừa xong"
        default: return "Just now"
        }
    } else if clamped < 3600 {
        let minutes = Int(clamped / 60)
        switch language {
        case "zh": return "\(minutes) 分钟前"
        case "vi": return "\(minutes) phút trước"
        default: return "\(minutes)m ago"
        }
    } else if clamped < 86400 {
        let hours = Int(clamped / 3600)
        switch language {
        case "zh": return "\(hours) 小时前"
        case "vi": return "\(hours) giờ trước"
        default: return "\(hours)h ago"
        }
    } else {
        let days = Int(clamped / 86400)
        switch language {
        case "zh": return "\(days) 天前"
        case "vi": return "\(days) ngày trước"
        default: return "\(days)d ago"
        }
    }
}

func formatRelativeTime(_ isoString: String, language: String) -> String {
    guard let date = parseISO8601(isoString) else { return "" }
    return formatRelativeInterval(Date().timeIntervalSince(date), language: language)
}

func formatRelativeTimeFromDate(_ date: Date, language: String) -> String {
    let relative = date.formatted(.relative(presentation: .named))
    switch language {
    case "zh": return "最近活跃 \(relative)"
    case "vi": return "Hoạt động gần nhất \(relative)"
    default: return "Last seen \(relative)"
    }
}

func formatRefreshTimestamp(_ date: Date, language: String) -> String {
    let localeId = language == "zh" ? "zh_CN" : (language == "vi" ? "vi_VN" : "en_US_POSIX")
    let clock = DateFormat.formatter("HH:mm:ss", timeZone: .current, locale: Locale(identifier: localeId)).string(from: date)
    return "\(formatRelativeRefreshTime(date, language: language)) · \(clock)"
}

func formatRefreshTimestamp(_ isoString: String, language: String) -> String {
    guard let date = parseISO8601(isoString) else { return "" }
    return formatRefreshTimestamp(date, language: language)
}

func formatRelativeRefreshTime(_ date: Date, language: String) -> String {
    formatRelativeInterval(Date().timeIntervalSince(date), language: language)
}

func localizedProviderStatusLabel(_ label: String, language: String) -> String {
    switch (language, label) {
    case ("zh", "Healthy"): return "正常"
    case ("zh", "Watch"): return "偏低"
    case ("zh", "Critical"): return "告急"
    case ("zh", "Error"): return "错误"
    case ("zh", "Tracking"): return "追踪中"
    case ("zh", "Idle"): return "空闲"
    case ("zh", "Active"): return "活跃"
    case ("zh", "Snapshot"): return "额度快照"
    case ("zh", "Waiting"): return "等待同步"
    case ("zh", "Proxy session"): return "代理会话"
    case ("zh", "Feedback disconnected"): return "同步已断开"
    case ("vi", "Healthy"): return "Ổn định"
    case ("vi", "Watch"): return "Cần theo dõi"
    case ("vi", "Critical"): return "Cảnh báo gấp"
    case ("vi", "Error"): return "Lỗi"
    case ("vi", "Tracking"): return "Đang theo dõi"
    case ("vi", "Idle"): return "Nhàn rỗi"
    case ("vi", "Active"): return "Đang dùng"
    case ("vi", "Snapshot"): return "Ảnh chụp hạn mức"
    case ("vi", "Waiting"): return "Đang chờ đồng bộ"
    case ("vi", "Proxy session"): return "Phiên proxy"
    case ("vi", "Feedback disconnected"): return "Đã ngắt đồng bộ"
    default: return label
    }
}

private enum NumberFormatterCache {
    static func currencyFormatter(symbol: String, fractionDigits: Int) -> NumberFormatter {
        let key = "AIUsage.CurrencyFormatter.\(symbol).\(fractionDigits)"
        if let formatter = Thread.current.threadDictionary[key] as? NumberFormatter {
            return formatter
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = symbol
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    static func decimalFormatter() -> NumberFormatter {
        let key = "AIUsage.DecimalFormatter"
        if let formatter = Thread.current.threadDictionary[key] as? NumberFormatter {
            return formatter
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
}

func formatCurrency(_ value: Double) -> String {
    let displayCurrency = UserDefaults.standard.string(forKey: DefaultsKey.displayCurrency) ?? "USD"

    let displayValue = displayCurrency == "CNY" ? value * AppSettings.cnyPerUSD : value
    let symbol = displayCurrency == "CNY" ? "¥" : "$"

    // 智能精度：精确为 0 → "$0"；极小额（>0 且 <0.01）→ "<$0.01"（不再堆四位 0）；其余统一 2 位。
    if displayValue < 0.000_000_1 {
        return "\(symbol)0"
    }
    if displayValue < 0.01 {
        return "<\(symbol)0.01"
    }
    let formatter = NumberFormatterCache.currencyFormatter(symbol: symbol, fractionDigits: 2)
    return formatter.string(from: NSNumber(value: displayValue)) ?? "\(symbol)0.00"
}

/// 紧凑费用格式（菜单栏 / 状态栏图标用）：跟随「显示货币」做 USD→CNY 近似换算并换符号，
/// 同时保留紧凑档位（<1 两位、<100 一位、其余整数），兼顾省空间与币种一致。
func formatCurrencyCompact(_ usd: Double) -> String {
    let isCNY = (UserDefaults.standard.string(forKey: DefaultsKey.displayCurrency) ?? "USD") == "CNY"
    let symbol = isCNY ? "¥" : "$"
    let value = isCNY ? usd * AppSettings.cnyPerUSD : usd
    if value <= 0 { return "\(symbol)0" }
    if value < 1 { return String(format: "\(symbol)%.2f", value) }
    if value < 100 { return String(format: "\(symbol)%.1f", value) }
    return String(format: "\(symbol)%.0f", value)
}

extension Int {
    func clamped(to range: ClosedRange<Int>, fallback: Int) -> Int {
        if self == 0 { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func formatCompactNumber(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}

func formatNumber(_ value: Int) -> String {
    let formatter = NumberFormatterCache.decimalFormatter()
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func stablePaletteIndex(for value: String, paletteCount: Int) -> Int {
    guard paletteCount > 0 else { return 0 }

    let hash = value.unicodeScalars.reduce(5381) { partial, scalar in
        ((partial << 5) &+ partial) &+ Int(scalar.value)
    }

    return abs(hash) % paletteCount
}

struct StatsLegendChip: View {
    let color: Color
    let title: String
    let value: String?

    init(color: Color, title: String, value: String? = nil) {
        self.color = color
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Secure Key Field
// 带「眼睛」显隐开关的密钥输入框（三个代理编辑器共用，源自 OpenCode 编辑器）。

struct SecureKeyField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    init(_ placeholder: String = "sk-...", text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(L("Show / hide key", "显示 / 隐藏密钥"))
        }
    }
}

func parseISO8601(_ value: String) -> Date? {
    SharedFormatters.parseISO8601(value)
}

func membershipBadgeTint(for label: String?) -> Color {
    guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty else {
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    }

    let normalized = label.lowercased()

    if normalized.contains("enterprise") {
        return Color(red: 0.78, green: 0.25, blue: 0.34)
    }
    if normalized.contains("business") || normalized.contains("team") {
        return Color(red: 0.85, green: 0.61, blue: 0.15)
    }
    if normalized.contains("ultra") || normalized.contains("max") || normalized.contains("premium") {
        return Color(red: 0.73, green: 0.32, blue: 0.88)
    }
    if normalized.contains("pro") {
        return Color(red: 0.16, green: 0.74, blue: 0.46)
    }
    if normalized.contains("plus") {
        return Color(red: 0.36, green: 0.47, blue: 0.98)
    }
    if normalized.contains("hobby") {
        return Color(red: 0.17, green: 0.70, blue: 0.72)
    }
    if normalized.contains("free") {
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    }
    if normalized.contains("local") {
        return Color(red: 0.42, green: 0.49, blue: 0.58)
    }

    return Color(red: 0.39, green: 0.60, blue: 0.93)
}

func preferredAccountIdentityLabel(_ candidates: [String?], excluding excluded: String? = nil) -> String? {
    let normalizedExcluded = excluded?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    let cleaned = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }

    guard !cleaned.isEmpty else { return nil }

    let prioritized = (cleaned.first { $0.contains("@") } ?? cleaned.first)
        .flatMap { label in
            label == normalizedExcluded ? nil : label
        }

    if let prioritized {
        return prioritized
    }

    return cleaned.first { $0 != normalizedExcluded }
}

func accountIdentityIcon(for _: String?) -> String {
    "person.crop.circle"
}

// MARK: - Quota Reset Formatting
// 配额窗口（5h / 周 / 月度等）刷新倒计时的统一格式化与紧急度染色。
// 数据来源: QuotaWindow.resetAt（ISO8601 字符串）。卡片视图与菜单栏共用，避免重复实现。

enum QuotaResetFormatter {
    /// 解析 resetAt（ISO8601），返回距 `now` 的剩余秒数（clamp >= 0）；无法解析返回 nil。
    static func remainingSeconds(resetAt: String?, now: Date = Date()) -> Int? {
        guard let resetAt, let date = SharedFormatters.parseISO8601(resetAt) else { return nil }
        return max(0, Int(date.timeIntervalSince(now)))
    }

    /// 紧凑倒计时文本：`2d 3h` / `3h 20m` / `15m` / 即将刷新。无 resetAt 时返回 nil。
    static func compactText(resetAt: String?, language: String, now: Date = Date()) -> String? {
        guard let remaining = remainingSeconds(resetAt: resetAt, now: now) else { return nil }
        if remaining == 0 { return language == "zh" ? "即将刷新" : (language == "vi" ? "sắp đặt lại" : "soon") }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    /// 紧急度染色：<1h 红、<6h 橙，其余返回 `fallback`（默认次要色）。
    static func highlightColor(resetAt: String?, fallback: Color = .secondary, now: Date = Date()) -> Color {
        guard let remaining = remainingSeconds(resetAt: resetAt, now: now) else { return fallback }
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return fallback
    }
}
