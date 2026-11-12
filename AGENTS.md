# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository. iAgent itself loads this file into its
system prompt when run from this directory, so keep it short and accurate.

## What this is

iAgent (`iagent`, v0.3.3) is a terminal coding agent written in Swift, in the style of Claude Code. It talks to
either the Anthropic Messages API or any OpenAI-compatible Chat Completions server, and gives the model:

- **Coding tools:** `read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`, `web_fetch`
- **Apple ecosystem tools:** `apple_devices`, `ios_device`, `simulator`, `airdrop`, `reminders`, `calendar`, `apple_fm`,
  `contacts`, `notes`, `messages`, `shortcuts`, `mac`, `applescript` (disable with `--no-apple`)

Every non-read-only tool call goes through a human approval prompt. Security is a core feature, not an add-on;
read [SECURITY.md](SECURITY.md) before touching anything in the permission, path, process or network code.

User-facing docs live in [README.md](README.md). This file covers how the code is put together.

## Hard constraints

- **No third-party dependencies.** Apple frameworks only (Foundation, EventKit, Contacts, AppKit, Network…).
  `Package.swift` has no `dependencies:` and should stay that way (supply-chain control in SECURITY.md).
- **macOS 14+, Swift 5.9+** (`swift-tools-version:5.9`). Single executable target `iAgent` → product `iagent`.
- **No shell except in the `bash` tool.** Run external programs with an explicit argv via `runCommand` /
  `runChecked` (`Process.swift`). Pass AppleScript/JXA values as arguments to `runOSAScript`, never splice them
  into script source. Run user/model-supplied values that could look like options through `operand(_:_:)`
  (`Security.swift`), which rejects a leading `-`.
- **Sanitize everything printed to the terminal** that came from the model, a tool, a file, the network or a
  server error: `Sanitize.terminal(...)`. Use `Sanitize.displayArgs` for argument previews.
- **Never weaken these without an explicit request:** `.sensitive` approvals (secret files, shell-startup/
  LaunchAgent writes, `messages`), API-key scrubbing from child envs (`SecretEnv`), HTTPS-only remote transport
  (`Transport.isLocal`), no redirects on model API calls (`NoRedirects`), same-host redirects for `web_fetch`,
  secret masking of everything sent to the model (`Redact`, applied in `Agent.run`, the system prompt and
  `Toolbox.execute`), `.blocked` secret-file reads for cloud models, local-only mode (`LocalOnly`: loopback model
  server, removed/blocked egress tools, sandboxed `bash`),
  size/time limits (`maxReadBytes`, `maxFetchBytes`, `OutputBuffer.cap`, `truncate` at 30k chars, 60 iterations).
- **Nothing persisted to disk** by the agent (ephemeral URLSessions, no transcripts, prompt history in memory only).
  Temp files are deleted.
- **Hardened runtime, minimal entitlements.** Adding a new protected resource means updating `iAgent.entitlements`
  *and* adding a usage string to `Info.plist` (embedded into the binary via `-sectcreate` in `Package.swift`).

## Layout

```
Package.swift              SwiftPM manifest; embeds Info.plist into __TEXT,__info_plist
Info.plist                 bundle id dev.iagent.cli, version, TCC privacy usage strings, Bonjour types
iAgent.entitlements        Apple Events, Calendars/Reminders, Contacts — nothing else
scripts/build-release.sh   release build + hardened-runtime codesign → dist/iagent (SIGN_IDENTITY for Developer ID)
assets/                    logos, app icon, README screenshot
LICENSE, NOTICE            Apache License 2.0 and attribution notice
Sources/iAgent/
  main.swift               top-level script: flag parsing, config merge, --run-tool, one-shot mode, REPL + slash cmds (add new ones to `slashCommands` so /help and the menu list them)
  LineEditor.swift         raw-mode prompt: LineBuffer editing, in-memory InputHistory, SlashCompletion menu, PromptLayout,
                           framed input box with hint/status row, numbered permission menu (`choose`)
  Render.swift             Claude Code–style output: Spinner (Apple Intelligence colors), MarkdownStream (⏺ replies),
                           ToolDisplay (Read(…)/Update(…) names, "Read 42 lines" results); plain text when piped
  AppleFM.swift            Apple on-device model: starts/stops `fm serve` on 127.0.0.1:8642 (license/availability checks),
                           fits instructions/messages into its 4,096 tokens (`fm count-tokens`), apple_fm tool (`fm respond`)
  Config.swift             provider presets, ~/.iagent/config.json (with profiles) → IAGENT_* env → CLI flags; Keychain key
  Models.swift             ChatMessage/AssistantTurn/ToolCall/Usage, LLMProvider protocol, HTTP sessions, SSE + retry
  Agent.swift              agent loop (model → tools → model …), system prompt builder, StreamRenderer
  AnthropicProvider.swift  Messages API streaming, adaptive thinking, effort, prompt caching, tool_use/tool_result
  OpenAIProvider.swift     Chat Completions streaming + tool calls
  Tools.swift              Tool/Approval/Permissions/ToolContext types, Toolbox registry + execute(), coding tools
  Security.swift           Sanitize, PathPolicy (inside/outside/sensitive), operand(), SecretEnv, Redact, LocalOnly, Transport, redirect delegates
  Process.swift            argv process runner with timeout + output cap, runShell (bash tool only), runOSAScript, ToolAvailability
  Support.swift            ANSI Style, emit/emitError, JSON helpers, AgentError, truncate, Ctrl-C Interrupter
  AppleDevices.swift       AppleTools.all, apple_devices, ios_device (devicectl/libimobiledevice), simulator, airdrop, Bonjour, AirDropHelper
  ApplePIM.swift           reminders, calendar (EventKit), contacts, notes (JXA), messages (AppleScript), DateInput
  AppleMac.swift           shortcuts, mac (notify/say/clipboard/open/screenshot/…), applescript
```

## How it works

1. `main.swift` parses flags, then merges config: `Config.loadFile()` → `loadEnv()` → CLI flags (`cliSet`).
   Passing `--provider` on the CLI resets base URL/model/key from lower layers.
2. `Config.providerName` picks the preset: API key env vars, else `fm` if installed (and no other `-m`), else Ollama;
   `--local` skips the keys. `main.swift` starts `fm serve` via `AppleFM.ensureServer` when `managesFMServer`, and
   with `fm` there are no tools and `Agent.buildChatPrompt` replaces the agent prompt (`fm serve` can't call tools). `Config.makeProvider()` resolves preset/kind/base URL, enforces the HTTPS rule, finds the key
   (`apiKey` → Keychain → env var), and builds `AnthropicProvider` or `OpenAICompatibleProvider`.
3. `Agent.run(_:)` appends the user message, calls `provider.complete(...)` with streaming callbacks, appends the
   `AssistantTurn`, executes every tool call via `Toolbox.execute`, appends `.toolResult`s, and loops until the
   model stops calling tools (max 60 iterations). History is append-only; Anthropic `rawBlocks` (thinking +
   signatures) are echoed back unchanged. Truncated (`max_tokens`/`length`) turns get error results instead of
   running their tool calls.
4. `Toolbox.execute` parses JSON args, prints a summary, asks `Permissions.check` using the tool's `approval`
   closure, runs the tool, prints a 3-line preview, and returns output truncated to 30k chars.
5. The system prompt (`Agent.buildSystemPrompt`) includes environment info, an Apple section when Apple tools are
   on, and the contents of `AGENTS.md`, `CLAUDE.md` and `.iagent.md` from the working directory. `main.swift` passes
   only the files the user trusted (`Agent.trustedInstructions`: a startup question, or `trustedProjects` in the config).

## Adding or changing a tool

A tool is one `Tool(...)` value: `name`, `description`, JSON `schema`, `approval` closure, `summary`, optional
`preview`, and an async `run`. Register it in `Toolbox.all` (coding) or `AppleTools.all` (Apple). It then works with
both providers automatically.

- Multi-action tools take an `"action"` argument; use `AppleTools.actionSchema`. The "always allow" key becomes
  `tool.action`, so approvals are per action.
- A new tool that can send data off the Mac (network, other devices, iCloud sync, other apps) must be added to
  `LocalOnly.removedTools`, or its egress actions to `LocalOnly.blockedActions`.
- Pick the approval level deliberately: `.none` only for read-only, in-project, non-personal reads; `.ask` for
  changes; `.askScoped(scope)` when "always" must be limited (one host, one exact command, one path);
  `.sensitive(reason)` for anything that must be confirmed every time. For paths, use
  `PathPolicy.readApproval` / `writeApproval` instead of rolling your own.
- Use `str` / `int` / `bool` helpers for arguments and throw `AgentError` with a message the model can act on.
- Tool output is untrusted data: never print it unsanitized.

## Build, run, verify

```bash
swift build                              # debug build → .build/debug/iagent
swift build -c release                   # release build
scripts/build-release.sh                 # release + hardened-runtime ad-hoc signature → dist/iagent, then verifies codesign
.build/debug/iagent --help
.build/debug/iagent --run-tool mac '{"action":"battery"}'    # exercise a tool without any model or API key
.build/debug/iagent --run-tool glob '{"pattern":"**/*.swift"}'
```

Run the tests with `swift test < /dev/null`. Redirecting stdin makes the session non-interactive, which enables the
tests that check approvals are refused without a terminal. They use Swift Testing (`import Testing`, part of the
toolchain, so this is not a dependency) and `@testable import iAgent`:

- `Tests/iAgentTests/SecurityTests.swift`: one regression test per control in SECURITY.md (sanitizer, path
  policy and symlinked secrets, operand/osascript/argv injection, API-key scrubbing, HTTPS rule, redirect
  delegates, approval levels, output/time limits). A security change must keep these green and add a test.
- `Tests/iAgentTests/ToolTests.swift`: coding-tool behavior, run in a temp `Sandbox` directory.
- `Tests/iAgentTests/AppleFMTests.swift`: context fitting (counting injected, no model needed), `fm` schema
  conversion, apple_fm approvals.
- `Tests/iAgentTests/RenderTests.swift`: markdown rendering and wrapping, tool result lines, spinner text.
- `Tests/iAgentTests/LineEditorTests.swift`: prompt editing, history, `/` completion and wrapping (pure logic;
  the raw-terminal I/O is checked by hand in a real terminal).

Tests don't cover the providers' HTTP streaming or the Apple tools (TCC prompts, Xcode, real devices). Exercise
those by hand with `--run-tool`.

## Conventions

- Match the existing style: compact Swift, `enum` namespaces for static helpers, short doc comments (`///`)
  explaining *why*, CWE/OWASP references next to security controls.
- Print via `emit` / `emitError` and `Style.*` (respects `NO_COLOR` and non-TTY output), not `print`, except in
  `main.swift`'s simple exit paths.
- Keep README.md (user-facing), SECURITY.md (controls + verification) and this file in sync when behavior,
  flags, config keys, tools or limits change. Bump `version` in `main.swift` and `CFBundleShortVersionString` in
  `Info.plist` together.
- Paths: the cwd and `glob`/`grep` roots go through `realPath()` (realpath(3)), because the file enumerator returns
  resolved paths (`/var` → `/private/var`). `URL.resolvingSymlinksInPath()` strips `/private`, so don't use it for
  prefix comparisons.
- `.build/`, `.swiftpm/`, `dist/` and `.DS_Store` are gitignored build output; don't edit or commit them.
