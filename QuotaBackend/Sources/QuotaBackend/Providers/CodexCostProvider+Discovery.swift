import Foundation

extension CodexCostProvider {
    // MARK: - File discovery

    func resolveSessionRoots() -> [String] {
        let codexHome = explicitCodexHome() ?? "\(homeDirectory)/.codex"
        return [
            "\(codexHome)/sessions",
            "\(codexHome)/archived_sessions"
        ]
    }

    func explicitCodexHome() -> String? {
        let value = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func collectJSONLFiles(roots: [String], scanWindow: CodexScanWindow?) -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
            let candidates: [URL]
            if let scanWindow {
                candidates = listDatePartitionedJSONLFiles(root: rootURL, scanWindow: scanWindow)
                    + listFlatJSONLFiles(root: rootURL, scanWindow: scanWindow)
            } else {
                candidates = listAllJSONLFiles(root: rootURL)
            }
            for candidate in candidates {
                let path = candidate.path
                guard seen.insert(path).inserted else { continue }
                files.append(path)
            }
        }
        return files.sorted()
    }

    func listDatePartitionedJSONLFiles(root: URL, scanWindow: CodexScanWindow) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var files: [URL] = []
        var date = dateFromDayKey(scanWindow.scanSinceKey) ?? Date()
        let until = dateFromDayKey(scanWindow.scanUntilKey) ?? date

        while date <= until {
            let comps = calendar().dateComponents([.year, .month, .day], from: date)
            let dayDir = root
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            if let items = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                files.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "jsonl" })
            }

            guard let next = calendar().date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }

        return files
    }

    func listFlatJSONLFiles(root: URL, scanWindow: CodexScanWindow) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return items.filter { item in
            guard item.pathExtension.lowercased() == "jsonl" else { return false }
            guard let dayKey = dayKeyFromFilename(item.lastPathComponent) else { return true }
            return scanWindow.containsScanDay(dayKey)
        }
    }

    func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = Self.filenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        return String(filename[matchRange])
    }

    func listAllJSONLFiles(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var files: [URL] = []
        for case let item as URL in enumerator {
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            if let values = try? item.resourceValues(forKeys: Set<URLResourceKey>([.isRegularFileKey])),
               values.isRegularFile == false {
                continue
            }
            files.append(item)
        }
        return files
    }

    // MARK: - Scanning

}
