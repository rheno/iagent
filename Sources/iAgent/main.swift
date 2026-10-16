import Foundation

let version = "0.3.2"

// A write to a pipe whose reader exited must fail with EPIPE instead of killing the process.
signal(SIGPIPE, SIG_IGN)

// Internal helper mode: the `airdrop` tool re-launches this binary to host the AppKit sharing UI.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == AirDropHelper.flag {
    AirDropHelper.run(Array(CommandLine.arguments.dropFirst(2)))
}

let usageText = """
iagent \(version) — a terminal coding agent for any LLM, wired into the Apple ecosystem

USAGE
  iagent [options] [prompt]          interactive session (optionally starting with prompt)
  iagent -p "prompt" [options]       one-shot: run the task, print, exit
  echo "prompt" | iagent [options]   one-shot from stdin

OPTIONS
  --provider <name>     anthropic | openai | openrouter | fm | ollama | lmstudio | mlx (default: from API key env
                        vars; with none, or with --local, Apple's on-device model via fm)
  -m, --model <id>      model id, e.g. claude-opus-5-5, gpt-5, qwen3-coder, anthropic/claude-sonnet-5-5
  --base-url <url>      any OpenAI-compatible endpoint (e.g. http://localhost:8000/v1)
  --kind <openai|anthropic>  API dialect for a custom --base-url (default: openai)
  --api-key-env <VAR>   read the API key from this environment variable
  --max-tokens <n>      max output tokens per model call
  --effort <level>      Anthropic effort: low | medium | high | xhigh | max (default: high)
  --no-thinking         don't request adaptive thinking (Anthropic)
  --yolo                auto-approve tool calls (sending messages still always asks)
  --no-apple            disable the Apple ecosystem tools (smaller tool list for small models)
  --local               local-only: nothing leaves this Mac (model on localhost only, network tools off,
                        bash sandboxed without network). Also "localOnly": true or IAGENT_LOCAL_ONLY=1
  --run-tool <name> <json>  run one tool directly without a model (debugging), e.g.
                        --run-tool apple_devices '{}'
  -C, --cwd <dir>       working directory (default: current)
  -h, --help            show this help
  -v, --version         print version

CONFIG
  ~/.iagent/config.json and IAGENT_PROVIDER / _MODEL / _BASE_URL / _API_KEY / _EFFORT / _PROFILE env vars.
  See README.md for examples.
"""

let slashCommands = [
    SlashCommand(name: "/help", args: "", summary: "show this help"),
    SlashCommand(name: "/model", args: "[id]", summary: "show or switch the model"),
    SlashCommand(name: "/clear", args: "", summary: "start a fresh conversation"),
    SlashCommand(name: "/tools", args: "", summary: "list available tools"),
    SlashCommand(name: "/yolo", args: "", summary: "toggle auto-approval of tool calls"),
    SlashCommand(name: "/cost", args: "", summary: "show token usage for this session"),
    SlashCommand(name: "/exit", args: "", summary: "leave (Ctrl-D also works)"),
    SlashCommand(name: "/quit", args: "", summary: "leave"),
]

let slashHelp = slashCommands.map { "  " + ($0.name + " " + $0.args).padding(toLength: 18, withPad: " ", startingAt: 0) + $0.summary }
    .joined(separator: "\n") + """

  Type / to pick a command (↑/↓ to choose, Tab to complete, Enter to run, Esc to close).
  ↑/↓ recall earlier inputs. Ctrl-J, Option-Enter or a trailing \\ starts a new line; pastes keep their newlines.
  Ctrl-A/E line start/end · Option-←/→ by word · Ctrl-U/K/W delete · Ctrl-L clear screen
  Ctrl-C clears the input (twice on an empty prompt exits) and interrupts a running turn.
"""

// MARK: - Argument parsing

var config = Config()
var oneShot: String?
var positional: [String] = []
var cwdPath = FileManager.default.currentDirectoryPath
var flags = Config()   // CLI values, applied last
var cliSet: Set<String> = []
var directTool: (name: String, args: String)?

do {
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) throws -> String {
        guard !args.isEmpty else { throw AgentError("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help": print(usageText); exit(0)
        case "-v", "--version": print(version); exit(0)
        case "-p", "--print": oneShot = try value(a)
        case "--provider": flags.provider = try value(a); cliSet.insert("provider")
        case "-m", "--model": flags.model = try value(a); cliSet.insert("model")
        case "--base-url": flags.baseURL = try value(a); cliSet.insert("baseURL")
        case "--kind":
            let k = try value(a)
            guard let kind = ProviderKind(rawValue: k) else { throw AgentError("--kind must be openai or anthropic") }
            flags.kind = kind; cliSet.insert("kind")
        case "--api-key-env": flags.apiKeyEnv = try value(a); cliSet.insert("apiKeyEnv")
        case "--max-tokens":
            guard let n = Int(try value(a)) else { throw AgentError("--max-tokens needs an integer") }
            flags.maxTokens = n; cliSet.insert("maxTokens")
        case "--effort": flags.effort = try value(a); cliSet.insert("effort")
        case "--no-thinking": flags.thinking = false; cliSet.insert("thinking")
        case "--yolo", "--dangerously-skip-permissions": flags.autoApprove = true
        case "--no-apple": flags.appleTools = false; cliSet.insert("appleTools")
        case "--local": flags.localOnly = true; cliSet.insert("localOnly")
        case "--run-tool": directTool = (try value(a), try value(a))
        case "-C", "--cwd": cwdPath = (try value(a) as NSString).expandingTildeInPath
        default:
            if a.hasPrefix("-") && a.count > 1 { throw AgentError("Unknown option \(a) (see --help)") }
            positional.append(a)
        }
    }

    try config.loadFile()
    config.loadEnv()
    if cliSet.contains("provider") {
        // Switching provider on the CLI shouldn't inherit another provider's URL/model/key settings.
        config.provider = flags.provider
        config.baseURL = nil; config.model = nil; config.apiKey = nil; config.apiKeyEnv = nil; config.kind = nil
    }
    if cliSet.contains("model") { config.model = flags.model }
    if cliSet.contains("baseURL") { config.baseURL = flags.baseURL }
    if cliSet.contains("kind") { config.kind = flags.kind }
    if cliSet.contains("apiKeyEnv") { config.apiKeyEnv = flags.apiKeyEnv; config.apiKey = nil }
    if cliSet.contains("maxTokens") { config.maxTokens = flags.maxTokens }
    if cliSet.contains("effort") { config.effort = flags.effort }
    if cliSet.contains("thinking") { config.thinking = false }
    if cliSet.contains("appleTools") { config.appleTools = false }
    if cliSet.contains("localOnly") { config.localOnly = true }
    config.autoApprove = flags.autoApprove
} catch {
    emitError("error: \(error)")
    exit(2)
}

var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: cwdPath, isDirectory: &isDir), isDir.boolValue else {
    emitError("error: working directory \(cwdPath) does not exist")
    exit(2)
}

let permissions = Permissions(autoApprove: config.autoApprove)
// Resolve symlinks (e.g. /tmp, /var) so paths from the file enumerator share the cwd prefix.
var ctx = ToolContext(cwd: realPath(URL(fileURLWithPath: cwdPath).standardizedFileURL), permissions: permissions)
ctx.localOnly = config.localOnly
let usesAppleFM = config.providerName == "fm"
/// Apple's on-device model chats without tools: `fm serve` can't call them yet (see `Agent.buildChatPrompt`).
let tools = usesAppleFM ? [] : Toolbox.all(apple: config.appleToolsEnabled, localOnly: config.localOnly)
// Credential-looking env values (API keys, tokens) are masked wherever they show up in what the model receives.
Redact.registerEnvironment()

if let direct = directTool {
    // No model is involved, so the tools don't depend on the provider (Apple's `fm` gets none in chat).
    let call = ToolCall(id: "direct", name: direct.name, arguments: direct.args)
    let all = Toolbox.all(apple: config.appleTools ?? true, localOnly: config.localOnly)
    let (output, isError) = await Toolbox.execute(call, tools: all, ctx: ctx)
    print("\n" + Sanitize.terminal(output))
    exit(isError ? 1 : 0)
}

for warning in config.warnings { emitError("warning: \(warning)") }

let provider: LLMProvider
do {
    provider = try config.makeProvider()
} catch {
    emitError("error: \(error)")
    exit(2)
}

if config.managesFMServer {
    do {
        try await AppleFM.ensureServer(at: URL(string: AppleFM.baseURL)!)
    } catch {
        emitError("error: \(error)")
        exit(2)
    }
}

let modelName = usesAppleFM ? "Apple's on-device Foundation Model (Apple Intelligence), served by fm on this Mac"
                            : "\(provider.model), through \(provider.label)"
var projectFiles = Agent.projectFiles(cwd: ctx.cwd)
/// Tokens Apple's model spends on iAgent's prompt and tools before any conversation (0 for other providers).
var fmBaseTokens = 0
if usesAppleFM {
    let base = Agent.buildChatPrompt(cwd: ctx.cwd, model: modelName, instructions: [])
    (projectFiles, fmBaseTokens) = await AppleFM.fitInstructions(projectFiles, system: base, tools: tools)
}
let instructions = Agent.trustedInstructions(projectFiles, cwd: ctx.cwd, trustedProjects: config.trustedProjects)
let agent = Agent(provider: provider, tools: tools, ctx: ctx, instructions: instructions, model: modelName, chat: usesAppleFM)
Interrupter.shared.install()

/// Runs one request in a cancellable task so Ctrl-C interrupts it without killing the session.
func runTurn(_ input: String) async -> Bool {
    if usesAppleFM, let warning = await AppleFM.overflowWarning(input, used: max(agent.contextUsed, fmBaseTokens)) {
        emitError(warning)
        return false
    }
    let task = Task<Bool, Never> {
        do {
            try await agent.run(input)
            return true
        } catch {
            if Task.isCancelled || error is CancellationError { return false }
            emitError("error: \(error)")
            if usesAppleFM && AppleFM.isContextOverflow(error) {
                emitError("This conversation filled Apple's on-device model (about 4,096 tokens). Type /clear to start a fresh one.")
            }
            return false
        }
    }
    Interrupter.shared.track(task)
    let ok = await task.value
    Interrupter.shared.track(nil)
    return ok
}

// MARK: - One-shot mode

if oneShot == nil && isatty(STDIN_FILENO) == 0 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let piped = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = positional.joined(separator: " ")
    oneShot = [prefix, piped].filter { !$0.isEmpty }.joined(separator: "\n\n")
}

if let prompt = oneShot {
    guard !prompt.isEmpty else { emitError("error: empty prompt"); exit(2) }
    exit(await runTurn(prompt) ? 0 : 1)
}

// MARK: - Interactive REPL

var banner = [Style.bold("✻ iAgent \(version)") + Style.dim("  \(provider.label) · \(provider.model)"),
              Style.dim("  cwd: \(ctx.cwd.path)  — /help for commands")]
if config.localOnly {
    banner.append(Style.green("  🔒 local-only: model on this Mac only · network tools off · bash has no network"))
}
if usesAppleFM {
    banner.append(Style.dim("  Apple's on-device model: chat only, no file or command tools (fm serve can't call tools yet)"))
}
if permissions.autoApprove {
    banner.append(Style.yellow("  ⚠  --yolo: tool calls run without asking (secret files, files that run code later and messages still ask)"))
}
Logo.banner(banner)
emit("\n")

let editor = LineEditor.isSupported ? LineEditor(commands: slashCommands) : nil

func readInput() -> String? {
    if let editor { return editor.read() }
    emit(Style.bold(Style.magenta("❯ ")))
    var lines: [String] = []
    while let line = readLine() {
        if line.hasSuffix("\\") {
            lines.append(String(line.dropLast()))
            emit(Style.dim("… "))
            continue
        }
        lines.append(line)
        return lines.joined(separator: "\n")
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

var pending: String? = positional.isEmpty ? nil : positional.joined(separator: " ")
if let pending { editor?.history.add(pending) }

while true {
    if let editor {
        editor.status = usesAppleFM ? "on-device · \(max(agent.contextUsed, fmBaseTokens)) / \(AppleFM.contextSize) tokens" : provider.model
    }
    guard let raw = pending ?? readInput() else { emit("\n"); break }
    pending = nil
    let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { continue }

    if input.hasPrefix("/") {
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "/exit", "/quit":
            exit(0)
        case "/help":
            emit(slashHelp + "\n")
        case "/clear":
            agent.reset()
            emit(Style.dim("  Conversation cleared.\n"))
        case "/model":
            if parts.count > 1 {
                provider.model = parts[1].trimmingCharacters(in: .whitespaces)
                emit(Style.dim("  Model set to \(provider.model)\n"))
            } else {
                emit(Style.dim("  \(provider.label) · \(provider.model)\n"))
            }
        case "/tools":
            for t in agent.tools {
                emit("  " + Style.bold(t.name) + (t.approval([:], ctx) == .none ? "" : Style.yellow((t.schema["properties"] as? [String: Any])?["action"] != nil ? " (asks for changes)" : " (asks)")) + Style.dim(" — \(t.description.prefix(100))") + "\n")
            }
        case "/yolo":
            permissions.autoApprove.toggle()
            emit(Style.dim("  Auto-approve is now \(permissions.autoApprove ? "ON" : "off")\n"))
        case "/cost":
            let u = agent.usage
            emit(Style.dim("  input: \(u.input) tokens (cache read: \(u.cacheRead)) · output: \(u.output) tokens\n"))
        default:
            emit(Style.yellow("  Unknown command \(parts[0]). /help lists commands.\n"))
        }
        continue
    }

    _ = await runTurn(input)
    if usesAppleFM && agent.contextUsed > 0 {
        let line = "  context: \(agent.contextUsed) / \(AppleFM.contextSize) tokens"
        if agent.contextUsed * 4 > AppleFM.contextSize * 3 {
            emit(Style.yellow(line + " — nearly full, /clear starts a fresh conversation") + "\n")
        } else if editor == nil {
            emit(Style.dim(line) + "\n")   // otherwise the status row under the input box shows it
        }
    }
    emit("\n")
}
