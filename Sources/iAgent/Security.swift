import Foundation

// Security controls shared by the agent loop and tools. See SECURITY.md for the threat model.

// MARK: - Terminal output sanitization (CWE-150, OWASP LLM05)

enum Sanitize {
    /// Makes untrusted text (model output, tool results, file/web content, device names) safe to print:
    /// control characters and escape sequences become visible markers so they can't retitle the window,
    /// erase lines, move the cursor, write the clipboard (OSC 52) or forge an approval prompt.
    /// Bidi overrides and zero-width characters are made visible too (Trojan Source, CVE-2021-42574).
    static func terminal(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                out.append(scalar)                                   // newline, tab
            case 0x1B:
                out.append(contentsOf: "␛".unicodeScalars)           // ESC
            case 0x0D:
                out.append(contentsOf: "␍".unicodeScalars)           // carriage return
            case 0x00...0x1F:
                out.append(contentsOf: "^\(Character(UnicodeScalar(scalar.value + 0x40)!))".unicodeScalars)
            case 0x7F, 0x80...0x9F:
                out.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                out.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Sanitized deep copy of tool arguments, used only for display (summaries, approval previews).
    static func displayArgs(_ args: [String: Any]) -> [String: Any] {
        args.mapValues(displayValue)
    }

    private static func displayValue(_ v: Any) -> Any {
        switch v {
        case let s as String: return terminal(s)
        case let a as [Any]: return a.map(displayValue)
        case let d as [String: Any]: return d.mapValues(displayValue)
        default: return v
        }
    }
}

// MARK: - Filesystem policy (CWE-22, OWASP LLM02/LLM06)

enum PathPolicy {
    enum Zone { case inside, outside, sensitive }

    /// Credential and persistence locations. Reading them can leak secrets to the model provider;
    /// writing them can plant persistence. Both always need explicit confirmation.
    private static let sensitiveComponents: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".gcloud", ".config/gcloud", "Keychains",
        ".password-store", ".iagent",
    ]
    private static let sensitiveNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", ".my.cnf", "credentials", "credentials.json",
        "id_rsa", "id_ecdsa", "id_ed25519", "id_dsa", "authorized_keys", "known_hosts",
        ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", "sudoers",
    ]
    private static let sensitiveExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "kdbx", "mobileprovision"]

    static func canonical(_ url: URL) -> URL {
        // Resolve symlinks of the deepest existing ancestor, so a symlink inside the project
        // pointing at ~/.ssh is classified by its real target.
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for c in tail { resolved.appendPathComponent(c) }
        return resolved.standardizedFileURL
    }

    static func isSensitive(_ url: URL) -> Bool {
        let path = canonical(url).path
        let name = (path as NSString).lastPathComponent
        if name == ".env" || name.hasPrefix(".env.") && !name.hasSuffix(".sample") && !name.hasSuffix(".example") { return true }
        if sensitiveNames.contains(name) || sensitiveExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        if LaunchAgentDirs.contains(where: { path.contains($0) }) { return true }
        return sensitiveComponents.contains { path.contains("/\($0)/") || path.hasSuffix("/\($0)") }
    }

    private static let LaunchAgentDirs = ["/Library/LaunchAgents/", "/Library/LaunchDaemons/"]

    static func zone(_ url: URL, cwd: URL) -> Zone {
        if isSensitive(url) { return .sensitive }
        let path = canonical(url).path
        let root = canonical(cwd).path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? .inside : .outside
    }

    /// Approval for reading/listing: free inside the project, confirmed outside it, always confirmed for secrets.
    static func readApproval(_ path: String?, _ ctx: ToolContext) -> Approval {
        switch zone(ctx.resolve(path ?? "."), cwd: ctx.cwd) {
        case .inside: return .none
        case .outside: return .askScoped("outside working dir")
        case .sensitive: return .sensitive("reads a credential/secret file, which would be sent to the model provider")
        }
    }

    static func writeApproval(_ path: String?, _ ctx: ToolContext) -> Approval {
        switch zone(ctx.resolve(path ?? "."), cwd: ctx.cwd) {
        case .inside: return .ask
        case .outside: return .askScoped("outside working dir")
        case .sensitive: return .sensitive("modifies a credential, shell-startup or persistence file")
        }
    }
}

// MARK: - Argument injection (CWE-88)

/// Rejects values that a command-line tool would parse as an option (e.g. a bundle id of `--erase`).
func operand(_ value: String, _ name: String) throws -> String {
    guard !value.isEmpty else { throw AgentError("\(name) must not be empty") }
    guard !value.hasPrefix("-") else { throw AgentError("\(name) must not start with '-'") }
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw AgentError("\(name) contains control characters") }
    return value
}

// MARK: - Secrets kept away from child processes (OWASP LLM02)

enum SecretEnv {
    /// Environment variables holding the LLM API key; removed from every child process (bash, osascript, ...)
    /// so a prompt-injected command can't read and exfiltrate them.
    nonisolated(unsafe) static var names: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY",
                                                         "OPENROUTER_API_KEY", "IAGENT_API_KEY"]

    static var childEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !names.contains($0.key) }
    }
}

// MARK: - Transport (CWE-319)

enum Transport {
    /// Plain HTTP is only acceptable when traffic never leaves this machine or the local network.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let b) where (16...31).contains(b): return true
        default: return false
        }
    }
}

/// Refuses all redirects: an API key in a header must never be replayed to another URL.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Follows redirects only within the approved host; cross-host hops need a new, explicitly approved fetch.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url?.host?.lowercased()
        completionHandler(request.url?.host?.lowercased() == from ? request : nil)
    }
}
