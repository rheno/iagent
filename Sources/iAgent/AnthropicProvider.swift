import Foundation

/// Native Anthropic Messages API (raw HTTP + SSE; there is no official Swift SDK).
final class AnthropicProvider: LLMProvider {
    let baseURL: URL
    let apiKey: String
    var model: String
    let maxTokens: Int
    let effort: String?
    let thinking: Bool
    let extraHeaders: [String: String]

    var label: String { "anthropic @ \(baseURL.host ?? baseURL.absoluteString)" }

    /// First-party API only: features a proxy/gateway may reject.
    private var isFirstParty: Bool { baseURL.host == "api.anthropic.com" }

    /// Models that accept server-side refusal fallbacks in the `"default"` form.
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    init(baseURL: URL, apiKey: String, model: String, maxTokens: Int, effort: String?, thinking: Bool,
         extraHeaders: [String: String]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.thinking = thinking
        self.extraHeaders = extraHeaders
    }

    func complete(system: String,
                  messages: [ChatMessage],
                  tools: [Tool],
                  callbacks: StreamCallbacks) async throws -> AssistantTurn {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": encode(messages),
            // Auto-places a cache breakpoint on the last cacheable block: the growing
            // conversation prefix is reused across agent-loop iterations.
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                var t: [String: Any] = ["name": tool.name, "description": tool.description, "input_schema": tool.schema]
                if isFirstParty { t["eager_input_streaming"] = true }
                return t
            }
        }
        // Haiku 4.5 and older models don't take adaptive thinking / effort.
        let supportsAdaptive = model.range(of: #"claude-(opus|sonnet|fable|mythos)-[5-9]|claude-(opus|sonnet)-4-[6-9]"#,
                                           options: .regularExpression) != nil
        if thinking && supportsAdaptive {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            if let effort { body["output_config"] = ["effort": effort] }
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if isFirstParty && Self.fallbackModels.contains(model) {
            // On a safety-classifier decline, the API re-runs the turn on a fallback model.
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSON.data(body)
        return try await parse(HTTP.streamLines(req), callbacks: callbacks)
    }

    /// Builds the turn from the SSE lines. A stream that ends before the stop reason (`message_delta`, sent after
    /// every content block is complete) or `message_stop` was cut off (dropped connection, proxy timeout): its text
    /// is incomplete and its tool calls may be too, so it is an error, not a finished turn. Accepting the stop reason
    /// alone keeps gateways that leave out `message_stop` working.
    func parse<Lines: AsyncSequence>(_ lines: Lines, callbacks: StreamCallbacks) async throws -> AssistantTurn
    where Lines.Element == String {
        var turn = AssistantTurn()
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var finished = false

        for try await line in lines {
            guard let payload = HTTP.sseData(line), let event = JSON.object(payload) else { continue }
            switch event["type"] as? String {
            case "message_start":
                if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    turn.usage.input = usage["input_tokens"] as? Int ?? 0
                    turn.usage.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                }
            case "content_block_start":
                guard let idx = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { break }
                blocks[idx] = block
            case "content_block_delta":
                guard let idx = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                      var block = blocks[idx] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + t
                    callbacks.onText(t)
                case "thinking_delta":
                    let t = delta["thinking"] as? String ?? ""
                    block["thinking"] = (block["thinking"] as? String ?? "") + t
                    callbacks.onThinking(t)
                case "signature_delta":
                    block["signature"] = delta["signature"]
                case "input_json_delta":
                    partialJSON[idx, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                blocks[idx] = block
            case "content_block_stop":
                guard let idx = event["index"] as? Int, var block = blocks[idx] else { break }
                if let raw = partialJSON[idx] {
                    // Keep the echoed block valid JSON even if the streamed input is truncated;
                    // the raw string still goes to the tool call so it can report INVALID_JSON.
                    block["input"] = JSON.object(raw) ?? [:]
                    blocks[idx] = block
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                    turn.stopReason = stop
                }
                if let usage = event["usage"] as? [String: Any] {
                    turn.usage.output = usage["output_tokens"] as? Int ?? turn.usage.output
                }
            case "message_stop":
                finished = true
            case "error":
                throw AgentError("Anthropic stream error: \(JSON.string(event["error"] ?? event))")
            default:
                break
            }
        }

        guard finished || turn.stopReason != nil else {
            throw AgentError("The connection to the model dropped before its reply finished, so the partial reply was discarded. Send your message again.")
        }
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        turn.rawBlocks = ordered
        for (idx, block) in blocks.sorted(by: { $0.key < $1.key }) {
            switch block["type"] as? String {
            case "text":
                turn.text += block["text"] as? String ?? ""
            case "tool_use":
                let args = partialJSON[idx] ?? JSON.string(block["input"] ?? [String: Any]())
                turn.toolCalls.append(ToolCall(id: block["id"] as? String ?? "",
                                               name: block["name"] as? String ?? "",
                                               arguments: args))
            default:
                break
            }
        }
        return turn
    }

    private func encode(_ messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pendingResults: [[String: Any]] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            // All results for one assistant turn go back in a single user message.
            out.append(["role": "user", "content": pendingResults])
            pendingResults = []
        }

        for message in messages {
            switch message {
            case .toolResult(let callId, let content, let isError):
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": callId,
                                        "content": content.isEmpty ? "(no output)" : content]
                if isError { r["is_error"] = true }
                pendingResults.append(r)
            case .user(let text):
                flushResults()
                out.append(["role": "user", "content": text])
            case .assistant(let turn):
                flushResults()
                if let raw = turn.rawBlocks, !raw.isEmpty {
                    out.append(["role": "assistant", "content": raw])
                } else {
                    var content: [[String: Any]] = []
                    if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
                    for call in turn.toolCalls {
                        content.append(["type": "tool_use", "id": call.id, "name": call.name,
                                        "input": JSON.object(call.arguments) ?? [:]])
                    }
                    if !content.isEmpty { out.append(["role": "assistant", "content": content]) }
                }
            }
        }
        flushResults()
        return out
    }
}
