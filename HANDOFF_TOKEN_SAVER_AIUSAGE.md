# HANDOFF: Tích Hợp Bộ Token Saver An Toàn Vào CPA Gateway (AIUsage)

> **Dành cho:** Codex / Agent phát triển tiếp theo  
> **Dự án:** `AIUsage` (macOS Native SwiftUI App + SwiftPM package `QuotaBackend`)  
> **Thư mục làm việc:** `/Users/apple/Downloads/Repo Github/AIUsage`  
> **Nhánh mục tiêu (Branch):** `personal-build` (hoặc tạo nhánh `feat/token-saver-integration` từ `personal-build`)  
> **Ngày cập nhật:** 29-10-2026

---

## 1. Bối Cảnh & Tôn Chỉ Tối Thượng (Zero-Risk Architecture)

> [!IMPORTANT]
> **LOẠI BỎ HOÀN TOÀN HEADROOM**: Không đưa Headroom vào codebase vì tiềm ẩn rủi ro phá vỡ chữ ký mật mã `thinking.signature` của Claude 3.7+, làm lệch TLS fingerprint và ngốn thêm ~1GB RAM máy người dùng.
> 
> Bộ Token Saver của AIUsage chỉ tập trung vào **"Bộ Ba An Toàn Tuyệt Đối 100%" (The Safe Trio)**:
> 1. **RTK (Rust Token Killer)**: Lọc rác terminal/tool output (60–90% input tokens).
> 2. **Caveman**: Ép model trả lời tinh gọn, bỏ hoa mỹ (40–65% output tokens).
> 3. **Ponytail**: Tư duy kiến trúc tối giản, YAGNI, stdlib-first (45–53% toàn session).

### 3 Yêu cầu bắt buộc cần thực hiện:
1. **Sửa dứt điểm UX/UI nút `Antigravity pool protection (opt-in)`**:  
   Chuyển từ ô checkbox lạc quẻ sang dạng **Nút gạt Switch (`.toggleStyle(.switch)`) nằm bên phải, màu tím**, đồng bộ 100% với các thẻ `Launch with app` và `Auto refresh`.
2. **Dựng Thẻ `Token Saver` trong `Gateway Settings -> Runtime`**:
   - **`Compress tool output (RTK)`**: Hỗ trợ toàn diện **Antigravity** (qua shell hook / zsh wrapper), Claude Code, Codex và OpenCode.
   - **`Compress LLM output (Caveman)`**: Nút gạt + Segmented Picker 3 chế độ `[Lite | Full | Ultra]`.
   - **`Lazy senior dev (Ponytail)`**: Nút gạt kích hoạt triết lý code tối giản (YAGNI, stdlib-first).
   - **`Coding-Only Scope Filter` (Rào chắn an toàn)**: Chỉ áp dụng cho các coding agent; tự động bypass đối với các request kịch bản RonC và Zalo bot để không làm hỏng văn phong sáng tạo.
3. **Cơ chế Cập nhật Phiên bản (Updates Tab)**:
   - Thêm phần kiểm tra phiên bản cho các quy tắc (Rules) và binary của Token Saver trong tab `Updates` (`Installed` vs `Latest` + nút `[Check]` / `[Update]`), tái sử dụng mẫu thiết kế của `CLIProxyGatewayManager`.

---

## 2. Bản Đồ File & Vị Trí Cần Chỉnh Sửa

| Tác vụ | File ảnh hưởng | Vị trí / Mô tả chi tiết |
| :--- | :--- | :--- |
| **1. Sửa Switch UI** | `AIUsage/Views/SubscriptionGatewaySettingsRuntimePane.swift` | Sửa `poolProtectionSection` (dòng ~160–182). Chuyển `Toggle` checkbox sang `compactToggle` hoặc `HStack + Spacer + Toggle.toggleStyle(.switch).tint(.purple)`. |
| **2. Dựng Card Token Saver** | `AIUsage/Views/SubscriptionGatewaySettingsRuntimePane.swift` | Thêm biến `tokenSaverSection: some View` và nhúng vào `body` ngay dưới `poolProtectionSection`. |
| **3. Lưu trữ cài đặt** | `QuotaBackend/Sources/QuotaBackend/Utilities/TokenSaverSettings.swift` *(File mới)* | Quản lý lưu trữ trạng thái người dùng vào `~/Library/Application Support/AIUsage/token-saver-settings.json`. Đọc/ghi atomic an toàn với thread lock. |
| **4. Cập nhật Updates Tab** | `AIUsage/Views/SubscriptionGatewaySettingsView.swift` | Mở rộng `updatesSection` (dòng ~198–245). Dùng `versionChip` hiển thị phiên bản `Installed` vs `Latest` cho Ponytail (`v5.3.3`), Caveman (`v4.0.2`), RTK (`v1.1.0`). |
| **5. GitHub Release Client** | `AIUsage/Services/TokenSaverReleaseManager.swift` *(File mới)* | Gửi request `GET` tới GitHub API lấy latest release tag của `DietrichGebert/ponytail`, `JuliusBrussee/caveman`, `rtk-ai/rtk`. Hỗ trợ tải raw file `SKILL.md` về máy. |

---

## 3. Chi Tiết Triển Khai Code Mẫu (Implementation Snippets)

### 3.1. Sửa `poolProtectionSection` trong `SubscriptionGatewaySettingsRuntimePane.swift`:
```swift
private var poolProtectionSection: some View {
    GatewayCard {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Antigravity pool protection (opt-in)", "Antigravity 分池保护（主动开启）"))
                    .font(.subheadline.weight(.medium))
                Text(L("Off by default. Requires CPA 8.0.43+. Writes model exclusions for depleted Gemini, Claude/GPT or Argon pools, without disabling other pools. Turning off restores only unchanged protection-owned exclusions. Codex and gateway routing policy are not modified.", "默认关闭，需要 CPA 8.0.43 或更新版本。对耗尽的 Gemini、Claude/GPT 或 Argon 池写入模型排除规则，不停用其他池。关闭时仅恢复未被外部修改的保护规则，不修改 Codex 或网关路由策略。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let poolProtectionError {
                    Text(poolProtectionError).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(
                get: { poolProtectionEnabled },
                set: { enabled in
                    do {
                        try AntigravityPoolProtectionSettings.setEnabled(enabled)
                        poolProtectionEnabled = enabled
                        poolProtectionError = nil
                    } catch {
                        poolProtectionError = L("Could not update protection. Check the CPA version, model exclusions and file permissions.", "无法更新保护设置，请检查 CPA 版本、模型排除规则和文件权限。")
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.purple)
            .accessibilityIdentifier("antigravity-pool-protection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
    .onAppear { poolProtectionEnabled = AntigravityPoolProtectionSettings.isEnabled() }
}
```

### 3.2. Thêm `tokenSaverSection` trong `SubscriptionGatewaySettingsRuntimePane.swift` (Không có Headroom):
```swift
private var tokenSaverSection: some View {
    GatewayCard {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text(L("Token Saver & Context Optimization", "Token 优化与上下文精简"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // 1. RTK Toggle (Tool output - Antigravity, Claude, Codex)
            compactToggleWithSubtitle(
                title: L("Compress tool output (RTK)", "压缩终端工具输出 (RTK)"),
                subtitle: L("git/grep/ls/tree/test logs -> 60-90% fewer input tokens. Fully supports Antigravity, Claude, Codex.", "精简终端与测试输出，减少 60-90% 输入 Token。全面支持 Antigravity、Claude、Codex。"),
                isOn: $tokenSaverSettings.rtkEnabled
            )

            Divider()

            // 2. Caveman Toggle + Mode Picker (Output Prose)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Compress LLM output (Caveman)", "精简模型回复 (Caveman)"))
                            .font(.subheadline.weight(.medium))
                        Text(L("Terse-style system prompt -> drops filler words, keeps code exact.", "注入精简提示词：剔除寒暄废话，严格保留代码与路径。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $tokenSaverSettings.cavemanMode) {
                        Text("Lite").tag(TokenSaverSettings.CavemanMode.lite)
                        Text("Full").tag(TokenSaverSettings.CavemanMode.full)
                        Text("Ultra").tag(TokenSaverSettings.CavemanMode.ultra)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                    .disabled(!tokenSaverSettings.cavemanEnabled)

                    Toggle("", isOn: $tokenSaverSettings.cavemanEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.purple)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 3. Ponytail Toggle (Minimal code ladder)
            compactToggleWithSubtitle(
                title: L("Lazy senior dev (Ponytail)", "极简高级架构师模式 (Ponytail)"),
                subtitle: L("Bias model toward minimal code: YAGNI, reuse stdlib, deletion over addition.", "引导模型编写最简代码：优先复用标准库，拒绝过度封装。"),
                isOn: $tokenSaverSettings.ponytailEnabled
            )

            Divider()

            // 4. Safety Scope Guard (Bảo vệ kịch bản RonC & Zalo bot)
            compactToggleWithSubtitle(
                title: L("Apply to Coding Agents only", "仅对编程 Agent 生效（隔离文案与对话机器人）"),
                subtitle: L("Bypasses compression for creative scripts (RonC) and customer-care chatbots (Zalo).", "自动放行 RonC 视频脚本与 Zalo 客服会话，避免误伤文案与情感语调。"),
                isOn: $tokenSaverSettings.codingOnlyScope,
                tintColor: .indigo
            )
        }
    }
}
```

---

## 4. Quản Lý Phiên Bản Trong Tab Updates (`TokenSaverReleaseManager`)

1. **Check Updates**: Gọi GitHub API:
   - `https://api.github.com/repos/DietrichGebert/ponytail/releases/latest`
   - `https://api.github.com/repos/JuliusBrussee/caveman/releases/latest`
   - `https://api.github.com/repos/rtk-ai/rtk/releases/latest`
2. **Apply Updates**:
   - Với Ponytail & Caveman: Tải file text `SKILL.md` và lưu đè vào `~/Library/Application Support/AIUsage/Rules/`. Cập nhật trong 0.2s mà không cần restart CPA Gateway.
   - Với RTK: Cập nhật qua Homebrew (`brew upgrade rtk`) hoặc tải binary release nếu cài độc lập.

---

## 5. Quy Trình Kiểm Thử (Verification Steps)

1. **Typecheck & Swift Build**:
   ```bash
   cd "/Users/apple/Downloads/Repo Github/AIUsage"
   xcodebuild -scheme AIUsage -configuration Debug build
   ```
2. **Chạy Unit Tests**:
   ```bash
   swift test --package-path QuotaBackend
   ```
3. **Kiểm tra UI**:
   - Xác nhận nút `Antigravity pool protection` là Switch bên phải màu tím.
   - Xác nhận thẻ `Token Saver` chỉ có 3 công cụ an toàn: RTK, Caveman, Ponytail, và bộ lọc Coding-only.
