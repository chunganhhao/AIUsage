import Foundation
import os.log

private let antigravityScanLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityScanning")

// MARK: - Antigravity Cost Provider: File Scanning & Proxy Archive
// 负责扫描 ~/.gemini/antigravity/brain/*/transcript.jsonl 提取非代理 token，
// 以及读取 ~/.config/aiusage/usage-archive/proxy-usage-antigravity-v1.json 提取代理轨用量。

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
                if let attrs = try? fm.attributesOfItem(atPath: foundPath),
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
        var out: [String: CodexAggregateBucket] = [:]

        for filePath in files {
            #if canImport(Darwin)
            autoreleasepool {
                let fileBuckets = processFile(filePath)
                for (dKey, bucket) in fileBuckets {
                    out[dKey, default: .empty].merge(bucket)
                }
            }
            #else
            let fileBuckets = processFile(filePath)
            for (dKey, bucket) in fileBuckets {
                out[dKey, default: .empty].merge(bucket)
            }
            #endif
        }

        return out
    }

    private func processFile(_ filePath: String) -> [String: CodexAggregateBucket] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return [:]
        }

        var detectedModel = "gemini-3.8-flash"
        if content.contains("`Model Selection` from None to Gemini 2.5 Flash") || content.contains("gemini-2.5-flash") {
            detectedModel = "gemini-2.5-flash"
        } else if content.contains("`Model Selection` from None to Gemini 2.5 Pro") || content.contains("gemini-2.5-pro") {
            detectedModel = "gemini-2.5-pro"
        } else if content.contains("Claude 3.7 Sonnet") || content.contains("claude-3-7-sonnet") {
            detectedModel = "claude-3.7-sonnet"
        }

        let modelKey = detectedModel + Self.nonProxySourceSuffix
        var fileOut: [String: CodexAggregateBucket] = [:]

        content.enumerateLines { line, _ in
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
            var m = bucket.models[modelKey] ?? CodexModelAggregate(model: modelKey)
            m.inputTokens += inTokens
            m.outputTokens += outTokens
            m.cacheReadTokens += cacheRead
            m.totalTokens += total
            m.estimatedCostUsd = 0

            bucket.models[modelKey] = m
            bucket.totalTokens += total
            bucket.usageRows += 1
            fileOut[dKey] = bucket
        }

        return fileOut
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
