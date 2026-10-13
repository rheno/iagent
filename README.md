<p align="center">
  <img src="assets/logo.png" width="160" alt="iAgent logo">
</p>

<h1 align="center">iAgent</h1>

A Claude-Code-style terminal agent written in Swift, with no third-party dependencies. It is wired into the Apple ecosystem: Mac, iPhone, iPad, Watch, Apple TV, AirPods, iCloud data. You can point it at any model:

- **Any OpenAI-compatible server**: OpenAI, OpenRouter, Ollama, LM Studio, vLLM, LiteLLM, Groq, DeepSeek, Together, …
- **Anthropic API** (native Messages API with streaming, adaptive thinking, and prompt caching)
- **Apple's on-device model** through the built-in `fm` command (macOS 27 with Apple Intelligence): no download, no key, nothing leaves the Mac

The coding tools are `read_file`, `write_file`, `edit_file`, `glob`, `grep`, `bash`, and `web_fetch`. Before it runs a command, changes a file, contacts a new web host, or touches anything outside the project, you're asked to approve the call (`y` / `a`lways / `n` / type feedback). Secret files and outgoing messages need confirmation every time, even with `--yolo`. See [SECURITY.md](SECURITY.md) for the full security model.

<p align="center">
  <img src="assets/screenshot-session.png" width="820" alt="iAgent session: bumping a version with an approved edit, refusing to read .env, and asking before adding a reminder">
</p>

## Apple ecosystem

On top of the coding tools, the agent gets tools for your whole Apple setup. Just ask in plain language, for example: *"what Apple devices do I have nearby?"*, *"remind me on my phone in 20 minutes to call Dina"*, *"what's on my calendar tomorrow?"*, *"AirDrop report.pdf to my iPhone"*, *"install build/App.ipa on my iPad"*, *"turn off the living room lights"* (via a Shortcut).

| Tool | What it reaches | How |
|---|---|---|
| `apple_devices` | This Mac, USB/Wi-Fi-paired iPhone/iPad/Watch/TV, simulators, Bluetooth accessories (AirPods, keyboards, with battery levels), Apple devices on the LAN (iPhone, iPad, Mac, Apple TV, HomePod) | `system_profiler`, devicectl / libimobiledevice, Bonjour |
| `ios_device` | Physical iPhone / iPad / Watch / Apple TV: info, battery, apps, processes, install/uninstall/launch, copy files in and out of app containers, screenshot, syslog | `xcrun devicectl` (Xcode), falls back to `libimobiledevice` |
| `simulator` | iOS/iPadOS/watchOS/tvOS/visionOS simulators: boot, install, launch, open URL, screenshot, push notification, appearance, location | `xcrun simctl` (Xcode) |
| `airdrop` | Send files/URLs to a nearby iPhone, iPad or Mac (you pick the recipient in the AirDrop sheet) | `NSSharingService` |
| `reminders` | Lists, list, add (a due time also alerts on iPhone/Watch), complete, delete | EventKit, iCloud sync |
| `calendar` | Calendars, events in a range, add (with alert), delete | EventKit, iCloud/Google/Exchange |
| `contacts` | Search by name, email or phone | Contacts framework |
| `notes` | Folders, recent, search, read, create, append | Notes.app via JXA |
| `messages` | Send an iMessage/SMS (with an optional attachment) | Messages.app via AppleScript |
| `shortcuts` | List and run your Shortcuts, which also covers HomeKit/Home, Focus modes and app actions | `shortcuts` CLI |
| `mac` | Notification, say, clipboard (Universal Clipboard puts it on your iPhone/iPad), open URL/app/file, screenshot, volume, dark mode, battery, Wi-Fi, running apps, now playing, display sleep | built-in commands |
| `applescript` | Any scriptable Mac app (Music, Safari, Mail, Finder, Photos, Keynote, …) | `osascript` |
| `apple_fm` | Hand a text task (summarize, classify, extract, rewrite) to Apple's on-device model, optionally with a file and a JSON Schema for structured output. The file is processed on your Mac; only the answer goes back to the main model | `fm respond` (macOS 27) |

**Setup for iPhone/iPad over USB/Wi-Fi.** Install Xcode for `devicectl`/`simctl`, or run `brew install libimobiledevice` for the USB-only basics. Then connect the device, unlock it, and tap **Trust**.

**Privacy prompts.** macOS asks once per capability: Reminders, Calendars, Contacts, Automation (Notes/Messages/System Events), Screen Recording (screenshots), and Local Network (Bonjour scan). Approvals are stored for your terminal app under System Settings → Privacy & Security. The binary embeds an `Info.plist` with usage descriptions, so these prompts work.

**Approvals.**
- Read-only actions (device scans, listing reminders/events, battery, …) run without asking.
- Personal data reads (contacts, notes, clipboard) and any change ask first. `--yolo` or answering `a` skips the prompt.
- `messages` always asks before each message, even with `--yolo`, and can't be used in non-interactive runs. The same goes for writing shell-startup files.
- Secret files (`.env`, SSH/cloud keys) are never read for a cloud model. With `--local` they can be read after confirming each time.

**Not possible from macOS:**
- Find My locations.
- Remotely controlling another device's screen.
- Reading iPhone app data outside app containers.
- Reading your Messages history.

Apple TV/HomePod playback control needs a third-party tool such as `pyatv`. Use `--no-apple` to drop these tools for small models.

Debug a tool without a model:

```bash
iagent --run-tool apple_devices '{}'
iagent --run-tool reminders '{"action":"lists"}'
iagent --run-tool mac '{"action":"battery"}'
```

## Build & install

```bash
cd iAgent
scripts/build-release.sh                   # release build, signed with the hardened runtime → dist/iagent
cp dist/iagent /usr/local/bin/             # or anywhere on PATH
```

Requires macOS 14+ and Swift 5.9+. Xcode is optional but needed for iPhone/iPad management and simulators.

## Usage

```bash
iagent                                  # interactive session
iagent "explain this repo"              # interactive, starting with a prompt
iagent -p "fix the failing test" --yolo # one-shot, auto-approve tools
git diff | iagent -p "review this diff" # one-shot from stdin
```

REPL commands: `/help`, `/model [id]`, `/clear`, `/tools`, `/yolo`, `/cost`, `/exit`. Type `/` to open a command
menu that filters as you type: ↑/↓ choose, Tab completes, Enter runs, Esc closes.

The prompt is a full line editor. ↑/↓ recall earlier inputs from this session (history is kept in memory only, never
written to disk). ←/→, Option-←/→ (by word), Ctrl-A/E, Ctrl-U/K/W and Ctrl-L work as in a shell. For a new line, press
Ctrl-J or Option-Enter, or end the line with `\`. Pasted text keeps its newlines and is not submitted until you press
Enter. Ctrl-C clears the input, Ctrl-C twice on an empty prompt (or Ctrl-D) exits, and Ctrl-C during a turn stops it, including at an approval prompt (the tool call is then refused).

## Keeping data private

**Secrets are always masked.** Before anything is sent to the model (your messages, tool results, project
instruction files), iagent replaces credentials with `[REDACTED]` and tells you when it did:

- known formats: Anthropic/OpenAI/GitHub/GitLab/Slack/AWS/Google/Stripe/npm/Hugging Face keys, JWTs, private key blocks
- `user:password@` in URLs, `Bearer …` tokens, and `password=`/`token:`/`API_KEY=` style values containing letters and digits
- the exact value of your API key, of every environment variable named like `*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, and of custom `headers` with such names (e.g. `Authorization`)

Secret files are never read for a cloud model at all. Masking is pattern-based. A secret in an unusual format can
still get through, so for confidential work use local-only mode.

**Local-only mode keeps everything on this Mac.** Turn it on with `iagent --local`, `"localOnly": true` in the config,
or `IAGENT_LOCAL_ONLY=1`. In this mode:

- The model server must be on this Mac (`localhost`, `127.0.0.1`, `::1`). Cloud APIs and LAN servers are refused, and
  the provider defaults to Apple's on-device model (`fm`) even if an API key is set. With `-m <model>`, or on a Mac without
  `fm`, it defaults to Ollama instead. Example: `iagent --local -m qwen3-coder`.
- Tools that send data elsewhere are removed: `web_fetch`, `messages`, `airdrop`, `shortcuts`, `applescript`,
  `ios_device`, `apple_devices`.
- Actions that sync through iCloud or reach other devices are blocked: reminder/calendar/note changes,
  `mac open`, `mac clipboard_set` (Universal Clipboard), `simulator openurl`/`raw`.
- `bash` runs in a macOS sandbox. It can't connect to anything but localhost, resolve DNS names, open apps or URLs, or
  send Apple Events. Builds, git, and tests that don't need the network work normally.

## Running offline with a local model

### Apple's on-device model (`fm`)

On macOS 27 with Apple Intelligence on, the model is already on your Mac. Agree to the terms once, then start iAgent:

```bash
sudo fm license        # once per Mac
iagent --local         # or just `iagent` when no API key is set
```

iAgent starts `fm serve` on `127.0.0.1:8642` and stops it again when it exits. If a server is already listening
there, iAgent uses that one. To run your own server, start it with `fm serve --port <n>` and pass
`--base-url http://127.0.0.1:<n>/v1 -m system`.

With `fm`, iAgent is a chat assistant only: no file, command or Apple tools. On macOS 27.0, `fm serve` can't call
tools (given a tool list, the model never returns a tool call), and the long agent prompt made it refuse ordinary
questions. Instead it gets a short prompt (about 200 tokens) with the current time, refreshed on every message.
Use it for questions, explanations and code snippets; use a larger model for work on your files.

The model's context holds 4,096 tokens, and iAgent measures it with `fm count-tokens`:

- At startup it counts its prompt and loads `AGENTS.md`, `CLAUDE.md` and `.iagent.md` only while they fit with
  1,024 tokens left for the conversation. A file that doesn't fit is skipped with a warning, so keep a short
  `.iagent.md` for this model.
- After each answer it shows `context: 250 / 4096 tokens`, in yellow once it is three-quarters full.
- A message that won't fit is stopped before it is sent. `/clear` starts a fresh conversation.

With a larger main model (Claude, GPT, …), the `apple_fm` tool lets that model hand text work to the on-device
model instead, e.g. "summarize notes.txt on-device".

### Other local servers

1. Install a local model server and download a model while you still have internet:

   ```bash
   brew install ollama
   ollama serve &                 # listens on http://localhost:11434
   ollama pull qwen3-coder
   ```

   Or use LM Studio: download and load a model, then start its local server (`http://localhost:1234/v1`).

   Or use [mlx-lm](https://github.com/ml-explore/mlx-lm) (Apple Silicon only, runs on the GPU through MLX):

   ```bash
   pipx install mlx-lm            # or: pip install mlx-lm
   mlx_lm.server --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit   # http://localhost:8080/v1
   ```

   The model downloads from Hugging Face on first start and is cached in `~/.cache/huggingface`. After that it works offline.
   The server is local, but keep it bound to `127.0.0.1` (the default); `--local` refuses it otherwise.

2. Start iAgent in local-only mode:

   ```bash
   iagent --local -m qwen3-coder                  # Ollama
   iagent --local --provider lmstudio -m <loaded-model>
   iagent --local --provider mlx -m mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
   ```

   Once the model is downloaded, no internet is needed.

3. To make this the default, add a profile to `~/.iagent/config.json`:

   ```json
   { "profile": "local",
     "profiles": { "local": { "provider": "ollama", "model": "qwen3-coder", "localOnly": true } } }
   ```

   For mlx-lm use `{ "provider": "mlx", "model": "<the model id you passed to mlx_lm.server>", "localOnly": true }`.
   Then plain `iagent` runs offline. Use `IAGENT_PROFILE=<name>` to pick another profile for one run.

Small models may struggle with the full tool list. Add `--no-apple` to drop the Apple device tools.

## Choosing a model

| Provider | Command | Key env var |
|---|---|---|
| Anthropic | `iagent --provider anthropic` (default model `claude-opus-5-5`) | `ANTHROPIC_API_KEY` |
| OpenAI | `iagent --provider openai -m gpt-5` | `OPENAI_API_KEY` |
| OpenRouter | `iagent --provider openrouter -m qwen/qwen3-coder` | `OPENROUTER_API_KEY` |
| Apple on-device | `iagent --provider fm` (model `system`) | – |
| Ollama | `iagent --provider ollama -m qwen3-coder` | – |
| LM Studio | `iagent --provider lmstudio -m <loaded-model>` | – |
| mlx-lm | `iagent --provider mlx -m <model-id>` | – |
| Any OpenAI-compatible | `iagent --base-url http://host:8000/v1 -m <id> --api-key-env MY_KEY` | your choice |
| Anthropic-compatible gateway | `iagent --base-url https://gw.example.com --kind anthropic -m <id>` | `ANTHROPIC_API_KEY` |

If you don't pass `--provider`, the provider is picked from the first key env var that is set: `ANTHROPIC_API_KEY`, then `OPENAI_API_KEY`, then `OPENROUTER_API_KEY`. If none are set, it uses Apple's on-device model (`fm`). On a Mac without `fm`, or when `-m` names another model, it uses local Ollama.

The model needs to support tool/function calling. Small local models often struggle with multi-step agent work.

## Config file

Settings are applied in this order, with later ones winning: `~/.iagent/config.json`, then `IAGENT_*` env vars, then CLI flags.

```json
{
  "profile": "local",
  "profiles": {
    "local":  { "provider": "ollama", "model": "qwen3-coder" },
    "claude": { "provider": "anthropic", "model": "claude-opus-5-5", "effort": "high" },
    "router": { "provider": "openrouter", "model": "anthropic/claude-sonnet-5-5" },
    "corp":   { "baseURL": "https://llm.internal/v1", "apiKeyEnv": "CORP_LLM_KEY", "model": "llama-4",
                "headers": { "X-Team": "devops" } }
  }
}
```

To switch profiles for a single run: `IAGENT_PROFILE=claude iagent`. Other env vars: `IAGENT_PROVIDER`, `IAGENT_MODEL`, `IAGENT_BASE_URL`, `IAGENT_API_KEY`, `IAGENT_EFFORT`, `IAGENT_LOCAL_ONLY`.

Keys: `provider`, `kind` (`openai`|`anthropic`), `baseURL`, `model`, `apiKey`, `apiKeyEnv`, `apiKeyKeychain` (+ optional `apiKeyKeychainAccount`), `maxTokens`, `effort`, `thinking` (bool), `headers`, `allowInsecureHTTP` (bool), `appleTools` (bool), `localOnly` (bool), `trustedProjects` (list of folders).

Store the API key in the macOS Keychain instead of the file:

```bash
security add-generic-password -s iagent-anthropic -a iagent -w   # prompts for the key
```

Then reference it in the profile: `{ "provider": "anthropic", "apiKeyKeychain": "iagent-anthropic" }`. Never put a plaintext `apiKey` in the file. If you must, `chmod 600 ~/.iagent/config.json`; iAgent warns if other users can read it.

Remote servers must use `https://`. Plain `http://` is accepted only for localhost/LAN servers such as Ollama and LM Studio.

## Project instructions

If the working directory has an `AGENTS.md`, `CLAUDE.md`, or `.iagent.md`, it can be added to the system prompt. These files steer the model, so a cloned repo could use them to slip in instructions. iAgent shows the start of each file and asks whether to trust the folder. The answer lasts for this session only.

To load them without asking, list the folder in the config file:

```json
{ "trustedProjects": ["~/code/my-app"] }
```

Non-interactive runs (`-p` with piped input, CI) can't ask, so they load instruction files only for folders in `trustedProjects`. The files must be regular files inside the project, up to 1 MB. A symlink to somewhere else is skipped.

## Anthropic specifics

- Requests use adaptive thinking (shown dimmed as it streams) with `output_config.effort` (`--effort`, default `high`). Use `--no-thinking` for models without adaptive thinking. It is skipped automatically for Haiku.
- Assistant content blocks, including thinking blocks and their signatures, are sent back unchanged on later turns. The history is append-only.
- Prompt caching is on (`cache_control` at the top level), so the conversation prefix is reused across tool-loop iterations. You can see cache reads with `/cost`.
- On `api.anthropic.com`, two more things are turned on:
  - `eager_input_streaming` for tools.
  - Server-side refusal fallbacks (`fallbacks: "default"`) for Opus 5.5 / Opus 5 / Fable 5.1 / Sonnet 5.5.

  Neither is sent through custom gateways.

## Layout

```
Sources/iAgent/
  main.swift               CLI flags, REPL, slash commands, one-shot mode
  LineEditor.swift         interactive prompt: line editing, history, / command menu
  Agent.swift              agent loop (model → tools → model …), system prompt, stream renderer
  Config.swift             presets, config file / env / flag resolution
  Models.swift             message types, provider protocol, HTTP+SSE helpers with retry
  OpenAIProvider.swift     Chat Completions streaming + tool calls
  AnthropicProvider.swift  Messages API streaming + tool_use/tool_result
  Tools.swift              coding tools + permission/approval prompts
  Process.swift            argv-based process runner, osascript bridge
  AppleDevices.swift       apple_devices, ios_device, simulator, airdrop (+ Bonjour, AirDrop helper)
  ApplePIM.swift           reminders, calendar, contacts, notes, messages
  AppleMac.swift           shortcuts, mac, applescript
  Support.swift            terminal styling, JSON helpers, Ctrl-C handling
  Security.swift           output sanitizer, path policy, secret scrubbing, transport rules
Tests/iAgentTests/
  SecurityTests.swift      regression tests for every control in SECURITY.md
  ToolTests.swift          coding-tool behavior (read/write/edit/glob/grep/bash/web_fetch, invalid JSON)
Info.plist                 privacy usage descriptions embedded into the binary
iAgent.entitlements        hardened-runtime entitlements (Apple Events, Calendars, Contacts only)
scripts/build-release.sh   signed release build
SECURITY.md                threat model, controls, standards mapping, residual risks
AGENTS.md                  architecture and conventions for contributors and coding agents
```

Run the tests with `swift test < /dev/null`. Redirecting stdin makes the session non-interactive, which enables the tests that check approvals are refused without a terminal.

Adding a tool means adding one `Tool(...)` to `Toolbox` (or `AppleTools.all`). It works with both providers.
