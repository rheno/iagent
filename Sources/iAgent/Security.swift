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
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".gcloud", ".config/gcloud", "keychains",
        ".password-store", ".iagent", ".config/gh",
    ]
    private static let sensitiveNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", ".my.cnf", "credentials", "credentials.json",
        "credentials.toml", ".credentials.json", ".vault-token", ".envrc",
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

    /// The canonical path, case-folded for matching: APFS is case-insensitive by default, so `.ZLOGIN` or `.ENVRC`
    /// is the file zsh or direnv loads. It folds like Unicode case folding, not lowercased(): `.zſhrc` (long s,
    /// U+017F) is the file zsh opens as `.zshrc`. canonical() restores the real case only for files that already exist.
    private static func matchPath(_ url: URL) -> (path: String, name: String) {
        let path = canonical(url).path.folding(options: [.caseInsensitive], locale: nil)
        return (path, (path as NSString).lastPathComponent)
    }

    static func isSensitive(_ url: URL) -> Bool {
        let (path, name) = matchPath(url)
        if name == ".env" || name.hasPrefix(".env.") && !name.hasSuffix(".sample") && !name.hasSuffix(".example") { return true }
        if sensitiveNames.contains(name) || sensitiveExtensions.contains((name as NSString).pathExtension) { return true }
        if LaunchAgentDirs.contains(where: { path.contains($0) }) { return true }
        return sensitiveComponents.contains { path.contains("/\($0)/") || path.hasSuffix("/\($0)") }
    }

    private static let LaunchAgentDirs = ["/library/launchagents/", "/library/launchdaemons/"]

    /// Files that run code later (login shells, git hooks and config such as core.hooksPath or core.fsmonitor).
    /// Fine to read; writing one would turn a file edit into a command that runs without a bash approval.
    private static let persistenceNames: Set<String> = [".zlogin", ".zlogout", ".bash_login", ".bash_logout", ".gitconfig"]
    private static let persistenceDirs = ["/.git/hooks/", "/.config/git/", "/.config/fish/"]

    static func runsCodeLater(_ url: URL) -> Bool {
        let (path, name) = matchPath(url)
        return persistenceNames.contains(name) || path.hasSuffix("/.git/config") || path.hasSuffix("/.git/hooks")
            || persistenceDirs.contains { path.contains($0) } || isNestedGitConfig(path)
    }

    /// Hooks and config of submodules and worktrees: `.git/modules/<name>/hooks/…`, `.git/worktrees/<name>/config.worktree`.
    private static func isNestedGitConfig(_ path: String) -> Bool {
        guard let r = path.range(of: "/.git/") else { return false }
        let inner = path[r.upperBound...].split(separator: "/")
        return inner.contains("hooks") || ["config", "config.worktree"].contains(inner.last ?? "")
    }

    /// Scope for "always" outside the project: one directory, never the whole filesystem.
    private static func outsideScope(_ url: URL) -> Approval {
        var isDir: ObjCBool = false
        let c = canonical(url)
        let dir = FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir) && isDir.boolValue ? c : c.deletingLastPathComponent()
        return .askScoped("outside working dir: \(dir.path)")
    }

    static func zone(_ url: URL, cwd: URL) -> Zone {
        if isSensitive(url) { return .sensitive }
        let path = canonical(url).path
        let root = canonical(cwd).path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? .inside : .outside
    }

    /// A regular file with more than one hard link. Unlike a symlink, a hard link can't be followed to see what else
    /// it is (a link inside the project to ~/.aws/credentials looks like any project file), so it isn't free to read.
    static func hasOtherLinks(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink > 1
    }

    /// Approval for reading/listing: free inside the project, confirmed outside it, always confirmed for secrets.
    static func readApproval(_ path: String?, _ ctx: ToolContext) -> Approval {
        let url = ctx.resolve(path ?? ".")
        switch zone(url, cwd: ctx.cwd) {
        case .inside: return hasOtherLinks(url) ? .askScoped("hard-linked file: \(canonical(url).path)") : .none
        case .outside: return outsideScope(ctx.resolve(path ?? "."))
        case .sensitive:
            // A cloud model provider must never receive a secret file; a model on this Mac may, with confirmation.
            return ctx.localOnly ? .sensitive("reads a credential/secret file")
                : .blocked("\(Sanitize.terminal(path ?? "")) is a credential/secret file. Its contents are never sent to a cloud model provider; run iagent --local with a local model to work with it")
        }
    }

    static func writeApproval(_ path: String?, _ ctx: ToolContext) -> Approval {
        let url = ctx.resolve(path ?? ".")
        if runsCodeLater(url) { return .sensitive("modifies a file that runs code later (git hook/config, login shell)") }
        switch zone(url, cwd: ctx.cwd) {
        case .inside: return .ask
        case .outside: return outsideScope(url)
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

// MARK: - Secret redaction before anything reaches the model (OWASP LLM02, CWE-200)

enum Redact {
    /// Exact secret values known at startup (API keys, *_TOKEN/*_SECRET env vars), masked wherever they appear.
    nonisolated(unsafe) private(set) static var known: Set<String> = []

    static func register(_ value: String?) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), v.count >= 8 else { return }
        known.insert(v)
    }

    /// Registers the values of environment variables whose names say they hold a credential.
    static func registerEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        registerCredentials(env)
    }

    /// Registers the values whose names say they hold a credential (env vars, custom HTTP headers such as a
    /// gateway's `Authorization` or `X-Api-Key`). For `Bearer <token>`-style values the token is registered too.
    static func registerCredentials(_ values: [String: String]) {
        let name = try! NSRegularExpression(pattern: "(KEY|TOKEN|SECRET|PASSW(OR)?D|CREDENTIAL|AUTH|COOKIE)", options: .caseInsensitive)
        for (k, v) in values where name.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil {
            register(v)
            if let scheme = v.range(of: #"^(?i)(bearer|basic|token)\s+"#, options: .regularExpression) {
                register(String(v[scheme.upperBound...]))
            }
        }
    }

    static let mask = "[REDACTED]"

    /// Well-known credential formats, replaced whole.
    private static let tokens: [NSRegularExpression] = [
        "-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----[\\s\\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----|\\z)",
        "\\bsk-ant-[A-Za-z0-9_-]{20,}",
        "\\bsk-(proj-|svcacct-|or-v1-)?[A-Za-z0-9_-]{20,}",
        "\\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,})",
        "\\bxox[abposr]-[A-Za-z0-9-]{10,}",
        "\\b(AKIA|ASIA)[0-9A-Z]{16}\\b",
        "\\bAIza[0-9A-Za-z_-]{35}",
        "\\b[srp]k_(live|test)_[A-Za-z0-9]{16,}",
        "\\b(npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,})",
        "\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}",
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Credentials whose surroundings identify them; only the value (last capture group) is masked.
    private static let values: [NSRegularExpression] = [
        "(?i)\\b(bearer|basic)\\s+([A-Za-z0-9._~+/=-]{16,})",
        "(?i)\\b[a-z][a-z0-9+.-]*://[^\\s:/@]+:([^\\s@/]+)@",
        "(?i)[A-Za-z0-9_.-]*(api[_-]?key|secret|token|passw(or)?d|pwd|credential|private[_-]?key|auth)[A-Za-z0-9_.-]*[\"']?\\s*[:=]\\s*[\"']?([^\\s\"'`,;()<>{}\\[\\]]{8,})",
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Masks secrets in text bound for the model provider. Returns the text and how many secrets were masked.
    /// A key=value is masked only when the value has letters and digits, so code like `apiKey = config.apiKey` survives.
    static func secrets(_ text: String) -> (text: String, count: Int) {
        var s = text, count = 0
        for v in known.sorted(by: { $0.count > $1.count }) where s.contains(v) {
            count += s.components(separatedBy: v).count - 1
            s = s.replacingOccurrences(of: v, with: mask)
        }
        for re in tokens {
            let n = re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
            guard n > 0 else { continue }
            count += n
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: mask)
        }
        for re in values {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range(at: m.numberOfRanges - 1), in: s) else { continue }
                let value = s[r]
                guard value != mask, value.contains(where: \.isNumber), value.contains(where: \.isLetter) else { continue }
                s.replaceSubrange(r, with: mask)
                count += 1
            }
        }
        return (s, count)
    }
}

// MARK: - Local-only mode: nothing leaves this Mac

enum LocalOnly {
    /// Tools whose purpose is to reach the network, other devices or other people, or that can drive any app.
    static let removedTools: Set<String> = ["web_fetch", "airdrop", "messages", "shortcuts", "applescript", "ios_device", "apple_devices"]

    /// Actions that sync through iCloud, hand data to nearby devices (Universal Clipboard) or open URLs.
    static let blockedActions: Set<String> = [
        "mac.open", "mac.clipboard_set", "reminders.add", "reminders.complete", "reminders.delete",
        "calendar.add", "calendar.delete", "notes.create", "notes.append", "simulator.openurl", "simulator.raw",
    ]

    /// Seatbelt profile for the bash tool: no network except loopback, no DNS, no opening apps/URLs through
    /// LaunchServices and no Apple Events (another app could send the data on our behalf).
    /// DNS goes through mDNSResponder's Unix socket, not only its Mach services: without that rule a lookup of
    /// `<data>.attacker.example` still leaves the Mac. Writes to iCloud Drive and File Provider folders (Dropbox,
    /// OneDrive, Google Drive under ~/Library/CloudStorage) are denied too, since their daemons upload what lands
    /// there. HOME is passed with `sandbox-exec -D HOME=…`.
    static let sandboxProfile = """
    (version 1)
    (allow default)
    (deny network-outbound (remote ip))
    (allow network-outbound (remote ip "localhost:*"))
    (deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
    (deny mach-lookup (global-name "com.apple.dnssd.service") (global-name "com.apple.mDNSResponder") (global-name "com.apple.nsurlsessiond"))
    (deny file-write* (subpath (string-append (param "HOME") "/Library/Mobile Documents"))
                      (subpath (string-append (param "HOME") "/Library/CloudStorage")))
    (deny lsopen)
    (deny appleevent-send)
    """
}

// MARK: - Transport (CWE-319)

enum Transport {
    /// This Mac only (not the LAN): the bar for --local, where nothing may leave the machine.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost") || ipv4(host)?.first == 127
    }

    /// The four octets of a dotted-quad IPv4 address, or nil for anything else (`10.0.0.1.evil.example` is a name).
    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { $0.allSatisfy { $0.isASCII && $0.isNumber } ? Int($0) : nil }.filter { (0...255).contains($0) }
        return parts.count == 4 && octets.count == 4 ? octets : nil
    }

    /// Plain HTTP is only acceptable when traffic never leaves this machine or the local network.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        guard let octets = ipv4(host) else { return false }
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
        let from = task.originalRequest?.url, to = request.url
        let sameHost = to?.host?.lowercased() == from?.host?.lowercased()
        let downgrade = from?.scheme?.lowercased() == "https" && to?.scheme?.lowercased() != "https"
        completionHandler(sameHost && !downgrade ? request : nil)
    }
}
