import Foundation
import os.log

private let antigravityScanLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityScanning")

// Local transcript scanning. Each conversation is checkpointed once, even when
// both transcript.jsonl and transcript_full.jsonl snapshots exist.

extension AntigravityCostProvider {

    func resolveBrainDirectory() -> String? {
        let path = (homeDirectory as NSString).appendingPathComponent(".gemini/antigravity/brain")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return path
    }

    func collectTranscriptFiles(brainDirectory: String, scanWindowCutoff: Date?) throws -> [String] {
        let fm = FileManager.default
        let conversations = try fm.contentsOfDirectory(
            at: URL(fileURLWithPath: brainDirectory), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

        var files: [String] = []
        for conversation in conversations {
            guard try conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let logDir = conversation.appendingPathComponent(".system_generated/logs").path

            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: logDir)
            } catch {
                // 尚未生成日志的会话可以跳过；权限等读取错误必须保留重试机会。
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain,
                   [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code) { continue }
                throw error
            }

            for name in ["transcript.jsonl", "transcript_full.jsonl"] where names.contains(name) {
                let path = (logDir as NSString).appendingPathComponent(name)
                if let cutoff = scanWindowCutoff,
                   let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date, mtime < cutoff { continue }
                files.append(path)
            }
        }

        return files
    }

    func scanFiles(_ files: [String]) throws -> [String: CodexAggregateBucket] {
        let byFile = try scanFilesByPath(files)
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

    func scanFilesByPath(_ files: [String]) throws -> [String: [String: CodexAggregateBucket]] {
        var out: [String: [String: CodexAggregateBucket]] = [:]

        for filePath in files {
            let key = Self.canonicalTranscriptKey(filePath)
            for (day, bucket) in try processFile(filePath) {
                if bucket.totalTokens > (out[key]?[day]?.totalTokens ?? -1) {
                    out[key, default: [:]][day] = bucket
                }
            }
        }

        return out
    }

    private func processFile(_ filePath: String) throws -> [String: CodexAggregateBucket] {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)

        var currentModelKey = "unknown-model" + Self.nonProxySourceSuffix
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
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "USER_INPUT",
              let content = json["content"] as? String,
              content.contains("<USER_SETTINGS_CHANGE>"),
              let markerRange = content.range(of: "Model Selection") else { return nil }
        let tail = content[markerRange.upperBound...]
        guard let toRange = tail.range(of: " to ") else { return nil }
        let afterTo = tail[toRange.upperBound...]
        let rawModel: Substring
        if let dotRange = afterTo.range(of: ". No need") {
            rawModel = afterTo[..<dotRange.lowerBound]
        } else if let escapedNewline = afterTo.range(of: "\\n") {
            rawModel = afterTo[..<escapedNewline.lowerBound]
        } else if let newline = afterTo.range(of: "\n") {
            rawModel = afterTo[..<newline.lowerBound]
        } else if let closeTag = afterTo.range(of: "</USER_SETTINGS_CHANGE>") {
            rawModel = afterTo[..<closeTag.lowerBound]
        } else {
            rawModel = afterTo
        }
        let trimmed = String(rawModel).trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n"))
        return normalizeSelectedModelName(trimmed)
    }

    static func normalizeSelectedModelName(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, cleaned != "none" else { return nil }
        if cleaned.contains("gemini 4 argon") || cleaned.contains("gemini-4-argon") {
            return "gemini-4-argon"
        }
        if cleaned.contains("gemini 3.8 flash") || cleaned.contains("gemini-3.8-flash") {
            return "gemini-3.8-flash"
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
        // Fallback for any newly introduced model in <USER_SETTINGS_CHANGE>:
        // strip trailing parenthetical mode tags like "(high)" or "(thinking)" and slugify,
        // so new models never inherit the previous model's token attribution.
        let withoutParen: String
        if let parenIndex = cleaned.firstIndex(of: "(") {
            withoutParen = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutParen = cleaned
        }
        let slug = withoutParen
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return slug.isEmpty ? "unknown-model" : slug
    }

}
