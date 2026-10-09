import Foundation

enum ProviderKind: String {
    case openai, anthropic
}

struct Preset {
    let kind: ProviderKind
    let baseURL: String
    let keyEnv: String?
    let defaultModel: String?
}

let presets: [String: Preset] = [
    "anthropic": Preset(kind: .anthropic, baseURL: "https://api.anthropic.com", keyEnv: "ANTHROPIC_API_KEY", defaultModel: "claude-opus-5-5"),
    "openai": Preset(kind: .openai, baseURL: "https://api.openai.com/v1", keyEnv: "OPENAI_API_KEY", defaultModel: nil),
    "openrouter": Preset(kind: .openai, baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY", defaultModel: nil),
    "ollama": Preset(kind: .openai, baseURL: "http://localhost:11434/v1", keyEnv: nil, defaultModel: nil),
    "lmstudio": Preset(kind: .openai, baseURL: "http://localhost:1234/v1", keyEnv: nil, defaultModel: nil),
]

/// Resolution order (later wins): preset defaults < ~/.iagent/config.json < IAGENT_* env vars < CLI flags.
struct Config {
    var provider: String?
    var kind: ProviderKind?
    var baseURL: String?
    var model: String?
    var apiKey: String?
    var apiKeyEnv: String?
    /// Keychain item holding the API key: generic password with this service name (account optional).
    var apiKeyKeychain: String?
    var apiKeyKeychainAccount: String?
    var allowInsecureHTTP = false
    /// Nothing leaves this Mac: model server on loopback only, network tools off, bash sandboxed without network.
    var localOnly = false
    var maxTokens: Int?
    var effort: String?
    var thinking = true
    var headers: [String: String] = [:]
    var autoApprove = false
    var appleTools = true
    /// Non-fatal configuration warnings to show at startup.
    var warnings: [String] = []

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".iagent/config.json")

    mutating func loadFile() throws {
        guard let data = try? Data(contentsOf: Self.path) else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentError("Could not parse \(Self.path.path)")
        }
        // A plaintext key in a file others can read is a credential leak (CWE-732); ssh applies the same rule.
        if String(decoding: data, as: UTF8.self).contains("\"apiKey\""),
           let perms = (try? FileManager.default.attributesOfItem(atPath: Self.path.path))?[.posixPermissions] as? Int,
           perms & 0o077 != 0 {
            warnings.append("\(Self.path.path) contains an apiKey and is readable by other users (mode \(String(perms, radix: 8))). Run: chmod 600 \(Self.path.path) — or store the key in the Keychain (apiKeyKeychain).")
        }
        // A config may define named profiles: {"profile": "local", "profiles": {"local": {...}}}
        var values = obj
        if let profiles = obj["profiles"] as? [String: [String: Any]] {
            let selected = ProcessInfo.processInfo.environment["IAGENT_PROFILE"] ?? obj["profile"] as? String
            if let selected {
                guard let p = profiles[selected] else { throw AgentError("Profile '\(selected)' not found in \(Self.path.path)") }
                values.merge(p) { _, new in new }
            }
        }
        apply(values)
    }

    mutating func apply(_ v: [String: Any]) {
        if let s = v["provider"] as? String { provider = s }
        if let s = v["kind"] as? String { kind = ProviderKind(rawValue: s) }
        if let s = v["baseURL"] as? String { baseURL = s }
        if let s = v["model"] as? String { model = s }
        if let s = v["apiKey"] as? String { apiKey = s }
        if let s = v["apiKeyEnv"] as? String { apiKeyEnv = s }
        if let s = v["apiKeyKeychain"] as? String { apiKeyKeychain = s }
        if let s = v["apiKeyKeychainAccount"] as? String { apiKeyKeychainAccount = s }
        if let b = v["allowInsecureHTTP"] as? Bool { allowInsecureHTTP = b }
        if let b = v["localOnly"] as? Bool { localOnly = b }
        if let n = v["maxTokens"] as? Int { maxTokens = n }
        if let s = v["effort"] as? String { effort = s }
        if let b = v["thinking"] as? Bool { thinking = b }
        if let b = v["appleTools"] as? Bool { appleTools = b }
        if let h = v["headers"] as? [String: String] { headers.merge(h) { _, new in new } }
    }

    mutating func loadEnv() {
        let env = ProcessInfo.processInfo.environment
        if let s = env["IAGENT_PROVIDER"] { provider = s }
        if let s = env["IAGENT_BASE_URL"] { baseURL = s }
        if let s = env["IAGENT_MODEL"] { model = s }
        if let s = env["IAGENT_API_KEY"] { apiKey = s }
        if let s = env["IAGENT_EFFORT"] { effort = s }
        if let s = env["IAGENT_LOCAL_ONLY"] { localOnly = ["1", "true", "yes"].contains(s.lowercased()) }
    }

    func makeProvider() throws -> LLMProvider {
        let env = ProcessInfo.processInfo.environment
        // Local-only never autodetects a cloud provider from an API key in the environment.
        let name = provider ?? (localOnly ? (baseURL != nil ? "custom" : "ollama") : autodetectProvider(env))
        let preset = presets[name]
        guard let resolvedKind = kind ?? preset?.kind ?? (baseURL != nil ? .openai : nil) else {
            throw AgentError("Unknown provider '\(name)'. Use one of: \(presets.keys.sorted().joined(separator: ", ")), or set --base-url for any OpenAI-compatible server.")
        }
        guard let urlString = baseURL ?? preset?.baseURL, let url = URL(string: urlString) else {
            throw AgentError("No base URL configured for provider '\(name)'")
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw AgentError("Base URL must be http(s): \(urlString)")
        }
        if localOnly && !Transport.isLoopback(url) {
            throw AgentError("Local-only mode refuses the model server \(url.host ?? urlString): prompts and files would leave this Mac. Use a model running on this Mac, e.g. --provider ollama or --provider lmstudio, or drop --local.")
        }
        // Prompts, code and the API key must not cross the network in cleartext (CWE-319).
        if url.scheme?.lowercased() == "http" && !Transport.isLocal(url) && !allowInsecureHTTP {
            throw AgentError("Refusing plain-HTTP connection to \(url.host ?? urlString): prompts and the API key would be sent unencrypted. Use https, or set \"allowInsecureHTTP\": true in the config if you really mean it.")
        }
        let base = preset ?? presets[resolvedKind == .anthropic ? "anthropic" : "custom"]
        let keyEnv = apiKeyEnv ?? base?.keyEnv
        if let keyEnv { SecretEnv.names.insert(keyEnv) }
        let key = try apiKey ?? keychainKey() ?? keyEnv.flatMap { env[$0] }
        Redact.register(key)
        guard let model = model ?? base?.defaultModel else {
            throw AgentError("No model set for provider '\(name)'. Pass --model <id> or set IAGENT_MODEL.")
        }

        switch resolvedKind {
        case .anthropic:
            guard let key, !key.isEmpty else {
                throw AgentError("Missing API key: set \(keyEnv ?? "ANTHROPIC_API_KEY") (or IAGENT_API_KEY)")
            }
            return AnthropicProvider(baseURL: url, apiKey: key, model: model, maxTokens: maxTokens ?? 64_000,
                                     effort: effort ?? "high", thinking: thinking, extraHeaders: headers)
        case .openai:
            if let keyEnv, (key ?? "").isEmpty {
                throw AgentError("Missing API key: set \(keyEnv) (or IAGENT_API_KEY)")
            }
            var hdrs = headers
            if name == "openrouter" {
                hdrs["X-Title"] = hdrs["X-Title"] ?? "iagent"
            }
            return OpenAICompatibleProvider(baseURL: url, apiKey: key, model: model, maxTokens: maxTokens, extraHeaders: hdrs)
        }
    }

    /// Reads the API key from the login Keychain (`security add-generic-password -s <service> -a <account> -w`).
    private func keychainKey() throws -> String? {
        guard let service = apiKeyKeychain else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service] + (apiKeyKeychainAccount.map { ["-a", $0] } ?? []) + ["-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let key = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !key.isEmpty else {
            throw AgentError("No Keychain item with service '\(service)'. Add one with: security add-generic-password -s \(service) -a iagent -w")
        }
        return key
    }

    private func autodetectProvider(_ env: [String: String]) -> String {
        if baseURL != nil { return "custom" }
        if env["ANTHROPIC_API_KEY"] != nil { return "anthropic" }
        if env["OPENAI_API_KEY"] != nil { return "openai" }
        if env["OPENROUTER_API_KEY"] != nil { return "openrouter" }
        return "ollama"
    }
}
