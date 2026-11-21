import Foundation
import os.log

private let antigravityScanLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityScanning")

// MARK: - Antigravity Cost Provider: File Scanning & Proxy Archive
// 负责扫描 ~/.gemini/antigravity/brain/*/transcript.jsonl 提取非代理 token，
// 以及读取 ~/.config/aiusage/usage-archive/proxy-usage-antigravity-v1.json 提取代理轨用量。

struct AntigravityTranscriptFileStamp: Equatable, Sendable {
    let size: Int64
    let modifiedAt: TimeInterval
    let fileNumber: UInt64
    let timeZoneId: String
    let timeZoneOffset: Int
}

struct AntigravityTranscriptCacheEntry: Sendable {
    let stamp: AntigravityTranscriptFileStamp
    let buckets: [String: CodexAggregateBucket]
}

// shortcut: in-memory transcript scan cache (re-populates once per app launch for the 2-day window); add disk persistence only if cold-launch scan becomes noticeable.
actor AntigravityTranscriptScanCache {
    private var entries: [String: AntigravityTranscriptCacheEntry] = [:]

    func snapshot(for paths: [String]) -> [String: AntigravityTranscriptCacheEntry] {
        var result: [String: AntigravityTranscriptCacheEntry] = [:]
        for path in paths {
            if let entry = entries[path] {
                result[path] = entry
            }
        }
        return result
    }

    func update(
        _ updates: [String: AntigravityTranscriptCacheEntry],
        removing failedPaths: Set<String> = [],
        pruningBrainDirectory brainDirectory: String?,
        keeping activePaths: Set<String>
    ) {
        if let brainDirectory {
            let prefix = brainDirectory.hasSuffix("/") ? brainDirectory : brainDirectory + "/"
            entries = entries.filter { key, _ in
                !key.hasPrefix(prefix) || activePaths.contains(key)
            }
        }
        for path in failedPaths {
            entries.removeValue(forKey: path)
        }
        for (path, entry) in updates {
            entries[path] = entry
        }
    }
}

extension AntigravityCostProvider {

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
        let pricingResolvedRequests: Int?
    }

    private struct ProxyUsageDayDTO: Decodable {
        let models: [String: ProxyUsageModelAggDTO]
    }

    private struct ProxyUsageArchiveDTO: Decodable {
        let version: Int
        let updatedAt: String
        let days: [String: ProxyUsageDayDTO]
    }

    func resolveBrainDirectory() -> String? {
        let path = (homeDirectory as NSString).appendingPathComponent(".gemini/antigravity/brain")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return path
    }

    func collectTranscriptFiles(brainDirectory: String, scanWindowCutoff: Date?) -> [String] {
        let fm = FileManager.default
        guard let conversations = try? fm.contentsOfDirectory(atPath: brainDirectory) else {
            return []
        }

        var files: [String] = []
        for convId in conversations {
            let logDir = (brainDirectory as NSString)
                .appendingPathComponent(convId)
                .appending("/.system_generated/logs")
            
            let transcriptPath = (logDir as NSString).appendingPathComponent("transcript.jsonl")
            var targetPath: String?
            if fm.fileExists(atPath: transcriptPath) {
                targetPath = transcriptPath
            } else {
                let fullPath = (logDir as NSString).appendingPathComponent("transcript_full.jsonl")
                if fm.fileExists(atPath: fullPath) {
                    targetPath = fullPath
                }
            }

            guard let foundPath = targetPath else { continue }

            if let scanWindowCutoff {
                let resolvedPath = (foundPath as NSString).resolvingSymlinksInPath
                if let attrs = try? fm.attributesOfItem(atPath: resolvedPath),
                   let mtime = attrs[.modificationDate] as? Date {
                    if mtime < scanWindowCutoff {
                        continue
                    }
                }
            }

            files.append(foundPath)
        }

        return files
    }

    func scanFiles(_ files: [String]) -> [String: CodexAggregateBucket] {
        let byFile = scanFilesByPath(files)
        var out: [String: CodexAggregateBucket] = [:]
        for fileBuckets in byFile.values {
            for (dKey, bucket) in fileBuckets {
                out[dKey, default: .empty].merge(bucket)
            }
        }
        return out
    }

    static func canonicalTranscriptKey(_ filePath: String) -> String {
        if filePath.hasSuffix("/transcript_full.jsonl") {
            return String(filePath.dropLast("/transcript_full.jsonl".count)) + "/transcript.jsonl"
        }
        if filePath == "transcript_full.jsonl" {
            return "transcript.jsonl"
        }
        return filePath
    }

    func scanFilesByPath(_ files: [String]) -> [String: [String: CodexAggregateBucket]] {
        var out: [String: [String: CodexAggregateBucket]] = [:]

        for filePath in files {
            let key = Self.canonicalTranscriptKey(filePath)
            #if canImport(Darwin)
            autoreleasepool {
                if let fileBuckets = processFile(filePath), !fileBuckets.isEmpty {
                    out[key] = fileBuckets
                }
            }
            #else
            if let fileBuckets = processFile(filePath), !fileBuckets.isEmpty {
                out[key] = fileBuckets
            }
            #endif
        }

        return out
    }

    func scanFilesByPathCached(
        _ files: [String],
        brainDirectory: String? = nil,
        parseFile: (@Sendable (String) -> [String: CodexAggregateBucket]?)? = nil
    ) async -> [String: [String: CodexAggregateBucket]] {
        var stampsByPath: [String: AntigravityTranscriptFileStamp] = [:]
        stampsByPath.reserveCapacity(files.count)
        for filePath in files {
            if let stamp = transcriptFileStamp(for: filePath) {
                stampsByPath[filePath] = stamp
            }
        }

        let cached = await Self.transcriptScanCache.snapshot(for: files)
        var updates: [String: AntigravityTranscriptCacheEntry] = [:]
        var failedPaths: Set<String> = []
        var out: [String: [String: CodexAggregateBucket]] = [:]

        for filePath in files {
            let key = Self.canonicalTranscriptKey(filePath)
            let stamp = stampsByPath[filePath]
            if let stamp, let entry = cached[filePath], entry.stamp == stamp {
                if !entry.buckets.isEmpty {
                    out[key] = entry.buckets
                }
                continue
            }

            let fileBuckets: [String: CodexAggregateBucket]?
            #if canImport(Darwin)
            fileBuckets = autoreleasepool {
                if let parseFile {
                    return parseFile(filePath)
                }
                return processFile(filePath)
            }
            #else
            if let parseFile {
                fileBuckets = parseFile(filePath)
            } else {
                fileBuckets = processFile(filePath)
            }
            #endif

            guard let fileBuckets else {
                failedPaths.insert(filePath)
                continue
            }

            if let stamp {
                updates[filePath] = AntigravityTranscriptCacheEntry(stamp: stamp, buckets: fileBuckets)
            }
            if !fileBuckets.isEmpty {
                out[key] = fileBuckets
            }
        }

        if !updates.isEmpty || !failedPaths.isEmpty || brainDirectory != nil {
            await Self.transcriptScanCache.update(
                updates,
                removing: failedPaths,
                pruningBrainDirectory: brainDirectory,
                keeping: Set(files)
            )
        }

        return out
    }

    private func transcriptFileStamp(for filePath: String) -> AntigravityTranscriptFileStamp? {
        let resolvedPath = (filePath as NSString).resolvingSymlinksInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
              let sizeNumber = attrs[.size] as? NSNumber,
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return AntigravityTranscriptFileStamp(
            size: sizeNumber.int64Value,
            modifiedAt: modDate.timeIntervalSinceReferenceDate,
            fileNumber: fileNumber,
            timeZoneId: timeZone.identifier,
            timeZoneOffset: timeZone.secondsFromGMT()
        )
    }

    func processFile(_ filePath: String) -> [String: CodexAggregateBucket]? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return nil
        }

        var currentModelKey = "gemini-3.8-flash" + Self.nonProxySourceSuffix
        var fileOut: [String: CodexAggregateBucket] = [:]

        content.enumerateLines { line, _ in
            if line.contains("\"USER_INPUT\""),
               line.contains("<USER_SETTINGS_CHANGE>"),
               line.contains("Model Selection"),
               let updatedModel = Self.extractSelectedModel(from: line) {
                currentModelKey = updatedModel + Self.nonProxySourceSuffix
            }

            guard line.contains("\"PLANNER_RESPONSE\"") && line.contains("\"input_tokens\"") else {
                return
            }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "PLANNER_RESPONSE" else {
                return
            }

            guard let createdAtStr = json["created_at"] as? String,
                  let createdAt = SharedFormatters.parseISO8601(createdAtStr) else {
                return
            }

            let inTokens = json["input_tokens"] as? Int ?? 0
            let outTokens = json["output_tokens"] as? Int ?? 0
            let cacheRead = json["cache_read_tokens"] as? Int ?? 0
            let total = inTokens + outTokens + cacheRead

            guard total > 0 else { return }

            let dKey = self.dayKey(createdAt)
            var bucket = fileOut[dKey] ?? .empty
            var m = bucket.models[currentModelKey] ?? CodexModelAggregate(model: currentModelKey)
            m.inputTokens += inTokens
            m.outputTokens += outTokens
            m.cacheReadTokens += cacheRead
            m.totalTokens += total
            m.estimatedCostUsd = 0

            bucket.models[currentModelKey] = m
            bucket.totalTokens += total
            bucket.usageRows += 1
            fileOut[dKey] = bucket
        }

        return fileOut
    }

    static func extractSelectedModel(from line: String) -> String? {
        guard line.contains("<USER_SETTINGS_CHANGE>") else { return nil }
        let markers = ["changed setting `Model Selection`", "`Model Selection`", "Model Selection changed"]
        guard let markerRange = markers
            .compactMap({ line.range(of: $0, options: .backwards) })
            .max(by: { $0.upperBound < $1.upperBound }) else { return nil }
        let tail = line[markerRange.upperBound...]
        guard let toRange = tail.range(of: " to ") else { return nil }
        let afterTo = tail[toRange.upperBound...]
        let delimiters: [(pattern: String, options: String.CompareOptions)] = [
            (". No need", .caseInsensitive),
            ("\\n", []),
            ("\n", []),
            ("\r", []),
            ("</USER_SETTINGS_CHANGE>", []),
            ("<", [])
        ]
        var endIndex = afterTo.endIndex
        for (pattern, options) in delimiters {
            if let range = afterTo.range(of: pattern, options: options),
               range.lowerBound < endIndex {
                endIndex = range.lowerBound
            }
        }
        let trimmed = String(afterTo[..<endIndex]).trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
        return normalizeSelectedModelName(trimmed)
    }

    static func normalizeSelectedModelName(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, cleaned != "none" else { return nil }
        // Reject prose/code discussion fragments that mention USER_SETTINGS_CHANGE + Model Selection.
        if cleaned.contains("\"") || cleaned.contains("'") || cleaned.contains("`")
            || cleaned.contains("\\") || cleaned.contains(":") || cleaned.contains("{") || cleaned.contains("}")
            || cleaned.contains("[") || cleaned.contains("]") {
            return nil
        }
        if cleaned.split(whereSeparator: \.isWhitespace).count > 5 {
            return nil
        }
        let withoutParen: String
        if cleaned.hasSuffix(")"), let parenIndex = cleaned.lastIndex(of: "(") {
            let inside = cleaned[cleaned.index(after: parenIndex)..<cleaned.index(before: cleaned.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowedEffortChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
            guard !inside.isEmpty,
                  inside.unicodeScalars.allSatisfy({ allowedEffortChars.contains($0) }) else {
                return nil
            }
            withoutParen = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutParen = cleaned
        }
        guard !withoutParen.contains("("), !withoutParen.contains(")") else {
            return nil
        }
        if cleaned.contains("orchestrator") {
            if cleaned.contains("carbon") { return "gemini-4-carbon" }
            if cleaned.contains("hydrogen") { return "gemini-4-hydrogen" }
            if cleaned.contains("flash") { return "gemini-3.8-flash" }
            return "gemini-4-argon"
        }
        if cleaned.contains("gemini 4 hydrogen") || cleaned.contains("gemini-4-hydrogen") {
            return "gemini-4-hydrogen"
        }
        if cleaned.contains("gemini 4 carbon") || cleaned.contains("gemini-4-carbon") {
            return "gemini-4-carbon"
        }
        if cleaned.contains("gemini 4 argon") || cleaned.contains("gemini-4-argon") {
            return "gemini-4-argon"
        }
        if cleaned.contains("gemini 3.8 flash") || cleaned.contains("gemini-3.8-flash") {
            return "gemini-3.8-flash"
        }
        if cleaned.contains("gemini 3.5 flash") || cleaned.contains("gemini-3.5-flash") {
            return "gemini-3.5-flash-lite"
        }
        if cleaned.contains("gemini 3.1 pro") || cleaned.contains("gemini-3.1-pro") {
            return "gemini-3.1-pro"
        }
        if cleaned.contains("gemini 3 pro") || cleaned.contains("gemini-3-pro") {
            return "gemini-3-pro"
        }
        if cleaned.contains("gemini 2.5 pro") || cleaned.contains("gemini-2.5-pro") {
            return "gemini-2.5-pro"
        }
        if cleaned.contains("gemini 2.5 flash") || cleaned.contains("gemini-2.5-flash") {
            return "gemini-2.5-flash"
        }
        if cleaned.contains("claude opus 5.5") || cleaned.contains("claude-opus-5-5") || cleaned.contains("claude-opus-5.5") {
            return "claude-opus-5.5"
        }
        if cleaned.contains("claude sonnet 5.5") || cleaned.contains("claude-sonnet-5-5") || cleaned.contains("claude-sonnet-5.5") {
            return "claude-sonnet-5.5"
        }
        if cleaned.contains("claude opus 4.6") || cleaned.contains("claude-opus-4-6") || cleaned.contains("claude-opus-4.6") {
            return "claude-opus-4.6"
        }
        if cleaned.contains("claude sonnet 4.6") || cleaned.contains("claude-sonnet-4-6") || cleaned.contains("claude-sonnet-4.6") {
            return "claude-sonnet-4.6"
        }
        if cleaned.contains("claude 3.7 sonnet") || cleaned.contains("claude-3-7-sonnet") || cleaned.contains("claude-3.7-sonnet") {
            return "claude-3.7-sonnet"
        }
        if cleaned.contains("gpt-oss") {
            return "gpt-oss-120b"
        }
        let slug = withoutParen
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let knownPrefixes = ["gemini-", "claude-", "gpt-", "o1", "o3", "o4"]
        guard !slug.isEmpty, knownPrefixes.contains(where: { slug.hasPrefix($0) }) else {
            return nil
        }
        return slug
    }

    // MARK: - Proxy Archive

    func proxyUsageArchivePath() -> String {
        (homeDirectory as NSString)
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-antigravity-v1.json")
    }

    func loadProxyArchive() -> [String: CodexAggregateBucket] {
        let path = proxyUsageArchivePath()
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(ProxyUsageArchiveDTO.self, from: data) else {
            return [:]
        }

        var out: [String: CodexAggregateBucket] = [:]
        for (day, dayDTO) in dto.days {
            var bucket = CodexAggregateBucket.empty
            for (rawModel, modelDTO) in dayDTO.models {
                let modelKey = rawModel.hasSuffix(Self.proxySourceSuffix) ? rawModel : (rawModel + Self.proxySourceSuffix)
                var m = CodexModelAggregate(model: modelKey)
                m.inputTokens = modelDTO.inputTokens
                m.outputTokens = modelDTO.outputTokens
                m.cacheReadTokens = modelDTO.cacheReadTokens
                m.cacheCreateTokens = modelDTO.cacheCreateTokens
                m.totalTokens = modelDTO.inputTokens + modelDTO.outputTokens + modelDTO.cacheReadTokens + modelDTO.cacheCreateTokens
                m.estimatedCostUsd = modelDTO.costUSD

                bucket.models[modelKey] = m
                bucket.totalTokens += m.totalTokens
                bucket.estimatedCostUsd += m.estimatedCostUsd
                bucket.usageRows += modelDTO.requests
            }
            if !bucket.models.isEmpty {
                out[day] = bucket
            }
        }
        return out
    }
}
