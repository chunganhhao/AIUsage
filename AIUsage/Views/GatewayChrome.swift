import AppKit
import SwiftUI

// MARK: - Gateway Chrome
// 账号中心 / 概览共用的紧凑胶囊统计与筛选样式（偏 macOS 原生：不拉满宽、少边框噪音）。

struct GatewayStatCapsule: View {
    let value: String
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var isSelected: Bool = false
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let content = HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: Circle())
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppContent.primary(colorScheme))
            Text(title)
                .font(.caption)
                .foregroundStyle(AppContent.secondary(colorScheme))
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            (isSelected ? tint.opacity(0.16) : AppSurface.chip(colorScheme)),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(action != nil ? .isButton : [])

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

struct GatewayStatCapsuleRow: View {
    struct Item: Identifiable {
        let id: String
        let value: String
        let title: String
        let systemImage: String
        let tint: Color
    }

    let items: [Item]
    var selectedId: String?
    var onSelect: ((String) -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    capsule(item)
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(items) { item in
                    capsule(item)
                }
            }
        }
    }

    private func capsule(_ item: Item) -> some View {
        GatewayStatCapsule(
            value: item.value,
            title: item.title,
            systemImage: item.systemImage,
            tint: item.tint,
            isSelected: selectedId == item.id,
            action: onSelect.map { handler in { handler(item.id) } }
        )
    }
}

struct GatewayCapsuleFilterBar<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(values, id: \.self) { value in
                    let selected = selection == value
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = value }
                    } label: {
                        Text(title(value))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Color.accentColor : AppContent.secondary(colorScheme))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selected ? Color.accentColor.opacity(0.16) : AppSurface.chip(colorScheme))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        selected ? Color.accentColor.opacity(0.28) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Account filter", "账号筛选"))
    }
}

struct GatewayCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(padding: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppSurface.card(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppStroke.card(colorScheme), lineWidth: 1)
            )
            .shadow(color: AppShadow.card(colorScheme), radius: colorScheme == .dark ? 0 : 8, y: 3)
    }
}

struct GatewayQuietBadge: View {
    let text: String
    var tint: Color = .secondary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? AppContent.secondary(colorScheme) : tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (tint == .secondary ? AppSurface.chip(colorScheme) : tint.opacity(colorScheme == .dark ? 0.18 : 0.12)),
                in: Capsule()
            )
            .accessibilityLabel(text)
    }
}
