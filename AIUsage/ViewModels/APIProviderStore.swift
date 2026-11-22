import Foundation
import SwiftUI
import Combine
import os.log

// MARK: - API Provider Store
// 「API 提供商」主配置的持久化。列表存为单文件 ~/.config/aiusage/api-providers.json
// （含 apiKey，0600 权限，与 opencode-nodes.json 同口径）。
// 仅负责主配置本身的 CRUD/排序；向各代理分发与同步由 APIProviderDistributor 负责。

private let apiProviderStoreLog = Logger(subsystem: "com.aiusage.desktop", category: "APIProviderStore")

@MainActor
final class APIProviderStore: ObservableObject {
    static let shared = APIProviderStore()

    @Published private(set) var providers: [APIProvider] = []

    private let fileManager = FileManager.default

    private struct StoreFile: Codable {
        var version: Int
        var providers: [APIProvider]
    }

    private static let storeVersion = 1

    static var storePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/api-providers.json")
    }

    init() {
        load()
    }

    // MARK: - Lookup

    func provider(id: String) -> APIProvider? {
        providers.first { $0.id == id }
    }

    // MARK: - CRUD

    /// 新增或更新主配置。新条目插到列表最前；返回落库后的对象（已生成 sortOrder）。
    @discardableResult
    func upsert(_ provider: APIProvider) -> APIProvider {
        var updated = provider
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = updated
        } else {
            if updated.sortOrder == Int.max {
                let minOrder = providers.map(\.sortOrder).min() ?? 0
                updated.sortOrder = minOrder - 1
            }
            providers.insert(updated, at: 0)
            sortProviders()
        }
        save()
        return updated
    }

    func saveCatalogUpdate(_ provider: APIProvider) -> Bool {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return false }
        var updated = providers
        updated[index] = provider
        guard save(updated) else { return false }
        providers = updated
        return true
    }

    func delete(id: String) {
        providers.removeAll { $0.id == id }
        save()
    }

    /// 拖拽重排：按展示顺序整表重写 sortOrder 并保存。
    func applyOrder(ids: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for index in providers.indices {
            if let order = rank[providers[index].id] {
                providers[index].sortOrder = order
            }
        }
        sortProviders()
        save()
    }

    func markUsed(id: String) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].lastUsedAt = Date()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = fileManager.contents(atPath: Self.storePath) else { return }
        do {
            let file = try JSONDecoder.profileDecoder.decode(StoreFile.self, from: data)
            providers = file.providers
            sortProviders()
        } catch {
            apiProviderStoreLog.error("Failed to load API providers: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        _ = save(providers)
    }

    private func save(_ providers: [APIProvider]) -> Bool {
        let file = StoreFile(version: Self.storeVersion, providers: providers)
        do {
            let dir = (Self.storePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.profileEncoder.encode(file)
            try data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storePath)
            return true
        } catch {
            apiProviderStoreLog.error("Failed to save API providers: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sortProviders() {
        providers.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
    }
}
