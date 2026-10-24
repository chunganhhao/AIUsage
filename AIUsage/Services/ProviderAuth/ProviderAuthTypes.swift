import Foundation
import QuotaBackend

/// 每个服务商的连接方式。连接弹窗先检测本机已有的登录，没有可连接的会话时才按这里的方式发起新登录。
struct ProviderAuthPlan {
    enum Method {
        /// 官方 `codex login`（隔离的 CODEX_HOME），在浏览器完成 ChatGPT 登录。
        case codexCLI
        /// Gemini / Antigravity：AIUsage 自己接收 Google OAuth 回调。
        case googleOAuth
        /// Copilot：GitHub 设备码授权。
        case githubDevice
        /// Kiro：接入 Kiro 应用的登录（任意方式），或用 AWS Builder ID 设备码授权。
        case kiro
        /// Cursor：AIUsage 内置浏览器登录 cursor.com。
        case embeddedWeb
        /// Kimi / MiniMax / Droid / Warp：粘贴 API Key。
        case apiKey
        /// 未单独适配的服务商：先完成它自己的登录，再回来重新检测。
        case manual
    }

    let method: Method
    /// 标题下的一句话：AIUsage 用什么方式连接、连接后能看到什么。
    let summary: String
    /// 发起新登录的按钮文案。
    let signInTitle: String
    /// 本机没有可连接的登录时的说明。
    let signedOutTitle: String
    let signedOutDetail: String
    var appBundleIdentifier: String? = nil
    var downloadURL: URL? = nil
    /// 服务商自身的限制（如 Google 停止个人账号使用 Gemini CLI），在发起登录前提醒。
    var notice: Notice? = nil

    struct Notice {
        let title: String
        let detail: String
    }
}

struct ProviderAuthCandidate: Identifiable, Hashable {
    enum IdentityScope: String, Hashable {
        case accountScoped
        case sharedSource
    }

    let id: String
    let providerId: String
    let sourceIdentifier: String
    let sessionFingerprint: String?
    let title: String
    let subtitle: String?
    let detail: String
    let modifiedAt: Date?
    let authMethod: AuthMethod
    let credentialValue: String
    let sourcePath: String?
    let shouldCopyFile: Bool
    let identityScope: IdentityScope
    /// 本地就能读到的套餐名（如 Codex id_token、Cursor 应用缓存），用于连接前的账号卡片。
    var plan: String? = nil
}

struct ProviderMonitoredSessionIndex {
    let sourceIdentifiers: Set<String>
    let sessionFingerprints: Set<String>
    let accountHandles: Set<String>
}
