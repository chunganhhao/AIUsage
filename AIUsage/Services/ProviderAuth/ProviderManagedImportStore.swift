import Foundation
import QuotaBackend

enum ProviderManagedImportStore {
    private static var bundleID: String {
        if let bundleID = Bundle.main.bundleIdentifier?.nilIfBlank { return bundleID }
        #if DEBUG
        return "com.aiusage.desktop.debug"
        #else
        return ManagedAuthImportBoundary.productionBundleIdentifier
        #endif
    }

    private static func boundary(create: Bool) throws -> ManagedAuthImportBoundary {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        return ManagedAuthImportBoundary(
            bundleIdentifier: bundleID,
            applicationSupportDirectory: base
        )
    }

    static func isManagedImportPath(_ path: String?) -> Bool {
        guard let path = path?.nilIfBlank else { return false }
        return canonicalManagedPath(path) != nil
    }

    static func primaryManagedImportPath(for credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile,
           let credentialPath = canonicalManagedPath(credential.credential) {
            return credentialPath
        }

        return canonicalManagedPath(credential.metadata["sourcePath"])
    }

    private static func writableManagedImportPaths(for credential: AccountCredential) -> Set<String> {
        Set(
            [credential.credential, credential.metadata["sourcePath"]]
                .compactMap { writableManagedPath($0) }
        )
    }

    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {
        guard incomingCredential.authMethod == .authFile,
              let existingPath = primaryManagedImportPath(for: existingCredential),
              let incomingPath = primaryWritableManagedImportPath(for: incomingCredential),
              existingPath != incomingPath else {
            return
        }

        // Debug may discover production imports, but it must retain its own copied
        // artifact instead of overwriting or referencing the production file.
        guard writableManagedPath(existingPath) != nil else { return }

        do {
            try replaceManagedImport(at: existingPath, withContentsOf: incomingPath)
            removeManagedImport(at: incomingPath)
            let preservedLastUsedAt = incomingCredential.lastUsedAt

            if canonicalManagedPath(incomingCredential.credential) != nil {
                incomingCredential = AccountCredential(
                    id: incomingCredential.id,
                    providerId: incomingCredential.providerId,
                    accountLabel: incomingCredential.accountLabel,
                    authMethod: incomingCredential.authMethod,
                    credential: existingPath,
                    metadata: incomingCredential.metadata
                )
                incomingCredential.lastUsedAt = preservedLastUsedAt
            }

            if let sourcePath = incomingCredential.metadata["sourcePath"],
               canonicalManagedPath(sourcePath) == incomingPath {
                incomingCredential.metadata["sourcePath"] = existingPath
            }
        } catch {
            // If artifact reuse fails, keep the newer copied file and let
            // periodic orphan cleanup handle any stale leftovers.
        }
    }

    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {
        // 只扫描「当前进程自己的写入根」。Debug 绝不能清正式版 AuthImports。
        guard let rootDirectory = try? managedImportsRootDirectory(),
              FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return
        }

        let referencedPaths = Set(credentials.flatMap { writableManagedImportPaths(for: $0) })
        guard !referencedPaths.isEmpty else { return }

        // Vault 与磁盘不同步时 fail closed：缺文件说明路径漂移或另一套安装刚写过，
        // 此时删「未引用」文件极易误伤仍在使用的副本。
        let missingReferenced = referencedPaths.contains { !FileManager.default.fileExists(atPath: $0) }
        if missingReferenced { return }

        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            if !referencedPaths.contains(path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        pruneEmptyDirectories(under: rootDirectory)
    }

    /// Runtime deletion removes only writable managed files owned by the deleted credentials
    /// that are no longer referenced by remaining vault credentials, sparing in-flight imports.
    static func cleanupManagedImports(
        forDeletedCredentials deletedCredentials: [AccountCredential],
        referencedBy remainingCredentials: [AccountCredential]
    ) {
        guard let rootDirectory = try? managedImportsRootDirectory(),
              FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return
        }

        let referencedPaths = Set(remainingCredentials.flatMap { writableManagedImportPaths(for: $0) })
        let candidatePaths = Set(deletedCredentials.flatMap { writableManagedImportPaths(for: $0) })
            .subtracting(referencedPaths)
        guard !candidatePaths.isEmpty else { return }

        for path in candidatePaths {
            try? FileManager.default.removeItem(atPath: path)
        }

        pruneEmptyDirectories(under: rootDirectory)
    }

    /// 当前进程应写入的 AuthImports 根目录。
    static func managedImportsRootDirectory() throws -> URL {
        try boundary(create: true).activeRootURL
    }

    /// 读取补回时同时扫正式目录与当前隔离目录（Debug 仍能看到已恢复的历史文件）。
    static func readableImportRoots() -> [URL] {
        (try? boundary(create: false).readableRootURLs) ?? []
    }

    private static func replaceManagedImport(at targetPath: String, withContentsOf sourcePath: String) throws {
        guard let targetPath = writableManagedPath(targetPath),
              let sourcePath = writableManagedPath(sourcePath) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let targetURL = URL(fileURLWithPath: targetPath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: targetURL, options: .atomic)
    }

    private static func removeManagedImport(at path: String) {
        guard let managedPath = writableManagedPath(path) else { return }
        try? FileManager.default.removeItem(atPath: managedPath)
    }

    private static func canonicalManagedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfBlank else { return nil }
        return try? boundary(create: false).readableManagedPath(path)
    }

    private static func writableManagedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfBlank else { return nil }
        return try? boundary(create: false).writableManagedPath(path)
    }

    private static func primaryWritableManagedImportPath(for credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile,
           let credentialPath = writableManagedPath(credential.credential) {
            return credentialPath
        }
        return writableManagedPath(credential.metadata["sourcePath"])
    }

    private static func pruneEmptyDirectories(under rootDirectory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return
        }

        let directories = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  directory != rootDirectory,
                  let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ),
                  contents.isEmpty else {
                continue
            }

            try? FileManager.default.removeItem(at: directory)
        }
    }
}
