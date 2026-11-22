import SwiftUI

// MARK: - Sidebar Visibility Settings
// 集中管理左侧导航入口的显示/隐藏，与侧边栏右键「隐藏」互通（共享 AppSettings.hiddenSidebarSections）。
// 条目/图标/文案均取自 SidebarNavigation.hideable，保证与实际侧边栏完全一致，避免两处漂移。

extension SettingsView {

    var sidebarVisibilityBlock: some View {
        settingsBlock(
            title: L("Sidebar", "侧边栏"),
            subtitle: L(
                "Choose which entries appear in the left navigation. Hidden ones can be restored here anytime.",
                "选择左侧导航中显示哪些入口。已隐藏的入口可随时在此恢复。"
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SidebarNavigation.hideable) { item in
                    sidebarVisibilityRow(item)
                }

                if !settings.hiddenSidebarSections.isEmpty {
                    Button {
                        settings.hiddenSidebarSections = []
                    } label: {
                        Label(L("Show All", "全部显示", key: "sidebar.show_all"), systemImage: "eye")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 6)
                }
            }
        }
    }

    private func sidebarVisibilityRow(_ item: SidebarNavItem) -> some View {
        HStack(spacing: 10) {
            sidebarVisibilityIcon(item)
                .frame(width: 20, height: 20)
            Text(item.settingsTitle)
                .font(.subheadline)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { !settings.hiddenSidebarSections.contains(item.section.rawValue) },
                set: { isVisible in
                    var hidden = settings.hiddenSidebarSections
                    if isVisible {
                        hidden.remove(item.section.rawValue)
                    } else {
                        hidden.insert(item.section.rawValue)
                    }
                    settings.hiddenSidebarSections = hidden
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sidebarVisibilityIcon(_ item: SidebarNavItem) -> some View {
        switch item.icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(item.tint)
        case .providerAsset(let asset):
            ProviderIconView(asset, size: 16)
        }
    }
}
