import Foundation
import Testing
@testable import iAgent

// Regression tests for the controls in SECURITY.md ("How it was verified"). All payloads are harmless.

/// A throwaway project directory, removed when the test ends.
final class Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iagent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Same cwd canonicalization as main.swift (the temp dir lives under the /var symlink).
    var ctx: ToolContext { ToolContext(cwd: realPath(root),permissions: Permissions(autoApprove: false)) }

    @discardableResult
    func write(_ path: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

func isSensitive(_ a: Approval) -> Bool {
    if case .sensitive = a { return true }
    return false
}

func isBlocked(_ a: Approval) -> Bool {
    if case .blocked = a { return true }
    return false
}

// MARK: - Terminal escape injection (CWE-150)

@Suite struct SanitizeTests {
    @Test func escapeSequencesBecomeVisible() {
        let out = Sanitize.terminal("a\u{1B}]52;c;ZXZpbA==\u{07}b\u{1B}[2J")
        #expect(!out.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        #expect(out.contains("␛"))
        #expect(out.contains("^G"))
    }

    @Test func carriageReturnCannotHideText() {
        #expect(Sanitize.terminal("rm -rf ~\rls") == "rm -rf ~␍ls")
    }

    @Test func bidiAndZeroWidthAreShown() {
        #expect(Sanitize.terminal("a\u{202E}b") == "a⟨U+202E⟩b")
        #expect(Sanitize.terminal("a\u{200B}b") == "a⟨U+200B⟩b")
        #expect(Sanitize.terminal("a\u{9B}b") == "a⟨U+009B⟩b")   // C1 CSI
    }

    @Test func newlinesTabsAndUnicodeArePreserved() {
        #expect(Sanitize.terminal("a\tb\nc ✻ é") == "a\tb\nc ✻ é")
    }

    @Test func displayArgsSanitizesNestedValues() {
        let shown = Sanitize.displayArgs(["cmd": "x\u{1B}", "list": ["y\r"], "n": 3])
        #expect(shown["cmd"] as? String == "x␛")
        #expect((shown["list"] as? [Any])?.first as? String == "y␍")
        #expect(shown["n"] as? Int == 3)
    }
}

// MARK: - Path policy and secret files (CWE-22/200)

@Suite struct PathPolicyTests {
    @Test(arguments: [".env", ".env.production", "id_rsa", "server.pem", "cert.p12", ".netrc", ".git-credentials", ".zshrc"])
    func secretFilesAreSensitive(_ name: String) throws {
        let box = try Sandbox()
        #expect(PathPolicy.isSensitive(box.root.appendingPathComponent(name)))
    }

    @Test(arguments: [".env.example", ".env.sample", "README.md", "environment.swift"])
    func ordinaryFilesAreNotSensitive(_ name: String) throws {
        let box = try Sandbox()
        #expect(!PathPolicy.isSensitive(box.root.appendingPathComponent(name)))
    }

    @Test func credentialDirectoriesAreSensitive() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in [".ssh/config", ".aws/credentials", ".kube/config", ".iagent/config.json", "Library/LaunchAgents/x.plist"] {
            #expect(PathPolicy.isSensitive(home.appendingPathComponent(dir)), "\(dir)")
        }
    }

    @Test func symlinkToSecretIsCaught() throws {
        let box = try Sandbox()
        let secret = try box.write("elsewhere/.ssh/id_rsa", "not a real key")
        let link = box.root.appendingPathComponent("project/innocent.txt")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(PathPolicy.zone(link, cwd: box.root.appendingPathComponent("project")) == .sensitive)
    }

    @Test func zonesInsideAndOutside() throws {
        let box = try Sandbox()
        let project = box.root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(PathPolicy.zone(project.appendingPathComponent("src/a.swift"), cwd: project) == .inside)
        #expect(PathPolicy.zone(project.appendingPathComponent("../proj2/a.swift"), cwd: project) == .outside)
        #expect(PathPolicy.zone(URL(fileURLWithPath: "/etc/hosts"), cwd: project) == .outside)
    }

    @Test func approvalLevels() throws {
        let box = try Sandbox()
        let ctx = box.ctx
        #expect(PathPolicy.readApproval("a.txt", ctx) == .none)
        #expect(PathPolicy.writeApproval("a.txt", ctx) == .ask)
        #expect(PathPolicy.readApproval("/etc/hosts", ctx) == .askScoped("outside working dir"))
        #expect(isBlocked(PathPolicy.readApproval(".env", ctx)))         // never sent to a cloud model
        #expect(isSensitive(PathPolicy.writeApproval("~/.zshrc", ctx)))
        var local = ctx
        local.localOnly = true
        #expect(isSensitive(PathPolicy.readApproval(".env", local)))     // a local model may read it, with confirmation
    }
}

// MARK: - Argument injection (CWE-78/88)

@Suite struct InjectionTests {
    @Test func optionLikeOperandsAreRejected() {
        #expect(throws: AgentError.self) { try operand("--erase", "bundle_id") }
        #expect(throws: AgentError.self) { try operand("-o", "text") }
        #expect(throws: AgentError.self) { try operand("", "name") }
        #expect(throws: AgentError.self) { try operand("a\nb", "name") }
        #expect((try? operand("com.example.app", "bundle_id")) == "com.example.app")
    }

    @Test func osascriptArgumentsArriveAsData() async throws {
        let out = try await runOSAScript("on run argv\nreturn item 1 of argv\nend run", args: ["-e"])
        #expect(out == "-e")
    }

    @Test func argvIsNotInterpretedByAShell() async throws {
        let r = try await runCommand(["printf", "%s", "$(echo pwned); `id`"])
        #expect(r.stdout == "$(echo pwned); `id`")
    }
}

// MARK: - Secrets kept from child processes (OWASP LLM02)

@Suite(.serialized) struct SecretEnvTests {
    @Test func apiKeysAreRemovedFromBash() async throws {
        setenv("OPENAI_API_KEY", "sk-test-not-a-real-key", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        let box = try Sandbox()
        let out = try await runShell("printf '[%s]' \"$OPENAI_API_KEY\"", cwd: box.root, timeout: 10)
        #expect(out.hasPrefix("[]"))
    }

    @Test func customKeyEnvIsRemovedToo() {
        setenv("IAGENT_TEST_CUSTOM_KEY", "secret", 1)
        defer { unsetenv("IAGENT_TEST_CUSTOM_KEY"); SecretEnv.names.remove("IAGENT_TEST_CUSTOM_KEY") }
        SecretEnv.names.insert("IAGENT_TEST_CUSTOM_KEY")
        #expect(SecretEnv.childEnvironment["IAGENT_TEST_CUSTOM_KEY"] == nil)
    }
}

// MARK: - Transport (CWE-319)

@Suite struct TransportTests {
    @Test(arguments: ["http://localhost:11434/v1", "http://127.0.0.1:1234", "http://192.168.1.20:8000",
                      "http://10.0.0.5", "http://172.20.0.1", "http://mybox.local:8080"])
    func localHosts(_ s: String) {
        #expect(Transport.isLocal(URL(string: s)!))
    }

    @Test(arguments: ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://localhost.example.com"])
    func remoteHosts(_ s: String) {
        #expect(!Transport.isLocal(URL(string: s)!))
    }

    @Test func plainHTTPToRemoteServerIsRefused() {
        var config = Config()
        config.baseURL = "http://example.com/v1"
        config.model = "m"
        #expect(throws: AgentError.self) { try config.makeProvider() }
    }

    @Test func plainHTTPToLocalServerIsAllowed() throws {
        var config = Config()
        config.provider = "ollama"
        config.model = "qwen3-coder"
        _ = try config.makeProvider()
    }

    @Test func apiRedirectsAreNeverFollowed() async {
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.example.com/v1")!)
        let next = URLRequest(url: URL(string: "https://evil.example/collect")!)
        let followed = await withCheckedContinuation { c in
            NoRedirects().urlSession(.shared, task: task, willPerformHTTPRedirection: redirect(), newRequest: next) { c.resume(returning: $0) }
        }
        #expect(followed == nil)
    }

    @Test func webFetchRedirectsStayOnTheSameHost() async {
        let task = URLSession.shared.dataTask(with: URL(string: "https://docs.example.com/a")!)
        func follow(_ to: String) async -> URLRequest? {
            await withCheckedContinuation { c in
                SameHostRedirects().urlSession(.shared, task: task, willPerformHTTPRedirection: redirect(),
                                               newRequest: URLRequest(url: URL(string: to)!)) { c.resume(returning: $0) }
            }
        }
        #expect(await follow("https://docs.example.com/b") != nil)
        #expect(await follow("https://evil.example/b") == nil)
    }

    private func redirect() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 307, httpVersion: nil, headerFields: nil)!
    }
}

// MARK: - Approvals (OWASP LLM06)

@Suite struct PermissionTests {
    @Test func readOnlyAndAutoApprovedCallsPass() {
        #expect(Permissions(autoApprove: false).check(key: "read_file", level: .none, preview: "") == nil)
        #expect(Permissions(autoApprove: true).check(key: "write_file", level: .ask, preview: "") == nil)
        #expect(Permissions(autoApprove: true).check(key: "bash", level: .askScoped("command: ls"), preview: "") == nil)
    }

    @Test(.enabled(if: isatty(STDIN_FILENO) == 0, "needs a non-interactive stdin"))
    func nonInteractiveRunsRefuseSensitiveCallsEvenWithYolo() {
        let denied = Permissions(autoApprove: true).check(key: "messages.send", level: .sensitive("sends a message"), preview: "")
        #expect(denied?.contains("interactive confirmation") == true)
    }

    @Test(.enabled(if: isatty(STDIN_FILENO) == 0, "needs a non-interactive stdin"))
    func nonInteractiveRunsRefuseAskWithoutYolo() {
        #expect(Permissions(autoApprove: false).check(key: "write_file", level: .ask, preview: "") != nil)
    }

    @Test func toolApprovalScopes() throws {
        let box = try Sandbox()
        #expect(Toolbox.bash.approval(["command": "ls"], box.ctx) == .askScoped("command: ls"))
        #expect(Toolbox.webFetch.approval(["url": "https://example.com/x?k=1"], box.ctx) == .askScoped("host example.com"))
        #expect(isBlocked(Toolbox.readFile.approval(["path": ".env"], box.ctx)))
        #expect(isSensitive(ApplePIM_messagesApproval(box.ctx)))
    }

    private func ApplePIM_messagesApproval(_ ctx: ToolContext) -> Approval {
        AppleTools.all.first { $0.name == "messages" }!.approval(["action": "send", "to": "x", "text": "hi"], ctx)
    }
}

// MARK: - Resource limits (CWE-400/770)

@Suite struct LimitTests {
    @Test func outputBufferIsCapped() {
        let buf = OutputBuffer()
        let chunk = Data(repeating: UInt8(ascii: "y"), count: 1_000_000)
        for _ in 0..<12 { buf.append(chunk) }
        let s = buf.string
        #expect(s.hasPrefix("[output truncated"))
        #expect(s.utf8.count < OutputBuffer.cap + 200)
    }

    @Test func toolResultsAreTruncated() {
        let s = truncate(String(repeating: "x", count: 30_010))
        #expect(s.hasSuffix("[truncated 10 characters]"))
        #expect(truncate("short") == "short")
    }

    @Test func commandsTimeOut() async throws {
        let r = try await runCommand(["sleep", "5"], timeout: 0.3)
        #expect(r.note.contains("timed out"))
        #expect(!r.ok)
    }
}

// MARK: - Secrets never reach the model (OWASP LLM02)

@Suite struct RedactionTests {
    @Test(arguments: [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
        "sk-proj-abcdefghijklmnopqrstuvwxyz0123",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "AKIAIOSFODNN7EXAMPLE",
        "xoxb-1234567890-abcdefghij",
        "AIzaSyA1234567890abcdefghijklmnopqrstuv",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    ])
    func knownTokenFormatsAreMasked(_ token: String) {
        let (out, n) = Redact.secrets("value: \(token) end")
        #expect(!out.contains(token) && n == 1)
        #expect(out == "value: \(Redact.mask) end")
    }

    @Test func privateKeysUrlCredentialsAndAssignmentsAreMasked() {
        let text = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        DATABASE_URL=postgres://admin:S3cretPass1@db.internal/app
        DB_PASSWORD="hunter2secret99"
        Authorization: Bearer abcdef0123456789abcdef
        """
        let (out, n) = Redact.secrets(text)
        for secret in ["b3BlbnNzaC1rZXktdjEAAAAA", "S3cretPass1", "hunter2secret99", "abcdef0123456789abcdef"] {
            #expect(!out.contains(secret))
        }
        #expect(n == 4)
        #expect(out.contains("postgres://admin:[REDACTED]@db.internal/app"))
    }

    @Test func ordinaryCodeIsLeftAlone() {
        let code = """
        let apiKey = config.apiKey
        if let token = env["IAGENT_API_KEY"] { apiKey = token }
        "apiKeyEnv": "ANTHROPIC_API_KEY"
        password_field.isSecure = true
        """
        #expect(Redact.secrets(code) == (code, 0))
    }

    @Test func registeredValuesAreMaskedAnywhere() {
        Redact.registerEnvironment(["MY_SERVICE_TOKEN": "plainwordsecret", "HOME": "/Users/someone-long"])
        #expect(Redact.secrets("it is plainwordsecret!").text == "it is [REDACTED]!")
        #expect(Redact.secrets("/Users/someone-long").count == 0)       // not a credential variable
    }

    @Test func toolResultsAreRedactedBeforeTheModelSeesThem() async throws {
        let box = try Sandbox()
        try box.write("config.txt", "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789\n")
        let (out, isError) = await Toolbox.execute(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"config.txt"}"#),
                                                   tools: Toolbox.all(apple: false), ctx: box.ctx)
        #expect(!isError && !out.contains("ghp_") && out.contains(Redact.mask))
    }

    @Test func secretFilesAreNeverReadForACloudModel() async throws {
        let box = try Sandbox()
        try box.write(".env", "TOKEN=hunter2\n")
        let (out, isError) = await Toolbox.execute(ToolCall(id: "1", name: "read_file", arguments: #"{"path":".env"}"#),
                                                   tools: Toolbox.all(apple: false), ctx: Permissions.yoloCtx(box))
        #expect(isError && out.hasPrefix("Blocked:") && !out.contains("hunter2"))
    }
}

// MARK: - Local-only mode: nothing leaves this Mac

@Suite struct LocalOnlyTests {
    @Test(arguments: ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080"])
    func loopbackServersAreAllowed(_ s: String) { #expect(Transport.isLoopback(URL(string: s)!)) }

    @Test(arguments: ["https://api.anthropic.com", "http://192.168.1.10:11434", "http://10.0.0.2", "http://mac.local",
                      "http://127.0.0.1.evil.example"])
    func everythingElseIsNot(_ s: String) { #expect(!Transport.isLoopback(URL(string: s)!)) }

    @Test func cloudProvidersAreRefused() {
        var c = Config()
        c.localOnly = true
        c.provider = "anthropic"
        c.apiKey = "sk-ant-test"
        #expect(throws: AgentError.self) { try c.makeProvider() }
        c.provider = nil
        c.baseURL = "http://192.168.1.10:11434/v1"
        #expect(throws: AgentError.self) { try c.makeProvider() }
    }

    @Test func networkToolsAreRemovedAndEgressActionsBlocked() async throws {
        let names = Set(Toolbox.all(apple: true, localOnly: true).map(\.name))
        #expect(names.isDisjoint(with: LocalOnly.removedTools))
        #expect(names.isSuperset(of: ["read_file", "bash", "mac", "reminders"]))

        let box = try Sandbox()
        var ctx = Permissions.yoloCtx(box)
        ctx.localOnly = true
        let (out, isError) = await Toolbox.execute(ToolCall(id: "1", name: "mac", arguments: #"{"action":"open","target":"https://example.com"}"#),
                                                   tools: AppleTools.all, ctx: ctx)
        #expect(isError && out.hasPrefix("Blocked:"))
    }

    @Test func sandboxedBashHasNoNetwork() async throws {
        let box = try Sandbox()
        let probe = #"python3 -c 'import socket; socket.create_connection(("1.1.1.1", 80), 3)' 2>&1 | tail -1"#
        let out = try await runShell(probe, cwd: box.root, timeout: 20, sandboxed: true)
        #expect(out.contains("Operation not permitted"))
        let ok = try await runShell("echo works", cwd: box.root, timeout: 20, sandboxed: true)
        #expect(ok == "works\n[exit code 0]")
    }
}

extension Permissions {
    /// A context whose ordinary approvals pass, so tests reach the policy that is under test.
    static func yoloCtx(_ box: Sandbox) -> ToolContext {
        ToolContext(cwd: realPath(box.root), permissions: Permissions(autoApprove: true))
    }
}
