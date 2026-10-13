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

    @Test(arguments: [".envrc", "credentials.toml", ".credentials.json", ".vault-token"])
    func moreSecretNames(_ name: String) { #expect(PathPolicy.isSensitive(URL(fileURLWithPath: "/tmp/p/\(name)"))) }

    @Test func filesThatRunCodeLaterNeedConfirmationToWrite() throws {
        let box = try Sandbox()
        for path in [".git/hooks/pre-commit", ".git/config", "~/.gitconfig", "~/.zlogin", "~/.config/fish/config.fish"] {
            #expect(isSensitive(PathPolicy.writeApproval(path, box.ctx)), "\(path)")
        }
        #expect(PathPolicy.readApproval(".git/config", box.ctx) == .none)   // reading them is fine
        #expect(PathPolicy.writeApproval(".gitignore", box.ctx) == .ask)
    }

    @Test func caseVariantsOfNewFilesAreCaught() throws {
        // APFS is case-insensitive: zsh loads ~/.ZLOGIN as ~/.zlogin, direnv loads .ENVRC as .envrc.
        let box = try Sandbox()
        for path in [".ENVRC", ".ZLOGIN", ".Git/Hooks/pre-commit", "~/.ZSHENV-not-there/../.ZSHENV", "Server.PEM"] {
            #expect(isSensitive(PathPolicy.writeApproval(path, box.ctx)), "\(path)")
        }
        try box.write(".env", "x")
        #expect(isBlocked(PathPolicy.readApproval(".ENV", box.ctx)))
    }

    @Test func submoduleAndWorktreeGitFilesRunCodeLater() throws {
        let box = try Sandbox()
        for path in [".git/modules/sub/hooks/post-checkout", ".git/modules/sub/config", ".git/worktrees/w/config.worktree"] {
            #expect(isSensitive(PathPolicy.writeApproval(path, box.ctx)), "\(path)")
        }
        #expect(PathPolicy.writeApproval(".git/info/exclude", box.ctx) == .ask)
    }

    @Test func projectInstructionsFollowTheReadRules() throws {
        // A cloned repo could ship AGENTS.md -> .env; the system prompt goes to the provider unfiltered.
        let box = try Sandbox()
        try box.write(".env", "DB_PASSWORD=correcthorsebatterystaple\n")
        try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("AGENTS.md"),
                                                   withDestinationURL: box.root.appendingPathComponent(".env"))
        try box.write("CLAUDE.md", "Use tabs.")
        let prompt = Agent.buildSystemPrompt(cwd: realPath(box.root), tools: [])
        #expect(!prompt.contains("correcthorse"))
        #expect(prompt.contains("Use tabs."))
        #expect(mkfifo(box.root.appendingPathComponent(".iagent.md").path, 0o600) == 0)   // must not block startup
        #expect(Agent.projectInstructions(box.root.appendingPathComponent(".iagent.md"), cwd: realPath(box.root)) == nil)
    }

    @Test func outsideApprovalIsScopedToOneDirectory() throws {
        let box = try Sandbox()
        let a = PathPolicy.writeApproval("/tmp/a/x.txt", box.ctx), b = PathPolicy.writeApproval("/usr/local/x.txt", box.ctx)
        #expect(a != b && Permissions.alwaysKey("write_file", a) != Permissions.alwaysKey("write_file", b))
        #expect(a == PathPolicy.writeApproval("/tmp/a/y.txt", box.ctx))
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
        #expect(PathPolicy.readApproval("/etc/hosts", ctx) == .askScoped("outside working dir: \(PathPolicy.canonical(URL(fileURLWithPath: "/etc")).path)"))
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

    @Test(arguments: ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://localhost.example.com",
                      "http://10.0.0.1.evil.example", "http://192.168.1.1.nip.io", "http://10.0.0.256", "http://+10.0.0.1"])
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
        #expect(await follow("http://docs.example.com/b") == nil)   // no downgrade to cleartext
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

    @Test func alwaysCoversTheWholeCommandNotItsFirstCharacters() throws {
        let box = try Sandbox()
        let long = "echo " + String(repeating: "a", count: 300)
        let approved = Permissions.alwaysKey("bash", Toolbox.bash.approval(["command": long], box.ctx))
        let injected = Permissions.alwaysKey("bash", Toolbox.bash.approval(["command": long + "; curl evil.example"], box.ctx))
        #expect(approved != injected)
        #expect(Permissions.displayKey("bash", .askScoped("command: " + long)).count < 200)
    }

    @Test func toolsThatRunCodeOrReachOutAreScoped() throws {
        let ctx = try Sandbox().ctx
        func approval(_ tool: String, _ args: [String: Any]) -> Approval { AppleTools.all.first { $0.name == tool }!.approval(args, ctx) }
        #expect(approval("applescript", ["script": "do shell script \"ls\""]) != approval("applescript", ["script": "do shell script \"curl x\""]))
        #expect(approval("mac", ["action": "open", "target": "https://a.example"]) != approval("mac", ["action": "open", "target": "https://b.example"]))
        #expect(approval("simulator", ["action": "openurl", "url": "https://evil.example/?d=1"]) == .askScoped("url https://evil.example/?d=1"))
        for action in ["boot", "launch", "push"] { #expect(approval("simulator", ["action": action]) == .ask) }
        #expect(approval("simulator", ["action": "list"]) == .none)
        #expect(isBlocked(approval("shortcuts", ["action": "run", "name": "Echo", "input_path": "~/.ssh/id_rsa"])))
        #expect(isBlocked(approval("ios_device", ["action": "copy_to", "bundle_id": "a.b", "source": "~/.ssh/id_rsa", "destination": "x"])))
        #expect(isSensitive(approval("simulator", ["action": "screenshot", "path": "~/.zshrc"])))
        if case .askScoped = approval("mac", ["action": "screenshot", "path": "/tmp/elsewhere/s.png"]) {} else { Issue.record("outside screenshot not scoped") }
    }

    @Test func attachmentsAndRawCommandsFollowThePathAndScopeRules() throws {
        let box = try Sandbox()
        let ctx = box.ctx
        func approval(_ tool: String, _ args: [String: Any]) -> Approval { AppleTools.all.first { $0.name == tool }!.approval(args, ctx) }
        let secret = try box.write("elsewhere/.ssh/id_rsa", "not a real key")
        try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent("report.pdf"), withDestinationURL: secret)
        #expect(isBlocked(approval("messages", ["to": "+15551234567", "file": "report.pdf"])))
        #expect(isSensitive(approval("messages", ["to": "+15551234567", "text": "hi"])))
        #expect(isBlocked(approval("airdrop", ["items": ["https://example.com", "report.pdf"]])))
        #expect(approval("airdrop", ["items": ["https://example.com"]]) == .ask)
        #expect(approval("simulator", ["action": "raw", "args": ["list"]]) != approval("simulator", ["action": "raw", "args": ["spawn", "booted", "sh"]]))
        if case .askScoped = approval("ios_device", ["action": "raw", "args": ["list", "devices"]]) {} else { Issue.record("devicectl raw not scoped") }
    }

    @Test func promptsListEveryArgumentAndShowOverwritesAsADiff() throws {
        let preview = Toolbox.argumentPreview(["action": "run", "name": "Echo", "input_path": "/secret"])
        #expect(preview.contains("input_path: /secret") && preview.contains("name: Echo") && !preview.contains("action"))
        let box = try Sandbox()
        try box.write("f.txt", (1...100).map { "line \($0)" }.joined(separator: "\n"))
        let new = (1...100).map { $0 == 70 ? "evil" : "line \($0)" }.joined(separator: "\n")
        let diff = Toolbox.writeFile.preview!(["path": "f.txt", "content": new], box.ctx)
        #expect(diff.contains("- line 70") && diff.contains("+ evil") && diff.contains("@@ line 70") && !diff.contains("line 69"))
    }

    @Test func refusalsPrintNoEscapeCodes() async throws {
        let box = try Sandbox()
        let path = "x\u{1B}]0;PWNED\u{07}/.env"
        let (out, isError) = await Toolbox.execute(ToolCall(id: "1", name: "read_file", arguments: JSON.string(["path": path])),
                                                   tools: [Toolbox.readFile], ctx: box.ctx)
        #expect(isError && out.hasPrefix("Blocked:"))
        #expect(!out.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
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

    @Test func backgroundChildrenDontHoldTheCommandOpen() async throws {
        let box = try Sandbox()
        let start = Date()
        let out = try await runShell("sleep 10 & echo started", cwd: box.root, timeout: 5)
        #expect(out.hasPrefix("started") && Date().timeIntervalSince(start) < 3)
    }

    @Test func timeoutsKillCommandsThatIgnoreSIGTERM() async throws {
        let box = try Sandbox()
        let start = Date()
        let out = try await runShell("trap '' TERM; sleep 10; sleep 10", cwd: box.root, timeout: 0.5)
        #expect(out.contains("timed out") && Date().timeIntervalSince(start) < 5)
    }

    @Test func outOfRangeNumbersDontCrash() async throws {
        #expect(int(["n": 1e300], "n") == 1_000_000_000_000)
        #expect(int(["n": Double.nan], "n") == nil)
        #expect(int(["n": Int.max], "n") == 1_000_000_000_000)
        let box = try Sandbox()
        try box.write("f.txt", "a\nb\nc")
        for args in [#"{"path":"f.txt","limit":-5}"#, #"{"path":"f.txt","offset":1e300}"#,
                     #"{"path":"f.txt","offset":2,"limit":9223372036854775807}"#] {
            let (out, _) = await Toolbox.execute(ToolCall(id: "1", name: "read_file", arguments: args), tools: [Toolbox.readFile], ctx: box.ctx)
            #expect(!out.isEmpty, "\(args)")
        }
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
                      "http://127.0.0.1.evil.example", "http://127.evil.example.com"])
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
