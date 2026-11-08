import SwiftUI

// MARK: - Sidebar Navigation Model
// 主侧边栏导航条目的唯一数据源：同时驱动 ContentView 的 NavigationSplitView 列表
// 与「设置 → 通用」里的侧边栏可见性开关，避免两处条目/图标/文案各写一份导致漂移。
// 数据来源: 内置静态条目；隐藏状态来自 AppSettings.hiddenSidebarSections（UserDefaults）。

/// 单个侧边栏导航条目的展示元数据。
struct SidebarNavItem: Identifiable {
    /// 条目图标：系统 SF Symbol 或品牌资产（代理入口用品牌图标）。
    enum Icon {
        case system(String)
        case providerAsset(String)
    }

    let section: AppSection
    let titleEn: String
    let titleZh: String
    let localizationKey: String
    let icon: Icon
    let tint: Color
    /// 仪表盘与设置常驻，保证用户隐藏其它入口后仍能回到设置恢复。
    let isHideable: Bool
    var groupSubtitleEn: String? = nil
    var groupSubtitleZh: String? = nil

    var id: AppSection { section }
    var title: String { L(titleEn, titleZh, key: localizationKey) }
    var settingsTitle: String {
        guard let groupSubtitleEn, let groupSubtitleZh else { return title }
        return "\(title) (\(L(groupSubtitleEn, groupSubtitleZh)))"
    }
}

/// 侧边栏导航条目集合与可见性过滤。
enum SidebarNavigation {
    /// 本地应用分组标题（可折叠 Section 的 header，位于代理分组上方）。
    static var localGroupTitle: String {
        L("Local", "本地", key: "nav.group.local")
    }

    /// 代理分组标题（可折叠 Section 的 header）。
    static var proxiesGroupTitle: String {
        L("Proxies", "代理", key: "nav.group.proxies")
    }

    /// 本地与代理分组上方的主条目。
    static let primaryTop: [SidebarNavItem] = [
        SidebarNavItem(section: .dashboard, titleEn: "Dashboard", titleZh: "仪表盘",
                       localizationKey: "nav.dashboard", icon: .system("chart.bar.doc.horizontal"),
                       tint: .blue, isHideable: false),
        SidebarNavItem(section: .sessions, titleEn: "Sessions", titleZh: "会话",
                       localizationKey: "nav.sessions", icon: .system("bubble.left.and.text.bubble.right.fill"),
                       tint: .cyan, isHideable: true),
        SidebarNavItem(section: .providerAccounts, titleEn: "Subscriptions", titleZh: "订阅账号",
                       localizationKey: "nav.provider_accounts", icon: .system("person.2.crop.square.stack.fill"),
                       tint: .indigo, isHideable: true),
        SidebarNavItem(section: .subscriptionGateway, titleEn: "CPA Gateway", titleZh: "CPA 网关",
                       localizationKey: "nav.subscription_gateway", icon: .providerAsset("cliproxyapi"),
                       tint: .purple, isHideable: true),
        SidebarNavItem(section: .apiProviders, titleEn: "API Providers", titleZh: "API 提供商",
                       localizationKey: "nav.api_providers", icon: .system("shippingbox.fill"),
                       tint: .teal, isHideable: true)
    ]

    /// 可折叠的「本地」分组：管理本机安装的 Codex / Antigravity 客户端账号切换、重启与环境规则。
    static let local: [SidebarNavItem] = [
        SidebarNavItem(section: .codexLocalManagement, titleEn: "Codex", titleZh: "Codex",
                       localizationKey: "nav.codex_local_management", icon: .providerAsset("codex"),
                       tint: .primary, isHideable: true,
                       groupSubtitleEn: "Local", groupSubtitleZh: "本地"),
        SidebarNavItem(section: .antigravityManagement, titleEn: "Antigravity", titleZh: "Antigravity",
                       localizationKey: "nav.antigravity_management", icon: .providerAsset("antigravity"),
                       tint: .primary, isHideable: true,
                       groupSubtitleEn: "Local", groupSubtitleZh: "本地")
    ]

    /// 可折叠的「代理」分组：分组标题已表达“代理”语义，条目只保留应用名。
    static let proxies: [SidebarNavItem] = [
        SidebarNavItem(section: .codexProxyManagement, titleEn: "Codex", titleZh: "Codex",
                       localizationKey: "nav.codex_proxy_management", icon: .providerAsset("codex"),
                       tint: .primary, isHideable: true,
                       groupSubtitleEn: "Proxy", groupSubtitleZh: "代理"),
        SidebarNavItem(section: .proxyManagement, titleEn: "Claude", titleZh: "Claude",
                       localizationKey: "nav.proxy_management", icon: .providerAsset("claude"),
                       tint: .primary, isHideable: true,
                       groupSubtitleEn: "Proxy", groupSubtitleZh: "代理"),
        SidebarNavItem(section: .opencodeManagement, titleEn: "OpenCode", titleZh: "OpenCode",
                       localizationKey: "nav.opencode_management", icon: .providerAsset("opencode"),
                       tint: .primary, isHideable: true,
                       groupSubtitleEn: "Proxy", groupSubtitleZh: "代理")
    ]

    /// 代理分组下方的主条目。
    static let primaryBottom: [SidebarNavItem] = [
        SidebarNavItem(section: .costTracking, titleEn: "Usage Stats", titleZh: "用量统计",
                       localizationKey: "nav.cost_tracking", icon: .system("chart.bar.xaxis"),
                       tint: .green, isHideable: true),
        SidebarNavItem(section: .callAnalytics, titleEn: "Call Analytics", titleZh: "调用分析",
                       localizationKey: "nav.call_analytics", icon: .system("puzzlepiece.extension"),
                       tint: .purple, isHideable: true)
    ]

    /// 分隔线上方的全部主条目（含本地与代理分组，供设置页等平铺场景使用）。
    static let primary: [SidebarNavItem] = primaryTop + local + proxies + primaryBottom

    /// 分隔线下方的次分组（消息 + 设置）。
    static let secondary: [SidebarNavItem] = [
        SidebarNavItem(section: .inbox, titleEn: "Inbox", titleZh: "消息",
                       localizationKey: "nav.inbox", icon: .system("bell.fill"),
                       tint: .orange, isHideable: true),
        SidebarNavItem(section: .settings, titleEn: "Settings", titleZh: "设置",
                       localizationKey: "nav.settings", icon: .system("gearshape"),
                       tint: .gray, isHideable: false)
    ]

    static let all: [SidebarNavItem] = primary + secondary

    /// 可被用户隐藏的条目（设置页据此渲染开关列表）。
    static let hideable: [SidebarNavItem] = all.filter(\.isHideable)

    /// 过滤掉已隐藏的条目；常驻条目不受影响。
    static func visible(_ items: [SidebarNavItem], hidden: Set<String>) -> [SidebarNavItem] {
        items.filter { !$0.isHideable || !hidden.contains($0.section.rawValue) }
    }
}
