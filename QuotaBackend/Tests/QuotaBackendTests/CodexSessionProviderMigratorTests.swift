import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import QuotaBackend

final class CodexSessionProviderMigratorTests: XCTestCase {
    func testMigratesOnlyAIUsageProviderInPlaceAndRecordsCutoff() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-session-provider-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("active.jsonl")
        let archivedURL = home
            .appendingPathComponent(".codex/archived_sessions", isDirectory: true)
            .appendingPathComponent("archived.jsonl")
        let foreignURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("foreign.jsonl")
        let nativeURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("native.jsonl")

        try writeRollout(sessionID: "active-session", provider: "aiusage-proxy", to: sessionURL)
        try writeRollout(sessionID: "archived-session", provider: "aiusage-proxy", to: archivedURL)
        try writeRollout(sessionID: "foreign-session", provider: "cliproxyapi", to: foreignURL)
        try writeRollout(sessionID: "native-session", provider: "openai", to: nativeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)

        let original = try Data(contentsOf: sessionURL)
        let originalSuffix = try suffixAfterFirstLine(original)
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.size] as? NSNumber
        ).uint64Value

        let report = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)

        XCTAssertEqual(report.migratedFiles, 2)
        XCTAssertEqual(try provider(in: sessionURL), "openai")
        XCTAssertEqual(try provider(in: archivedURL), "openai")
        XCTAssertEqual(try provider(in: foreignURL), "cliproxyapi")
        XCTAssertEqual(try provider(in: nativeURL), "openai")
        XCTAssertEqual(try suffixAfterFirstLine(Data(contentsOf: sessionURL)), originalSuffix)
        let migratedSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.size] as? NSNumber
        ).uint64Value
        XCTAssertEqual(migratedSize, originalSize)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)

        let archiveURL = CodexSessionProviderMigrator.archiveURL(homeDirectory: home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let archivePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(archivePermissions & 0o777, 0o600)
        let cutoffs = CodexSessionProviderMigrator.legacyProxyCutoffs(homeDirectory: home.path)
        XCTAssertNotNil(cutoffs["active-session"])
        XCTAssertNotNil(cutoffs["archived-session"])
        XCTAssertNil(cutoffs["foreign-session"])

        let second = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)
        XCTAssertEqual(second.migratedFiles, 0)
    }

    func testMigratesInheritedProviderMetadataInForkedRollout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-fork-provider-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let rolloutURL = home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("fork.jsonl")
        try FileManager.default.createDirectory(
            at: rolloutURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = try metadataData(
            sessionID: "child-session",
            provider: "openai",
            parentSessionID: "parent-session"
        )
        data.append(0x0A)
        data.append(try metadataData(sessionID: "parent-session", provider: "aiusage-proxy"))
        data.append(0x0A)
        data.append(Data("{\"type\":\"response_item\",\"payload\":{\"text\":\"keep exactly\"}}\n".utf8))
        try data.write(to: rolloutURL, options: .atomic)
        let originalSize = data.count

        let priorCutoff = "2026-09-01T00:00:00.000Z"
        let archiveURL = CodexSessionProviderMigrator.archiveURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingArchive: [String: Any] = [
            "version": 1,
            "updatedAt": priorCutoff,
            "files": [
                rolloutURL.path: [
                    "sessionID": "parent-session",
                    "originalProvider": "aiusage-proxy",
                    "migratedAt": priorCutoff,
                    "valueOffset": 0,
                    "valueLength": 15,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existingArchive, options: [.sortedKeys])
            .write(to: archiveURL, options: .atomic)

        let report = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)

        XCTAssertEqual(report.migratedFiles, 1)
        XCTAssertEqual(try sessionProviders(in: rolloutURL), ["openai", "openai"])
        XCTAssertEqual(try Data(contentsOf: rolloutURL).count, originalSize)
        let cutoffFormatter = ISO8601DateFormatter()
        cutoffFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedCutoff = try XCTUnwrap(cutoffFormatter.date(from: priorCutoff))
        XCTAssertEqual(
            CodexSessionProviderMigrator.legacyProxyCutoffs(homeDirectory: home.path)["parent-session"],
            expectedCutoff
        )
    }

    func testMigratesCodexThreadIndexDatabases() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-thread-index-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let rootState = home.appendingPathComponent(".codex/state_5.sqlite")
        let nestedState = home.appendingPathComponent(".codex/sqlite/state_4.sqlite")
        let catalog = home.appendingPathComponent(".codex/sqlite/codex-dev.db")
        try createIndexDatabase(at: rootState, table: "threads")
        try createIndexDatabase(at: nestedState, table: "threads")
        try createIndexDatabase(at: catalog, table: "local_thread_catalog")

        let report = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)

        XCTAssertEqual(report.migratedFiles, 0)
        XCTAssertEqual(report.migratedDatabaseRows, 3)
        XCTAssertEqual(try modelProviders(in: rootState, table: "threads"), ["openai", "openai", "cliproxyapi"])
        XCTAssertEqual(try modelProviders(in: nestedState, table: "threads"), ["openai", "openai", "cliproxyapi"])
        XCTAssertEqual(
            try modelProviders(in: catalog, table: "local_thread_catalog"),
            ["openai", "openai", "cliproxyapi"]
        )

        let second = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)
        XCTAssertEqual(second.migratedDatabaseRows, 0)
    }

    func testMigrateSkipsLegacyCPAArchiveBackedRootsFilesAndDatabasesWhileMigratingOrdinaryOnes() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-migrator-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let fm = FileManager.default
        let archiveDir = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
        let archiveSessions = archiveDir.appendingPathComponent("archive-sessions", isDirectory: true)
        let archiveSqlite = archiveDir.appendingPathComponent("archive-sqlite", isDirectory: true)
        try fm.createDirectory(at: archiveSessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveSqlite, withIntermediateDirectories: true)

        try Data(#"{"type":"codex"}"#.utf8).write(to: archiveDir.appendingPathComponent("aiusage-codex-1.json"))
        let preExistingLock = archiveDir.appendingPathComponent("preexisting.lock")
        try Data("keep-lock".utf8).write(to: preExistingLock)
        try Data("keep-wal".utf8).write(to: archiveDir.appendingPathComponent("wal-target.bin"))

        let archivedRollout = archiveSessions.appendingPathComponent("archived-rollout.jsonl")
        let archiveStateDB = archiveSqlite.appendingPathComponent("state_9.sqlite")
        let archiveCatalogDB = archiveSqlite.appendingPathComponent("codex-dev.db")
        try writeRollout(sessionID: "arch-sess", provider: "aiusage-proxy", to: archivedRollout)
        try createIndexDatabase(at: archiveStateDB, table: "threads")
        try createIndexDatabase(at: archiveCatalogDB, table: "local_thread_catalog")
        let manifestBefore = try recursiveManifest(at: archiveDir)

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let ordinaryRollout = codexDir.appendingPathComponent("sessions/2026/09/05/ordinary.jsonl")
        try writeRollout(sessionID: "ord-sess", provider: "aiusage-proxy", to: ordinaryRollout)
        try fm.createSymbolicLink(
            at: codexDir.appendingPathComponent("sessions/aliased-subdir"),
            withDestinationURL: archiveSessions
        )
        try fm.createSymbolicLink(
            at: codexDir.appendingPathComponent("archived_sessions"),
            withDestinationURL: archiveSessions
        )

        let ordinaryStateDB = codexDir.appendingPathComponent("state_1.sqlite")
        let walLinkedStateDB = codexDir.appendingPathComponent("state_2.sqlite")
        try createIndexDatabase(at: ordinaryStateDB, table: "threads")
        try createIndexDatabase(at: walLinkedStateDB, table: "threads")
        let walDBBefore = try Data(contentsOf: walLinkedStateDB)
        try fm.createSymbolicLink(
            at: codexDir.appendingPathComponent("state_2.sqlite-wal"),
            withDestinationURL: archiveDir.appendingPathComponent("wal-target.bin")
        )
        try fm.createSymbolicLink(
            at: codexDir.appendingPathComponent("sqlite"),
            withDestinationURL: archiveSqlite
        )

        let report = try CodexSessionProviderMigrator.migrate(homeDirectory: home.path)

        let walDBVerifyCopy = home.appendingPathComponent("verify-wal-state.sqlite")
        try fm.copyItem(at: walLinkedStateDB, to: walDBVerifyCopy)

        XCTAssertEqual(report.migratedFiles, 1)
        XCTAssertEqual(report.migratedDatabaseRows, 1)
        XCTAssertEqual(try provider(in: ordinaryRollout), "openai")
        XCTAssertEqual(try modelProviders(in: ordinaryStateDB, table: "threads"), ["openai", "openai", "cliproxyapi"])
        XCTAssertEqual(try Data(contentsOf: walLinkedStateDB), walDBBefore)
        XCTAssertEqual(try modelProviders(in: walDBVerifyCopy, table: "threads"), ["aiusage-proxy", "openai", "cliproxyapi"])
        XCTAssertEqual(try provider(in: archivedRollout), "aiusage-proxy")
        XCTAssertEqual(try modelProviders(in: archiveStateDB, table: "threads"), ["aiusage-proxy", "openai", "cliproxyapi"])
        XCTAssertEqual(try modelProviders(in: archiveCatalogDB, table: "local_thread_catalog"), ["aiusage-proxy", "openai", "cliproxyapi"])
        XCTAssertEqual(try recursiveManifest(at: archiveDir), manifestBefore)
        XCTAssertTrue(fm.fileExists(atPath: preExistingLock.path))

        // Direct ~/.codex symlink pointing into CLIProxyAPI/auth must scan/migrate nothing
        let home2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-migrator-whole-codex-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home2) }
        let archiveDir2 = home2.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
        try writeRollout(
            sessionID: "arch2-sess",
            provider: "aiusage-proxy",
            to: archiveDir2.appendingPathComponent("sessions/arch2.jsonl")
        )
        try createIndexDatabase(at: archiveDir2.appendingPathComponent("state_8.sqlite"), table: "threads")
        try fm.createDirectory(at: home2, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home2.appendingPathComponent(".codex"), withDestinationURL: archiveDir2)
        let manifest2Before = try recursiveManifest(at: archiveDir2)

        let report2 = try CodexSessionProviderMigrator.migrate(homeDirectory: home2.path)

        XCTAssertEqual(report2.scannedFiles, 0)
        XCTAssertEqual(report2.migratedFiles, 0)
        XCTAssertEqual(report2.migratedDatabaseRows, 0)
        XCTAssertFalse(fm.fileExists(atPath: CodexSessionProviderMigrator.archiveURL(homeDirectory: home2.path).path))
        XCTAssertEqual(try recursiveManifest(at: archiveDir2), manifest2Before)

        // Mid-scan archive-root repointing: write checks resolve fresh archiveRoots after discovery
        let home3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-migrator-repoint-\(UUID().uuidString)", isDirectory: true)
        defer {
            CodexSessionProviderMigrator.afterDiscoveryHookForTesting = nil
            try? fm.removeItem(at: home3)
        }
        let archiveV1 = home3.appendingPathComponent("archive-v1", isDirectory: true)
        let archiveV2 = home3.appendingPathComponent("archive-v2", isDirectory: true)
        try fm.createDirectory(at: archiveV1, withIntermediateDirectories: true)
        try writeRollout(
            sessionID: "race-sess",
            provider: "aiusage-proxy",
            to: archiveV2.appendingPathComponent("sessions/2026/09/05/race.jsonl")
        )
        try createIndexDatabase(at: archiveV2.appendingPathComponent("state_8.sqlite"), table: "threads")
        let cliProxyAuth = home3.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        try fm.createDirectory(at: cliProxyAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cliProxyAuth, withDestinationURL: archiveV1)
        try fm.createSymbolicLink(at: home3.appendingPathComponent(".codex"), withDestinationURL: archiveV2)
        let manifest3Before = try recursiveManifest(at: archiveV2)

        CodexSessionProviderMigrator.afterDiscoveryHookForTesting = {
            let staging = cliProxyAuth.deletingLastPathComponent().appendingPathComponent(".swap-\(UUID().uuidString)")
            try? fm.createSymbolicLink(at: staging, withDestinationURL: archiveV2)
            _ = rename(staging.path, cliProxyAuth.path)
        }
        let report3 = try CodexSessionProviderMigrator.migrate(homeDirectory: home3.path)
        CodexSessionProviderMigrator.afterDiscoveryHookForTesting = nil

        XCTAssertEqual(report3.scannedFiles, 1)
        XCTAssertEqual(report3.migratedFiles, 0)
        XCTAssertEqual(report3.migratedDatabaseRows, 0)
        XCTAssertFalse(fm.fileExists(atPath: CodexSessionProviderMigrator.archiveURL(homeDirectory: home3.path).path))
        XCTAssertEqual(try recursiveManifest(at: archiveV2), manifest3Before)
    }

    private func recursiveManifest(at root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [String] = []
        for case let item as URL in enumerator {
            let vals = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let rel = item.path.hasPrefix(rootPrefix) ? String(item.path.dropFirst(rootPrefix.count)) : item.path
            if vals.isSymbolicLink == true {
                let dest = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                entries.append("L:\(rel)->\(dest)")
            } else if vals.isRegularFile == true {
                let data = try Data(contentsOf: item)
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                entries.append("F:\(rel):\(data.count):\(sha)")
            }
        }
        return entries.sorted()
    }

    private func writeRollout(sessionID: String, provider: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try metadataData(sessionID: sessionID, provider: provider)
        data.append(0x0A)
        data.append(Data("{\"type\":\"response_item\",\"payload\":{\"text\":\"keep exactly\"}}\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    private func metadataData(
        sessionID: String,
        provider: String,
        parentSessionID: String? = nil
    ) throws -> Data {
        var payload: [String: Any] = [
            "id": sessionID,
            "model_provider": provider,
        ]
        if let parentSessionID {
            payload["session_id"] = parentSessionID
        }
        let metadata: [String: Any] = [
            "timestamp": "2026-09-05T00:00:00.000Z",
            "type": "session_meta",
            "payload": payload,
        ]
        return try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    }

    private func provider(in url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        return try XCTUnwrap(payload["model_provider"] as? String)
    }

    private func suffixAfterFirstLine(_ data: Data) throws -> Data {
        let newline = try XCTUnwrap(data.firstIndex(of: 0x0A))
        return data[data.index(after: newline)...]
    }

    private func sessionProviders(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any] else { return nil }
                return (payload["model_provider"] as? String) ?? (payload["modelProvider"] as? String)
            }
    }

    private func createIndexDatabase(at url: URL, table: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE \(table) (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL);
        INSERT INTO \(table) VALUES ('legacy', 'aiusage-proxy');
        INSERT INTO \(table) VALUES ('native', 'openai');
        INSERT INTO \(table) VALUES ('foreign', 'cliproxyapi');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func modelProviders(in url: URL, table: String) throws -> [String] {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "SELECT model_provider FROM \(table) ORDER BY CASE id WHEN 'legacy' THEN 0 WHEN 'native' THEN 1 ELSE 2 END",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        var providers: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            if let value = sqlite3_column_text(query, 0) {
                providers.append(String(cString: value))
            }
        }
        return providers
    }
}
