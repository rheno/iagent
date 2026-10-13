import Foundation

struct ToolCall {
    let id: String
    let name: String
    /// Raw JSON string of the arguments as produced by the model.
    let arguments: String
}

struct Usage {
    var input = 0
    var output = 0
    var cacheRead = 0

    static func += (lhs: inout Usage, rhs: Usage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
    }
}

struct AssistantTurn {
    var text: String = ""
    var toolCalls: [ToolCall] = []
    /// Provider-native content blocks (Anthropic) that must be echoed back unchanged,
    /// e.g. thinking blocks with signatures.
    var rawBlocks: [[String: Any]]?
    var stopReason: String?
    var usage = Usage()
}

enum ChatMessage {
    case user(String)
    case assistant(AssistantTurn)
    case toolResult(callId: String, content: String, isError: Bool)
}

struct StreamCallbacks {
    var onText: (String) -> Void
    var onThinking: (String) -> Void
}

protocol LLMProvider: AnyObject {
    var label: String { get }
    var model: String { get set }
    func complete(system: String,
                  messages: [ChatMessage],
                  tools: [Tool],
                  callbacks: StreamCallbacks) async throws -> AssistantTurn
}

// MARK: - Shared HTTP / SSE plumbing

enum HTTP {
    /// Model API traffic: ephemeral (no cookies/cache on disk), TLS by default, and never follows redirects,
    /// so an API key header can't be replayed to another host.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600   // idle timeout between bytes; long thinking pauses
        cfg.timeoutIntervalForResource = 3600
        cfg.httpShouldSetCookies = false
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// web_fetch traffic: separate ephemeral session, no credentials, redirects only within the approved host.
    static let webSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: cfg, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    private static let retryable: Set<Int> = [408, 409, 429, 500, 502, 503, 504, 529]

    /// POSTs `body` and returns the SSE line stream, retrying transient failures before any bytes arrive.
    static func streamLines(_ request: URLRequest) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var attempt = 0
        while true {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError("Non-HTTP response") }
            if (200..<300).contains(http.statusCode) { return bytes.lines }

            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > 16_000 { break }
            }
            let text = String(decoding: body, as: UTF8.self)
            if retryable.contains(http.statusCode), attempt < 3 {
                attempt += 1
                // The server's value is untrusted: a negative or NaN delay would trap in UInt64(_:).
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let delay = min(retryAfter ?? pow(2.0, Double(attempt)), 30)
                emit(Style.dim("  (HTTP \(http.statusCode), retrying in \(Int(delay))s...)\n"))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            if (300..<400).contains(http.statusCode) {
                throw AgentError("HTTP \(http.statusCode) redirect from \(request.url?.host ?? "server") refused (API requests never follow redirects). Check the base URL.")
            }
            throw AgentError("HTTP \(http.statusCode) from \(request.url?.host ?? "server"): \(text.prefix(2000))")
        }
    }

    /// Extracts the JSON payload from an SSE `data:` line; nil for other lines.
    static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    }
}
