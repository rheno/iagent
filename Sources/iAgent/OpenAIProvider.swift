import Foundation

/// Any server speaking the OpenAI Chat Completions API:
/// OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq, DeepSeek, Together, LiteLLM, ...
final class OpenAICompatibleProvider: LLMProvider {
    let baseURL: URL
    let apiKey: String?
    var model: String
    let maxTokens: Int?
    let extraHeaders: [String: String]

    var label: String { "openai-compatible @ \(baseURL.host ?? baseURL.absoluteString)" }

    init(baseURL: URL, apiKey: String?, model: String, maxTokens: Int?, extraHeaders: [String: String]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.extraHeaders = extraHeaders
    }

    func complete(system: String,
                  messages: [ChatMessage],
                  tools: [Tool],
                  callbacks: StreamCallbacks) async throws -> AssistantTurn {
        var body: [String: Any] = [
            "model": model,
            "messages": encode(system: system, messages: messages),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description, "parameters": tool.schema]]
            }
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSON.data(body)

        var turn = AssistantTurn()
        var calls: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in try await HTTP.streamLines(req) {
            guard let payload = HTTP.sseData(line) else { continue }
            if payload == "[DONE]" { break }
            guard let obj = JSON.object(payload) else { continue }
            if let err = obj["error"] { throw AgentError("Provider error: \(JSON.string(err))") }

            if let u = obj["usage"] as? [String: Any] {
                turn.usage.input = u["prompt_tokens"] as? Int ?? turn.usage.input
                turn.usage.output = u["completion_tokens"] as? Int ?? turn.usage.output
                if let details = u["prompt_tokens_details"] as? [String: Any] {
                    turn.usage.cacheRead = details["cached_tokens"] as? Int ?? 0
                }
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let finish = choice["finish_reason"] as? String { turn.stopReason = finish }
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            // Reasoning models on OpenRouter / DeepSeek / Ollama expose their reasoning here.
            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                callbacks.onThinking(r)
            }
            if let c = delta["content"] as? String, !c.isEmpty {
                turn.text += c
                callbacks.onText(c)
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let idx = tc["index"] as? Int ?? (tc["id"] != nil ? calls.count : max(calls.count - 1, 0))
                var entry = calls[idx] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let n = fn["name"] as? String, entry.name.isEmpty { entry.name = n }
                    if let a = fn["arguments"] as? String {
                        entry.args += a
                    } else if let a = fn["arguments"] as? [String: Any] {
                        entry.args = JSON.string(a)   // some servers send a decoded object
                    }
                }
                calls[idx] = entry
            }
        }

        turn.toolCalls = calls.keys.sorted().compactMap { idx in
            guard let c = calls[idx], !c.name.isEmpty else { return nil }
            let id = c.id.isEmpty ? "call_\(idx)_\(UUID().uuidString.prefix(8))" : c.id
            return ToolCall(id: id, name: c.name, arguments: c.args)
        }
        return turn
    }

    private func encode(system: String, messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            switch message {
            case .user(let text):
                out.append(["role": "user", "content": text])
            case .assistant(let turn):
                var m: [String: Any] = ["role": "assistant", "content": turn.text.isEmpty ? NSNull() : turn.text]
                if !turn.toolCalls.isEmpty {
                    m["tool_calls"] = turn.toolCalls.map { call -> [String: Any] in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
                    }
                }
                out.append(m)
            case .toolResult(let callId, let content, _):
                out.append(["role": "tool", "tool_call_id": callId, "content": content])
            }
        }
        return out
    }
}
