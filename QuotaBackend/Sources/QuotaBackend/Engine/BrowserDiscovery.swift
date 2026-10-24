import Foundation

/// Scans installed browsers on macOS and reports which have usable sessions
/// for a given provider. Shared across all cookie-based providers.
public enum BrowserDiscovery {

    public struct BrowserProfile: Sendable {
        public let browserName: String
        public let profileName: String
        public let cookiesDBPath: String
        public let keychainService: String
        public let isAvailable: Bool
    }

    public struct DiscoveredSession: Sendable {
        public let browserName: String
        public let profileName: String
        public let cookieHeader: String
        public let accountHint: String?
    }

    // MARK: - All Known Browsers

    private static func allBrowserProfiles(home: String) -> [BrowserProfile] {
        let fm = FileManager.default
        var profiles: [BrowserProfile] = []

        let chromeBase = "\(home)/Library/Application Support/Google/Chrome"
        profiles.append(contentsOf: discoverChromiumProfiles(
            base: chromeBase, browserName: "Chrome", keychainService: "Chrome Safe Storage", fm: fm
        ))

        let arcBase = "\(home)/Library/Application Support/Arc/User Data"
        profiles.append(contentsOf: discoverChromiumProfiles(
            base: arcBase, browserName: "Arc", keychainService: "Arc Safe Storage", fm: fm
        ))

        let edgeBase = "\(home)/Library/Application Support/Microsoft Edge"
        profiles.append(contentsOf: discoverChromiumProfiles(
            base: edgeBase, browserName: "Edge", keychainService: "Microsoft Edge Safe Storage", fm: fm
        ))

        let braveBase = "\(home)/Library/Application Support/BraveSoftware/Brave-Browser"
        profiles.append(contentsOf: discoverChromiumProfiles(
            base: braveBase, browserName: "Brave", keychainService: "Brave Safe Storage", fm: fm
        ))

        let cursorPaths: [(String, String)] = [
            ("\(home)/Library/Application Support/Cursor/Partitions/cursor-browser/Cookies", "Browser"),
            ("\(home)/Library/Application Support/Cursor/Cookies", "Main"),
        ]
        for (path, name) in cursorPaths {
            profiles.append(BrowserProfile(
                browserName: "Cursor", profileName: name,
                cookiesDBPath: path, keychainService: "Cursor Safe Storage",
                isAvailable: fm.fileExists(atPath: path)
            ))
        }

        return profiles
    }

    private static func discoverChromiumProfiles(base: String, browserName: String, keychainService: String, fm: FileManager) -> [BrowserProfile] {
        var results: [BrowserProfile] = []
        guard fm.fileExists(atPath: base) else { return results }

        let candidateNames = ["Default"] + (1...20).map { "Profile \($0)" }
        for name in candidateNames {
            let cookiesPath = "\(base)/\(name)/Cookies"
            if fm.fileExists(atPath: cookiesPath) {
                results.append(BrowserProfile(
                    browserName: browserName, profileName: name,
                    cookiesDBPath: cookiesPath, keychainService: keychainService,
                    isAvailable: true
                ))
            }
        }

        if let entries = try? fm.contentsOfDirectory(atPath: base) {
            let knownNames = Set(candidateNames)
            for entry in entries where !knownNames.contains(entry) {
                let cookiesPath = "\(base)/\(entry)/Cookies"
                if fm.fileExists(atPath: cookiesPath) {
                    results.append(BrowserProfile(
                        browserName: browserName, profileName: entry,
                        cookiesDBPath: cookiesPath, keychainService: keychainService,
                        isAvailable: true
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Discover Available Browsers

    public static func availableBrowsers(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [BrowserProfile] {
        allBrowserProfiles(home: home).filter(\.isAvailable)
    }

    // MARK: - Provider Auth Capabilities

    public struct ProviderAuthCapability: Sendable {
        public let providerId: String
        public let displayName: String
        public let supportedMethods: [AuthMethod]
        public let cookieDomains: [String]?
        public let cookieNames: [String]?
        public let instructions: String
    }

    public static let providerCapabilities: [ProviderAuthCapability] = [
        ProviderAuthCapability(
            providerId: "cursor",
            displayName: "Cursor",
            supportedMethods: [.cookie, .webSession, .auto],
            cookieDomains: ["cursor.com", "www.cursor.com"],
            cookieNames: ["WorkosCursorSessionToken", "__Secure-next-auth.session-token", "wos-session"],
            instructions: "Log in to cursor.com in your browser, or paste the Cookie header from DevTools."
        ),
        ProviderAuthCapability(
            providerId: "antigravity",
            displayName: "Antigravity",
            supportedMethods: [.authFile, .oauth],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Connect your Antigravity IDE session or sign in with Google."
        ),
        ProviderAuthCapability(
            providerId: "kiro",
            displayName: "Kiro",
            supportedMethods: [.authFile, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Authenticates via AWS SSO OIDC Device Flow in-app (supports Google, GitHub, Builder ID, Organization). Also discovers Kiro IDE session cache automatically."
        ),
        ProviderAuthCapability(
            providerId: "codex",
            displayName: "Codex",
            supportedMethods: [.token, .authFile, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Reads ~/.codex/auth.json automatically. You can also paste an OpenAI API key."
        ),
        ProviderAuthCapability(
            providerId: "copilot",
            displayName: "Copilot",
            supportedMethods: [.token, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Authenticates via GitHub Device Flow OAuth in-app, or reads `gh auth token` / ~/.config/gh/hosts.yml as fallback. You can also paste a GitHub token."
        ),
        ProviderAuthCapability(
            providerId: "gemini",
            displayName: "Gemini CLI",
            supportedMethods: [.authFile, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Reads ~/.gemini/oauth_creds.json from the Gemini CLI."
        ),
        ProviderAuthCapability(
            providerId: "claude",
            displayName: "Claude",
            supportedMethods: [.auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Reads the AIUsage Claude Gateway usage archive automatically. No credentials needed."
        ),
        ProviderAuthCapability(
            providerId: "warp",
            displayName: "Warp",
            supportedMethods: [.apiKey, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Paste a personal Warp API key (wk-…) from Warp → Settings → Cloud platform → API keys. Accounts added before keys were supported keep reading the Warp desktop app cache."
        ),
        ProviderAuthCapability(
            providerId: "droid",
            displayName: "Droid",
            supportedMethods: [.cookie, .token, .authFile, .auto],
            cookieDomains: nil,
            cookieNames: nil,
            instructions: "Reads local auth files automatically. You can also paste a session cookie or bearer token."
        ),
    ]

    public static func capability(for providerId: String) -> ProviderAuthCapability? {
        providerCapabilities.first { $0.providerId == providerId }
    }
}
