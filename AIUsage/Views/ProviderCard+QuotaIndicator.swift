import SwiftUI
import QuotaBackend

struct QuotaIndicatorView: View {
    let remainingPercent: Double
    let accentColor: Color
    var resetAt: String?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private let segmentHeights: [CGFloat] = [14, 18, 24, 32, 40, 48, 48, 40, 32, 24, 18, 14]
    private var clampedRemaining: Double {
        min(max(remainingPercent, 0), 100)
    }

    private var displayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var metricLabel: String {
        settings.quotaIndicatorMetric == .remaining ? L("Remaining", "剩余") : L("Used", "已用")
    }

    private var inlineResetText: String? {
        guard let resetAt, let date = parseResetDate(resetAt) else { return nil }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining == 0 {
            switch appState.language {
            case "zh": return "即将刷新"
            case "vi": return "sắp đặt lại"
            default: return "soon"
            }
        }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private var inlineResetColor: Color {
        guard let resetAt, let date = parseResetDate(resetAt) else { return .secondary }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return .secondary
    }

    private func parseResetDate(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...:
            return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...:
            return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:
            return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var semanticGradientColors: [Color] {
        switch clampedRemaining {
        case 70...:
            return [
                Color(red: 0.37, green: 0.94, blue: 0.62),
                Color(red: 0.11, green: 0.74, blue: 0.39)
            ]
        case 35...:
            return [
                Color(red: 1.00, green: 0.84, blue: 0.34),
                Color(red: 0.96, green: 0.56, blue: 0.17)
            ]
        default:
            return [
                Color(red: 1.00, green: 0.54, blue: 0.28),
                Color(red: 0.90, green: 0.20, blue: 0.29)
            ]
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: semanticGradientColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: [
                semanticGradientColors.first?.opacity(0.45) ?? riskColor.opacity(0.45),
                semanticGradientColors.first ?? riskColor,
                semanticGradientColors.last ?? riskColor,
                semanticGradientColors.last?.opacity(0.45) ?? riskColor.opacity(0.45)
            ],
            center: .center
        )
    }

    private var valueGradient: LinearGradient {
        LinearGradient(
            colors: semanticGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    var body: some View {
        switch settings.quotaIndicatorStyle {
        case .bar:
            barStyle
        case .ring:
            ringStyle
        case .segments:
            segmentsStyle
        }
    }

    private var barStyle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metricLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(valueGradient)

                if let resetText = inlineResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(inlineResetColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(trackColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: 1)
                        )

                    RoundedRectangle(cornerRadius: 8)
                        .fill(meterGradient)
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 12 : 0))
                        .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 10, x: 0, y: 4)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 12 : 0), height: 5)
                        .padding(.top, 1.5)
                }
            }
            .frame(height: 12)
        }
    }

    private var ringStyle: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06))

                Circle()
                    .stroke(trackColor, lineWidth: 10)

                Circle()
                    .trim(from: 0, to: displayPercent / 100)
                    .stroke(ringGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.32 : 0.15), radius: 8, x: 0, y: 4)

                VStack(spacing: 1) {
                    Text(displayText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(valueGradient)
                    Text(metricLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)

            if let resetText = inlineResetText {
                Text(resetText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(inlineResetColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var segmentsStyle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metricLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(valueGradient)

                if let resetText = inlineResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(inlineResetColor)
                }
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(segmentHeights.enumerated()), id: \.offset) { index, height in
                    segment(at: index, height: height)
                }
            }
            .frame(height: 52)
        }
    }

    private func segment(at index: Int, height: CGFloat) -> some View {
        let ratio = segmentFillRatio(for: index)

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5)
                .fill(trackColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(borderColor, lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 5)
                .fill(meterGradient)
                .frame(height: max(height * ratio, ratio > 0 ? 8 : 0))
                .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 4, x: 0, y: 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .bottom)
    }

    private func segmentFillRatio(for index: Int) -> CGFloat {
        let count = Double(segmentHeights.count)
        let start = (Double(index) / count) * 100
        let end = (Double(index + 1) / count) * 100

        if displayPercent >= end {
            return 1
        }
        if displayPercent <= start {
            return 0
        }

        let partial = (displayPercent - start) / (end - start)
        return CGFloat(min(max(partial, 0), 1))
    }
}
