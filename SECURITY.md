# iAgent security

iAgent runs an LLM that can read files, run commands and act on your Apple devices and iCloud data. This document covers:

- what it protects against,
- the controls that do it, mapped to the standards they come from,
- the risks that remain.

The last review was on 2026-10-07 against v0.2.0. Every control below has a regression test that tries to break it, listed under "How it was verified".

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
| none | Read-only, inside the project: read/glob/grep in the working dir, device scans, listing reminders/events, battery | – | – |
| ask | Changes: writes in the project, reminders/calendar/notes edits, installs, shortcuts, AppleScript | skips | per tool action |
| ask, scoped | `bash` (scoped to the exact command), `web_fetch` (scoped to the host), file access outside the working dir | skips | that exact scope only |
| sensitive | Secret/credential files (read or write), shell-startup and LaunchAgent files, sending messages | **still asks** | not offered |

- Non-interactive runs refuse anything that isn't "none" unless you pass `--yolo`. "Sensitive" calls are refused in non-interactive runs, with or without `--yolo`.
- Each approval prompt shows exactly what will run: the full command, the diff (up to 40 lines each side, with a count of the rest), or the message recipient and text.

### Data exfiltration and secrets (OWASP LLM02, CWE-200/312/522/732)

- **Secret files need confirmation every time.** This covers `.env*`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, Keychains, `*.pem/*.key/*.p12`, `.netrc`, `.git-credentials`, `~/.iagent`, and similar.
- **Symlinks are resolved first.** So `innocent.txt -> ~/.ssh/id_rsa` is caught.
- **`grep` never opens secret files.** It tells the model how many it skipped.
- **`web_fetch` asks per host.** This closes the "read a secret, then fetch `evil.example/?k=<secret>`" path.
- **API keys are removed from child processes.** `bash`, `osascript` and every helper run without `*_API_KEY` in their environment, including any custom `apiKeyEnv`.
- **Keys can live in the macOS Keychain** (`apiKeyKeychain`). A config file containing `apiKey` that other users can read triggers a startup warning.
- **Nothing is written to disk.** No transcript, cookie or cache is stored (sessions are ephemeral). Temporary files are deleted immediately.

### Transport (CWE-319, OWASP ASVS V12)

- **HTTPS with TLS 1.2 or later** is required for model APIs. Plain `http://` works only for loopback/LAN servers such as Ollama or LM Studio, unless you set `allowInsecureHTTP: true`.
- **Model API requests never follow redirects,** so an API key header can't be replayed to another host.
- **`web_fetch` follows redirects only within the approved host.** It has its own credential-less session.

### Injection (CWE-78, CWE-88, CWE-150, OWASP LLM05)

- **No shell is involved** except in the `bash` tool itself. Every external program gets an explicit argument list.
- **Script values are passed as arguments.** AppleScript/JXA values are separated from the script by `--` and never spliced into it.
- **Option-looking values are rejected.** Device ids, bundle ids, app names, shortcut names and URLs starting with `-` are refused. `say` reads its text from stdin.
- **Terminal output is sanitized.** Model output, tool output, previews and server errors all pass through the sanitizer before printing. ESC, CR, other control characters, bidi overrides and zero-width characters become visible markers (`␛`, `␍`, `⟨U+202E⟩`). So nothing can retitle the window, erase lines, write the clipboard over OSC 52, or fake an approval prompt.
- **Untrusted content is labeled.** The system prompt tells the model to treat tool output as data. Web content is wrapped in `<untrusted_web_content>`.

### Resource limits (OWASP LLM10, CWE-400/770)

- `read_file` is limited to 20 MB, `web_fetch` downloads to 5 MB, and command output to 10 MB.
- Tool results sent to the model are cut at 30k characters.
- Commands time out after 120 s by default (600 s max).
- A single request is limited to 60 model calls.

### Binary and platform (Apple platform security, OWASP LLM03 Supply Chain)

- **No third-party dependencies.** Only Apple frameworks are used.
- **`scripts/build-release.sh` signs with the hardened runtime** (no JIT, no `DYLD_*` injection, library validation on). It grants only three entitlements: Apple Events, Calendars/Reminders and Contacts. With `SIGN_IDENTITY` set, it produces a Developer ID build ready for notarization.
- **macOS privacy permissions (TCC) apply to each data class.** The embedded `Info.plist` explains why each one is requested.

## Standards coverage

| Standard | Items addressed |
|---|---|
| OWASP Top 10 for LLM Applications 2025 | LLM01 Prompt Injection (approval gates, untrusted-content handling), LLM02 Sensitive Information Disclosure, LLM03 Supply Chain, LLM05 Improper Output Handling, LLM06 Excessive Agency, LLM07 System Prompt Leakage (the system prompt holds no secrets), LLM10 Unbounded Consumption |
| CWE Top 25 / CWE | 22 path traversal, 78 OS command injection, 88 argument injection, 150 terminal escape injection, 200 exposure of sensitive info, 312/522 credential storage, 319 cleartext transmission, 400/770 resource exhaustion, 451 UI misrepresentation, 732 file permissions |
| OWASP ASVS v5 (applicable parts) | V12 secure communication, V13 configuration and secrets, V14 data protection |
| Apple platform security | Hardened runtime, minimal entitlements, TCC usage strings, Keychain for secrets, notarization path |

**What doesn't apply:**

- **Web-app controls** in ASVS (sessions, CSRF, authentication) and **OWASP MASVS** (mobile apps). iAgent is a local CLI with no server and no accounts.
- **Certification.** There is no formal certification such as SOC 2 or ISO 27001. This is a code-level review, not an audit.

## Residual risks (by design, or not fixable in a CLI)

1. **Approved `bash` commands can do anything your user account can.** Read every command before approving. With `--yolo`, all non-sensitive tools run without asking, so use it only in throwaway environments.
2. **Prompt injection can't be fully prevented.** The model can still be misled into *proposing* harmful actions. The approval prompt is the safety boundary.
3. **The model provider sees everything the model reads.** Use a local model (Ollama, LM Studio) for confidential work.
4. **macOS grants privacy permissions to your terminal app** when it launches iAgent. Other tools run from that terminal share those grants.
5. **No App Sandbox.** It's incompatible with a developer agent that must run arbitrary tools.
6. **The secret-file list is a deny-list.** Unusual secret locations aren't recognized. The approval prompt for reading outside the project still applies to them.

## Reporting a vulnerability

Please report privately to the maintainer rather than opening a public issue. Include steps to reproduce. We aim to acknowledge reports within 3 working days.

## How it was verified

Each control was tested with harmless payloads on macOS 26.7. These probes are automated in `Tests/iAgentTests/SecurityTests.swift`; run them with `swift test < /dev/null`.

- **Escape codes:** ESC/OSC sequences in a file were shown as visible markers.
- **Hidden commands:** a `\r`-hidden bash command was visible in the prompt.
- **Secret files:** `~/.ssh` and `.env` reads were refused even with `--yolo`, including through a symlink. `grep` skipped secret files.
- **Exfiltration:** `web_fetch` required approval.
- **Argument injection:**
  - A `say -o` value didn't create the file.
  - An osascript argument `-e <payload>` arrived as plain data.
  - The bundle id `--erase` was rejected.
- **Transport:** plain HTTP to a remote host was refused. A 307 redirect on the API was refused, and the redirect target never received the `Authorization` header. A cross-host `web_fetch` redirect wasn't followed.
- **API keys:** `$OPENAI_API_KEY` was empty inside `bash`.
- **Resource limits:** 30 MB of output was capped at 10 MB.
- **Messages:** refused non-interactively even with `--yolo`.
- **Signed build:** passes `codesign --verify --strict` with the `runtime` flag.
