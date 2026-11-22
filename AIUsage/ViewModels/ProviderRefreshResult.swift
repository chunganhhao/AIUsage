import Foundation

enum ProviderRefreshStatus {
    case success
    case partial
    case failure
}

struct ProviderRefreshResult {
    let status: ProviderRefreshStatus
    let refreshedProviders: [ProviderData]
    let refreshedAt: Date?
    let userMessage: String?
    let shouldUpdateErrorBanner: Bool

    init(
        status: ProviderRefreshStatus,
        refreshedProviders: [ProviderData],
        refreshedAt: Date?,
        userMessage: String?,
        shouldUpdateErrorBanner: Bool = true
    ) {
        self.status = status
        self.refreshedProviders = refreshedProviders
        self.refreshedAt = refreshedAt
        self.userMessage = userMessage
        self.shouldUpdateErrorBanner = shouldUpdateErrorBanner
    }

    var shouldUpdateTimestamps: Bool {
        refreshedAt != nil && !refreshedProviders.isEmpty
    }

    static func success(
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil,
        shouldUpdateErrorBanner: Bool = true
    ) -> Self {
        Self(
            status: .success,
            refreshedProviders: refreshedProviders,
            refreshedAt: refreshedAt,
            userMessage: userMessage,
            shouldUpdateErrorBanner: shouldUpdateErrorBanner
        )
    }

    static func partial(
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil,
        shouldUpdateErrorBanner: Bool = true
    ) -> Self {
        Self(
            status: .partial,
            refreshedProviders: refreshedProviders,
            refreshedAt: refreshedAt,
            userMessage: userMessage,
            shouldUpdateErrorBanner: shouldUpdateErrorBanner
        )
    }

    static func failure(
        userMessage: String? = nil,
        shouldUpdateErrorBanner: Bool = true
    ) -> Self {
        Self(
            status: .failure,
            refreshedProviders: [],
            refreshedAt: nil,
            userMessage: userMessage,
            shouldUpdateErrorBanner: shouldUpdateErrorBanner
        )
    }

    static func emptySuccess() -> Self {
        Self(
            status: .success,
            refreshedProviders: [],
            refreshedAt: nil,
            userMessage: nil
        )
    }

    /// Discarded out-of-scope or hidden completion: never overwrite another provider's active banner.
    static func ignored(status: ProviderRefreshStatus = .failure) -> Self {
        Self(
            status: status,
            refreshedProviders: [],
            refreshedAt: nil,
            userMessage: nil,
            shouldUpdateErrorBanner: false
        )
    }

    static func classified(
        totalResults: Int,
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil,
        shouldUpdateErrorBanner: Bool = true
    ) -> Self {
        guard !refreshedProviders.isEmpty else {
            return .failure(
                userMessage: userMessage,
                shouldUpdateErrorBanner: shouldUpdateErrorBanner
            )
        }

        if totalResults > 0, refreshedProviders.count < totalResults {
            return .partial(
                refreshedProviders: refreshedProviders,
                at: refreshedAt,
                userMessage: userMessage,
                shouldUpdateErrorBanner: shouldUpdateErrorBanner
            )
        }

        return .success(
            refreshedProviders: refreshedProviders,
            at: refreshedAt,
            userMessage: userMessage,
            shouldUpdateErrorBanner: shouldUpdateErrorBanner
        )
    }
}
