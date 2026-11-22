import Foundation
import Network
import os.log
import QuotaBackend

// MARK: - OpenCode Proxy HTTP Handlers
// 服务 OpenAI chat/completions 入站端点 `/v1/chat/completions`（流式与非流式），
// 忠实透传到 OpenAI 兼容上游。结构与 Codex 的 `/v1/responses` 处理保持一致。
// 请求日志（PROXY_LOG）仅用于观测展示，用量计费以 opencode.db 为准。

extension QuotaHTTPServer {
    // MARK: - Non-Streaming

    func handleOpenCodeChatEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = openCodeProxyService else {
            return codexErrorResponse(
                message: "OpenCode proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: headers
            )
        }

        let requestModel = Self.peekChatModel(from: request.body)
        // 全局统一代理：CLI 端固定发虚拟模型名，按激活节点真实模型改写请求体 model（每节点代理模式 forcedModel=nil → 不改写）。
        let forcedModel = openCodeConfig?.forcedModel
        let outboundBody = Self.rewriteChatModel(in: request.body, to: forcedModel) ?? request.body
        let upstreamModel = forcedModel ?? requestModel
        let startTime = Date()
        do {
            let result = try await proxy.passthroughChatCompletions(
                rawBody: outboundBody,
                inboundHeaders: request.headers
            )
            let elapsed = Date().timeIntervalSince(startTime) * 1000

            if (200..<300).contains(result.statusCode) {
                emitRequestLog(
                    claudeModel: requestModel,
                    upstreamModel: upstreamModel,
                    success: true,
                    responseTimeMs: elapsed,
                    inputTokens: result.usage?.inputTokens ?? 0,
                    outputTokens: result.usage?.outputTokens ?? 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: result.usage?.cachedTokens ?? 0,
                    nodeId: activeNodeId
                )
            } else {
                let bodyText = String(data: result.data, encoding: .utf8) ?? ""
                emitRequestLog(
                    claudeModel: requestModel,
                    upstreamModel: upstreamModel,
                    success: false,
                    responseTimeMs: elapsed,
                    errorMessage: String(bodyText.prefix(500)),
                    errorType: "upstream_error",
                    statusCode: result.statusCode,
                    nodeId: activeNodeId
                )
            }

            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            responseHeaders["Content-Length"] = "\(result.data.count)"
            if let requestID = result.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return HTTPResponse(status: result.statusCode, headers: responseHeaders, bodyData: result.data)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let errorResult = await proxy.buildErrorResult(error: error)
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId
            )
            httpLog.error("  ✗ OpenCode passthrough error: \(error.localizedDescription)")
            var responseHeaders = headers
            if let requestID = errorResult.response.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return jsonResponse(
                encodable: errorResult.response,
                status: errorResult.statusCode,
                headers: responseHeaders
            )
        }
    }

    // MARK: - Models (passthrough)

    /// `GET /v1/models`：原样转发上游模型列表，避免客户端探测时 404。
    func handleOpenCodeModelsEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = openCodeProxyService else {
            return codexErrorResponse(
                message: "OpenCode proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: headers
            )
        }

        do {
            let result = try await proxy.passthroughModels(inboundHeaders: request.headers)
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            responseHeaders["Content-Length"] = "\(result.data.count)"
            if let requestID = result.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return HTTPResponse(status: result.statusCode, headers: responseHeaders, bodyData: result.data)
        } catch {
            httpLog.error("  ✗ OpenCode models passthrough error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            return jsonResponse(
                encodable: errorResult.response,
                status: errorResult.statusCode,
                headers: headers
            )
        }
    }

    // MARK: - Streaming

    func handleOpenCodeStreamingProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let proxy = openCodeProxyService else {
            let response = codexErrorResponse(
                message: "OpenCode proxy is not enabled",
                type: "api_error",
                status: 503,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        guard await proxy.authenticate(headers: request.headers) else {
            let response = codexErrorResponse(
                message: "Invalid API key",
                type: "authentication_error",
                status: 401,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        let requestModel = Self.peekChatModel(from: request.body)
        let forcedModel = openCodeConfig?.forcedModel
        let outboundBody = Self.rewriteChatModel(in: request.body, to: forcedModel) ?? request.body
        let upstreamModel = forcedModel ?? requestModel
        let streamStartTime = Date()
        var firstTokenAt: Date?
        let streamer = StreamingResponse(connection: connection)
        await streamer.sendHeaders(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
        ])

        let usageRef = OpenCodePassthroughUsageRef()
        do {
            try await proxy.passthroughStreamingChatCompletions(
                rawBody: outboundBody,
                inboundHeaders: request.headers
            ) { data in
                // 首个上游帧到达即为首字时间（TTFT）。
                if firstTokenAt == nil { firstTokenAt = Date() }
                // usage 仅出现在带 stream_options.include_usage 的末帧；
                // 廉价子串判定避免对每个 delta 帧做 JSON 解析（"usage": null 会被解析步骤过滤）。
                if data.contains("\"usage\""), let usage = OpenCodeProxyService.parseUsage(fromStreamFrame: data) {
                    await usageRef.set(usage)
                }
                await streamer.sendSSEEvent(event: nil, data: data)
            }

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            let usage = await usageRef.get()
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                inputTokens: usage?.inputTokens ?? 0,
                outputTokens: usage?.outputTokens ?? 0,
                cacheCreationTokens: 0,
                cacheReadTokens: usage?.cachedTokens ?? 0,
                nodeId: activeNodeId
            )
        } catch {
            httpLog.error("  ✗ OpenCode streaming passthrough error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            // chat.completions 流没有专用错误事件，按 OpenAI 习惯回一个 error 对象帧再结束。
            let errMsg = """
            {"error":{"type":\(escapeJSON(errorResult.response.error.type)),"message":\(escapeJSON(errorResult.response.error.message))}}
            """
            await streamer.sendSSEEvent(event: nil, data: errMsg)
            await streamer.sendSSEEvent(event: nil, data: "[DONE]")

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(streamStartTime) * 1000 }
            emitRequestLog(
                claudeModel: requestModel,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                firstTokenMs: firstTokenMs,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode,
                nodeId: activeNodeId
            )
        }

        await streamer.finish()
    }

    /// 仅探测顶层 `model` 字段的轻量解码目标（避免对大 body 做 JSONSerialization 全量建图）。
    private struct ChatModelProbe: Decodable {
        let model: String?
    }

    /// 从原始请求体中安全读取 model（仅用于日志展示）。
    private static func peekChatModel(from body: Data) -> String {
        guard let model = (try? requestDecoder.decode(ChatModelProbe.self, from: body))?.model,
              !model.isEmpty else {
            return "unknown"
        }
        return model
    }

    /// 把请求体顶层 `model` 改写为 `target`（全局统一代理：CLI 固定发虚拟模型名，按激活节点真实模型改写）。
    /// `target` 为空/解析失败时返回 nil（调用方回退用原始 body，不改写）。
    static func rewriteChatModel(in body: Data, to target: String?) -> Data? {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        json["model"] = target
        return try? JSONSerialization.data(withJSONObject: json)
    }
}

/// 流式透传期间累计 usage 的线程安全容器。
private actor OpenCodePassthroughUsageRef {
    private var usage: OpenCodeProxyService.PassthroughUsage?

    func set(_ value: OpenCodeProxyService.PassthroughUsage) {
        usage = value
    }

    func get() -> OpenCodeProxyService.PassthroughUsage? {
        usage
    }
}
