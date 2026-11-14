import SwiftUI

extension SettingsView {

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func quotaStyleTitle(_ style: CardQuotaIndicatorStyle) -> String {
        switch style {
        case .bar:
            return L("Bar", "条形")
        case .ring:
            return L("Ring", "圆环")
        case .segments:
            return L("Segments", "分段")
        }
    }

    func autoRefreshTitle(for interval: Int) -> String {
        switch interval {
        case 0:
            return L("Off", "关闭")
        case 30:
            return L("30 seconds", "30 秒")
        case 60:
            return L("1 minute", "1 分钟")
        case 180:
            return L("3 minutes", "3 分钟")
        case 300:
            return L("5 minutes", "5 分钟")
        case 600:
            return L("10 minutes", "10 分钟")
        case 900:
            return L("15 minutes", "15 分钟")
        case 1800:
            return L("30 minutes", "30 分钟")
        case 3600:
            return L("1 hour", "1 小时")
        default:
            return interval >= 60
                ? L("\(interval / 60) minutes", "\(interval / 60) 分钟", "\(interval / 60) phút")
                : L("\(interval) seconds", "\(interval) 秒", "\(interval) giây")
        }
    }

    func claudeCodeRefreshTitle(for interval: Int) -> String {
        switch interval {
        case 0:
            return L("Off", "关闭")
        case 10:
            return L("10 seconds", "10 秒")
        case 30:
            return L("30 seconds", "30 秒")
        case 60:
            return L("1 minute", "1 分钟")
        case 180:
            return L("3 minutes", "3 分钟")
        case 300:
            return L("5 minutes", "5 分钟")
        case 600:
            return L("10 minutes", "10 分钟")
        default:
            return interval >= 60
                ? L("\(interval / 60) minutes", "\(interval / 60) 分钟", "\(interval / 60) phút")
                : L("\(interval) seconds", "\(interval) 秒", "\(interval) giây")
        }
    }

    func quotaMetricTitle(_ metric: CardQuotaIndicatorMetric) -> String {
        switch metric {
        case .remaining:
            return L("Remaining", "剩余")
        case .used:
            return L("Used", "已用")
        }
    }
}
