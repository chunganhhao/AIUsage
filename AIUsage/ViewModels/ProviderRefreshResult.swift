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

    var shouldUpdateTimestamps: Bool {
        refreshedAt != nil && !refreshedProviders.isEmpty
    }

    static func success(
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil
    ) -> Self {
        Self(
            status: .success,
            refreshedProviders: refreshedProviders,
            refreshedAt: refreshedAt,
            userMessage: userMessage
        )
    }

    static func partial(
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil
    ) -> Self {
        Self(
            status: .partial,
            refreshedProviders: refreshedProviders,
            refreshedAt: refreshedAt,
            userMessage: userMessage
        )
    }

    static func failure(userMessage: String? = nil) -> Self {
        Self(
            status: .failure,
            refreshedProviders: [],
            refreshedAt: nil,
            userMessage: userMessage
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

    static func classified(
        totalResults: Int,
        refreshedProviders: [ProviderData],
        at refreshedAt: Date? = Date(),
        userMessage: String? = nil
    ) -> Self {
        guard !refreshedProviders.isEmpty else {
            return .failure(userMessage: userMessage)
        }

        if totalResults > 0, refreshedProviders.count < totalResults {
            return .partial(
                refreshedProviders: refreshedProviders,
                at: refreshedAt,
                userMessage: userMessage
            )
        }

        return .success(
            refreshedProviders: refreshedProviders,
            at: refreshedAt,
            userMessage: userMessage
        )
    }
}
