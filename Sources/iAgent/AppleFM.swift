import Foundation

/// Apple's on-device Foundation Model through `fm serve` (Chat Completions on loopback). Nothing leaves this Mac,
/// no download, no API key. iAgent starts the server itself when nothing answers on the preset port, and stops it
/// when iAgent exits.
enum AppleFM {
    static let binary = "/usr/bin/fm"
    static let port = 8642
    static let baseURL = "http://127.0.0.1:\(port)/v1"
    /// The only model `fm serve` offers.
    static let model = "system"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    /// The model's whole context: prompt, tools, conversation and answer (`SystemLanguageModel.default.contextSize`).
    static let contextSize = 4_096
    /// Tokens kept free for the conversation and the answer when deciding which project instructions to load.
    static let conversationReserve = 1_024
    /// Tokens kept free for the answer when checking that a new message fits.
    static let answerReserve = 256

    /// Counts tokens with `fm count-tokens`, or nil when that fails. `--opt=value` keeps a value starting with `-`
    /// from being read as an option.
    static func countTokens(instructions: String = "", texts: [String] = []) async -> Int? {
        var argv = [binary, "count-tokens", "--quiet"]
        if !instructions.isEmpty { argv.append("--instructions=\(instructions)") }
        argv += texts.map { "--text=\($0)" }
        guard let r = try? await runCommand(argv, timeout: 30), r.ok else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The tool list as `fm serve` receives it, for counting.
    static func toolsJSON(_ tools: [Tool]) -> String {
        JSON.string(tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] })
    }

    /// Measures iAgent's system prompt and tools, then keeps the project instruction files that fit in what is left
    /// after `conversationReserve`, in order. A warning names the ones left out: without this, a long AGENTS.md makes
    /// every request fail with "exceeded the model's context size". Where counting fails, about 3 characters make a
    /// token. Returns the kept files and the tokens the prompt and tools take.
    static func fitInstructions(_ files: [Agent.ProjectFile], system: String, tools: [Tool],
                                count: (String, [String]) async -> Int? = { await countTokens(instructions: $0, texts: $1) })
        async -> (files: [Agent.ProjectFile], base: Int) {
        let toolList = toolsJSON(tools)
        let base = await count(system, [toolList]) ?? (system.count + toolList.count) / 3
        let budget = contextSize - base - conversationReserve
        var used = 0
        var kept: [Agent.ProjectFile] = []
        var skipped: [String] = []
        for file in files {
            let block = Agent.instructionBlock(file)
            // Something this long can't fit; don't spend a count on it.
            let tokens = block.count > contextSize * 8 ? block.count / 3 : await count("", [block]) ?? block.count / 3
            if used + tokens <= budget {
                kept.append(file)
                used += tokens
            } else {
                skipped.append("\(file.name) (~\(tokens) tokens)")
            }
        }
        if !skipped.isEmpty {
            emitError("warning: not loading \(skipped.joined(separator: ", ")): Apple's on-device model holds \(contextSize) tokens, iAgent's prompt and tools take ~\(base), and \(conversationReserve) stay free for the conversation, leaving \(max(budget - used, 0)). Put a short version in .iagent.md, or use a larger model.")
        }
        return (kept, base)
    }

    /// Why `message` won't fit after `used` tokens of context, or nil when it fits.
    static func overflowWarning(_ message: String, used: Int, count: (String) async -> Int? = { await countTokens(texts: [$0]) }) async -> String? {
        let tokens = await count(message) ?? message.count / 3
        guard used + tokens + answerReserve > contextSize else { return nil }
        return "This message (~\(tokens) tokens) won't fit: \(used) of Apple's on-device model's \(contextSize) tokens are in use, and ~\(answerReserve) are needed for the answer. Type /clear to start a fresh conversation, or shorten the message."
    }

    /// Whether `error` is the model running out of context, which `fm serve` reports as a plain server error.
    static func isContextOverflow(_ error: Error) -> Bool {
        "\(error)".contains("exceeded the model's context size")
    }

    nonisolated(unsafe) private static var server: Process?

    /// Makes sure an `fm serve` answers at `url`, starting one bound to 127.0.0.1 if needed.
    static func ensureServer(at url: URL) async throws {
        if await isUp(url) {
            // Any local user can listen on a loopback port; a server another account started would receive every
            // prompt. Without root, lsof only lists this user's processes, so an answering port it can't find isn't ours.
            let p = String(url.port ?? port)
            let mine = try? await runCommand(["lsof", "-nP", "-a", "-u", String(getuid()), "-iTCP:\(p)", "-sTCP:LISTEN", "-t"], timeout: 15)
            guard let mine, !mine.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError("Something not started by your account is listening on 127.0.0.1:\(p), so iAgent won't send it your prompts. Stop it, or pick another server with --base-url.")
            }
            return
        }
        guard isInstalled else {
            throw AgentError("Apple Foundation Models need \(binary) (macOS 27 with Apple Intelligence). Use another provider, e.g. --provider ollama.")
        }
        let license = try await runCommand([binary, "license", "--status"], timeout: 15)
        guard license.ok else {
            throw AgentError("The Apple Foundation Models CLI terms haven't been agreed to yet. Run once: sudo fm license")
        }
        let available = try await runCommand([binary, "available"], timeout: 15)
        guard available.ok else {
            let reason = Sanitize.terminal(available.combined)
            let hint = reason.contains("modelNotReady")
                ? " The model is still downloading or being set up: check System Settings → Apple Intelligence & Siri, stay on Wi-Fi and power, then retry when `fm available` succeeds."
                : ""
            throw AgentError("Apple's on-device model is not available: \(reason).\(hint)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["serve", "--host", "127.0.0.1", "--port", String(url.port ?? port)]
        p.environment = SecretEnv.childEnvironment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        let err = OutputBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { err.finished = true } else { err.append(d) }
        }
        p.standardError = errPipe
        do { try p.run() } catch { throw AgentError("Could not start fm serve: \(error.localizedDescription)") }
        server = p
        atexit { AppleFM.stop() }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning {
                throw AgentError("fm serve exited (status \(p.terminationStatus)): \(Sanitize.terminal(err.string.trimmingCharacters(in: .whitespacesAndNewlines)))")
            }
            if await isUp(url) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw AgentError("fm serve did not start listening on \(url.host ?? "127.0.0.1"):\(url.port ?? port) within 20 s")
    }

    static func stop() {
        guard let p = server, p.isRunning else { return }
        p.terminate()
        p.waitUntilExit()
        server = nil
    }

    private static func isUp(_ url: URL) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("models"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await HTTP.session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - apple_fm tool

extension AppleFM {
    /// Lets the main model hand a text task to Apple's on-device model. What it reads is processed on this Mac; only
    /// the answer goes back to the main model, so secret files follow read_file's rules.
    static let tool = Tool(
        name: "apple_fm",
        description: "Run a text task on Apple's on-device Foundation Model on this Mac: summarize, classify, extract, rewrite, tag. A file's contents are processed on this Mac and only the answer comes back to you. It is a small model with weaker reasoning than yours and a \(contextSize)-token context shared by instructions, prompt, file and answer (about 10,000 characters of input). Give `schema` (a JSON Schema for an object) to get JSON matching it.",
        schema: schema([
            "prompt": ["type": "string", "description": "The task or question"],
            "instructions": ["type": "string", "description": "Optional instructions for the model, e.g. a role or output rules"],
            "path": ["type": "string", "description": "Optional text file to include, absolute or relative to the working directory"],
            "schema": ["type": "object", "description": "Optional JSON Schema of an object; the answer is JSON matching it"],
        ], required: ["prompt"]),
        approval: { args, ctx in args["path"] == nil ? .none : PathPolicy.readApproval(args["path"] as? String, ctx) },
        summary: { args in
            [args["path"] as? String, (args["prompt"] as? String).map { String($0.prefix(60)) }].compactMap { $0 }.joined(separator: " · ")
        },
        run: { args, ctx in try await respond(args, ctx) })

    /// About 3 bytes make a token in English text and code, so a larger file can't fit with a prompt and an answer.
    static let maxFileBytes = 12_000

    static func respond(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        guard isInstalled else { throw AgentError("Apple's on-device model needs \(binary) (macOS 27 with Apple Intelligence)") }
        // `--opt=value` and `--` keep values starting with `-` from being read as options.
        var argv = [binary, "respond", "--no-stream"]
        if let instructions = args["instructions"] as? String, !instructions.isEmpty {
            argv.append("--instructions=\(instructions)")
        }
        if let path = args["path"] as? String {
            let url = ctx.resolve(path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maxFileBytes else {
                throw AgentError("\(ctx.display(url)) is \(size) bytes; Apple's on-device model holds \(contextSize) tokens, which fits about \(maxFileBytes) bytes of text. Pass part of it in prompt, e.g. from read_file with offset/limit.")
            }
            let data = try Data(contentsOf: url)
            if data.prefix(8000).contains(0) { throw AgentError("\(ctx.display(url)) looks like a binary file") }
            argv.append("--text=\(String(decoding: data, as: UTF8.self))")
        }
        var schemaFile: URL?
        defer { if let schemaFile { try? FileManager.default.removeItem(at: schemaFile) } }
        if let raw = args["schema"] {
            guard let object = raw as? [String: Any] ?? (raw as? String).flatMap(JSON.object) else {
                throw AgentError("schema must be a JSON Schema object")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("iagent-fm-schema-\(UUID().uuidString).json")
            try JSON.data(fmSchema(object)).write(to: url)
            schemaFile = url
            argv.append("--schema=\(url.path)")
        }
        argv += ["--", try str(args, "prompt")]

        let r = try await runCommand(argv, timeout: 180)
        let answer = stripANSI(r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !answer.hasPrefix("Error:") else {
            var failure = stripANSI(r.combined).trimmingCharacters(in: .whitespacesAndNewlines)
            if failure.hasPrefix("Error: ") { failure.removeFirst(7) }
            if failure.isEmpty { failure = "fm exited with status \(r.status)" }
            let hint = failure.contains("context size") ? " Pass less text: the model holds \(contextSize) tokens." : ""
            throw AgentError("Apple's on-device model failed: \(failure)\(r.note.isEmpty ? "" : " \(r.note)")\(hint)")
        }
        return answer.isEmpty ? "(empty answer)" : answer
    }

    /// `fm` reads a schema only when every object has `title`, `x-order` and `"additionalProperties": false`. The
    /// main model writes plain JSON Schema, so they are added here, keeping required properties first.
    static func fmSchema(_ node: [String: Any], title: String = "Result") -> [String: Any] {
        var n = node
        if let props = n["properties"] as? [String: Any] {
            let required = (n["required"] as? [String] ?? []).filter { props[$0] != nil }
            n["x-order"] = n["x-order"] as? [String] ?? required + props.keys.sorted().filter { !required.contains($0) }
            n["properties"] = Dictionary(uniqueKeysWithValues: props.map { key, value in
                (key, (value as? [String: Any]).map { fmSchema($0, title: title + key.prefix(1).uppercased() + key.dropFirst()) } ?? value)
            })
            n["type"] = "object"
            n["additionalProperties"] = false
            if n["title"] == nil { n["title"] = title }
        }
        if let items = n["items"] as? [String: Any] { n["items"] = fmSchema(items, title: title + "Item") }
        if let choices = n["anyOf"] as? [[String: Any]] {
            n["anyOf"] = choices.enumerated().map { fmSchema($1, title: "\(title)\($0 + 1)") }
        }
        return n
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
