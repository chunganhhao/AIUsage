import SwiftUI

extension SettingsView {

    // MARK: - Remote backend (client side)

    var remoteBackendBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsBlock(
                title: L("Host", "地址"),
                subtitle: L(
                    "Tailscale IP or hostname of the Mac that shares its quotas. A pasted http://host:port also works.",
                    "共享额度的那台 Mac 的 Tailscale IP 或主机名；也可以直接粘贴 http://地址:端口。"
                )
            ) {
                TextField("100.x.x.x", text: $remoteHostInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyRemoteSettings() }
            }

            Divider()

            settingsBlock(title: L("Port", "端口")) {
                TextField("4318", text: $remotePortInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120, alignment: .leading)
                    .onSubmit { applyRemoteSettings() }
            }

            Divider()

            settingsBlock(
                title: L("Access Token", "访问令牌"),
                subtitle: L(
                    "Shown on the host under Settings → Data & Refresh → Share with other devices.",
                    "在主机的「设置 → 数据与刷新 → 共享给其他设备」中查看并复制。"
                )
            ) {
                SecureField("aiu-…", text: $remoteTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyRemoteSettings() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(L("Apply", "应用")) { applyRemoteSettings() }
                        .buttonStyle(.borderedProminent)

                    Button {
                        Task { await testRemoteConnection() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingRemoteConnection {
                                SmallProgressView()
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                            }
                            Text(L("Test Connection", "测试连接"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingRemoteConnection)
                }

                remoteConnectionStatusView

                Text(
                    L(
                        "Remote mode only reads the snapshot the host has already fetched. It never asks the host to refresh or sign in, so accounts stay active on one device only. The refresh interval below controls how often the snapshot is pulled.",
                        "远程模式只读取主机已经获取到的额度快照，不会让主机刷新或登录，账号始终只在主机一处活动。下方的刷新间隔决定多久拉取一次快照。"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var remoteConnectionStatusView: some View {
        let icon: String
        let tint: Color
        let title: String
        switch remoteConnectionState {
        case .idle:
            icon = "network"; tint = .secondary; title = L("Connection not tested", "\u{5C1A}\u{672A}\u{6D4B}\u{8BD5}\u{8FDE}\u{63A5}")
        case .success:
            icon = "checkmark.circle.fill"; tint = .green; title = L("Remote server reachable", "\u{8FDC}\u{7A0B}\u{670D}\u{52A1}\u{53EF}\u{8FDE}\u{63A5}")
        case .failure:
            icon = "xmark.octagon.fill"; tint = .red; title = L("Connection failed", "\u{8FDE}\u{63A5}\u{5931}\u{8D25}")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(remoteConnectionMessage?.nilIfBlank ?? title)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func applyRemoteSettings(refreshDashboard: Bool = true) {
        let parsed = AppSettings.parseRemoteAddress(remoteHostInput)
        if let pastedPort = parsed.port {
            remotePortInput = "\(pastedPort)"
        }
        let port = Int(remotePortInput.trimmingCharacters(in: .whitespaces)) ?? 4318
        remoteHostInput = parsed.host
        settings.remoteHost = parsed.host.isEmpty ? "127.0.0.1" : parsed.host
        settings.remotePort = port

        let token = remoteTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteTokenInput = token
        QuotaShareTokenStore.save(token, slot: .remote)
        APIService.shared.updateAccessToken(token)

        settings.saveSettings()
        remoteConnectionState = .idle
        remoteConnectionMessage = nil
        if refreshDashboard {
            refreshCoordinator.refreshAllProviders()
        }
    }

    @MainActor
    func testRemoteConnection() async {
        applyRemoteSettings(refreshDashboard: false)
        isTestingRemoteConnection = true
        defer { isTestingRemoteConnection = false }

        APIService.shared.updateBaseURL(settings.remoteBaseURL)
        let startedAt = Date()

        do {
            _ = try await APIService.shared.checkHealth()
            let dashboard = try await APIService.shared.fetchDashboard()
            let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            remoteConnectionState = .success
            remoteConnectionMessage = L(
                "Connected · \(dashboard.providers.count) accounts · \(latencyMs) ms",
                "已连接 · \(dashboard.providers.count) 个账号 · 耗时 \(latencyMs) ms",
                "Đã kết nối · \(dashboard.providers.count) tài khoản · \(latencyMs) ms"
            )
            // 首次连上时把主机共享的服务商加入本机勾选，否则仪表盘只显示本机原先勾选的那部分；
            // 之后的刷新仍以本机勾选为准，用户取消勾选不会被反复加回。
            let catalogIds = Set(refreshCoordinator.providerCatalogIds())
            for providerId in Set(dashboard.providers.map(\.providerId)) where catalogIds.contains(providerId) {
                refreshCoordinator.ensureProviderSelected(providerId)
            }
            refreshCoordinator.refreshAllProviders()
        } catch {
            remoteConnectionState = .failure
            remoteConnectionMessage = error.localizedDescription
        }
    }

    // MARK: - Share with other devices (host side)

    var quotaShareBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsToggleRow(
                title: L("Share with Other Devices", "共享给其他设备"),
                subtitle: L(
                    "Let AIUsage on another Mac (e.g. over Tailscale) show this Mac's quotas in Remote mode. Read-only: other devices never trigger a refresh here and never need to sign in.",
                    "让其他 Mac 上处于「远程」模式的 AIUsage（例如通过 Tailscale）显示本机的额度。只读：其他设备不会触发本机刷新，也不需要登录账号。"
                ),
                isOn: $settings.shareQuotaEnabled
            )

            if settings.shareQuotaEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    quotaShareStatusView

                    HStack(spacing: 10) {
                        Text(L("Port", "端口"))
                            .font(.subheadline.weight(.semibold))
                        TextField("4318", text: $sharePortInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit { applySharePort() }
                        Button(L("Apply", "应用")) { applySharePort() }
                            .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Address to enter on the other device", "在其他设备上填写的地址"))
                            .font(.subheadline.weight(.semibold))

                        if shareAddresses.isEmpty {
                            Text(L(
                                "No Tailscale or local network address detected. Connect Tailscale on this Mac first.",
                                "未检测到 Tailscale 或局域网地址，请先在本机连上 Tailscale。"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            ForEach(shareAddresses) { address in
                                HStack(spacing: 8) {
                                    Text(address.kind == .tailscale ? "Tailscale" : L("LAN", "局域网"))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill((address.kind == .tailscale ? Color.blue : Color.gray).opacity(0.15)))
                                    Text(address.ip)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    copyShareValueButton(address.ip)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Access Token", "访问令牌"))
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            Text(isShareTokenRevealed ? quotaShare.hostToken : String(repeating: "•", count: 16))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                isShareTokenRevealed.toggle()
                            } label: {
                                Image(systemName: isShareTokenRevealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(isShareTokenRevealed ? L("Hide", "隐藏") : L("Show", "显示"))
                            copyShareValueButton(quotaShare.hostToken)
                            Button(L("Regenerate", "重新生成")) {
                                quotaShare.regenerateToken()
                                isShareTokenRevealed = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text(L(
                        "Only connections from Tailscale, the local network, or this Mac are accepted, and each request must carry the token. After regenerating the token, update it on the other devices.",
                        "仅接受来自 Tailscale、局域网或本机的连接，且每次请求都必须携带令牌。重新生成令牌后，需要在其他设备上同步更新。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                .onAppear { shareAddresses = QuotaShareService.shareAddresses() }
            }
        }
    }

    private var quotaShareStatusView: some View {
        let icon: String
        let tint: Color
        let text: String
        var showsRetry = false
        switch quotaShare.status {
        case .off, .starting:
            icon = "hourglass"; tint = .secondary; text = L("Starting…", "正在启动…")
        case .running(let port):
            icon = "dot.radiowaves.left.and.right"; tint = .green
            text = L("Sharing on port \(port)", "正在共享 · 端口 \(port)", "Đang chia sẻ ở cổng \(port)")
        case .failed(let message, let portInUse):
            icon = "exclamationmark.triangle.fill"; tint = .orange; showsRetry = true
            text = portInUse
                ? L(
                    "Port \(settings.shareQuotaPort) is already in use. Choose another port.",
                    "端口 \(settings.shareQuotaPort) 已被占用，请换一个端口。",
                    "Cổng \(settings.shareQuotaPort) đang được sử dụng. Hãy chọn cổng khác."
                )
                : L("Sharing failed: \(message)", "共享启动失败：\(message)", "Chia sẻ thất bại: \(message)")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showsRetry {
                Button(L("Retry", "重试")) { quotaShare.restartServer() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func copyShareValueButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            recentlyCopiedShareValue = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if recentlyCopiedShareValue == value { recentlyCopiedShareValue = nil }
            }
        } label: {
            Image(systemName: recentlyCopiedShareValue == value ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L("Copy", "复制"))
    }

    private func applySharePort() {
        guard let port = Int(sharePortInput.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else {
            sharePortInput = "\(settings.shareQuotaPort)"
            return
        }
        sharePortInput = "\(port)"
        if port == settings.shareQuotaPort {
            quotaShare.restartServer()
        } else {
            settings.shareQuotaPort = port
        }
    }
}
