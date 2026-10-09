import Foundation

extension AppleTools {
    // MARK: shortcuts

    static let shortcuts = Tool(
        name: "shortcuts",
        description: """
        Apple Shortcuts (synced across the user's devices). Actions: list (folder?); run (name, input? text, \
        input_path? file). Shortcuts can do things no other tool can: control HomeKit/Home accessories, set Focus \
        modes, use Find My-adjacent and third-party app actions, etc. Returns the shortcut's output.
        """,
        schema: actionSchema(["list", "run"], [
            "name": ["type": "string"], "folder": ["type": "string"],
            "input": ["type": "string", "description": "Text input for the shortcut"],
            "input_path": ["type": "string", "description": "File to pass as input"],
        ]),
        approval: { args, _ in action(args) == "list" ? .none : .ask },
        summary: summarize(["name", "folder"]),
        run: { args, ctx in
            switch action(args) {
            case "list":
                var argv = ["shortcuts", "list"]
                if let f = args["folder"] as? String { argv += ["--folder-name", try operand(f, "folder")] }
                let out = try await runChecked(argv)
                return out.isEmpty ? "No shortcuts." : out
            case "run":
                let name = try operand(try str(args, "name"), "name")
                let output = tempFile("out")
                var cleanup = [output]
                defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
                var argv = ["shortcuts", "run", name, "--output-path", output.path]
                if let p = args["input_path"] as? String {
                    argv += ["--input-path", ctx.resolve(p).path]
                } else if let text = args["input"] as? String {
                    let input = tempFile("txt")
                    try text.write(to: input, atomically: true, encoding: .utf8)
                    cleanup.append(input)
                    argv += ["--input-path", input.path]
                }
                let r = try await runCommand(argv, timeout: 300)
                guard r.ok else { throw AgentError("Shortcut '\(name)' failed: \(r.combined) \(r.note)") }
                guard let data = try? Data(contentsOf: output), !data.isEmpty else { return "Shortcut '\(name)' finished (no output)." }
                if let text = String(data: data, encoding: .utf8), !data.prefix(8000).contains(0) {
                    return truncate(text, max: 20_000)
                }
                // Binary output (image, PDF, ...): keep it where the user can find it.
                let kept = timestampedPath("shortcut-output", "bin")
                try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: kept))
                return "Shortcut '\(name)' returned \(data.count) bytes of binary output, saved to \(kept)"
            default:
                throw AgentError("Unknown action '\(action(args))'")
            }
        })

    // MARK: mac

    private static let macActions = ["notify", "say", "clipboard_get", "clipboard_set", "open", "screenshot",
                                     "volume", "dark_mode", "battery", "wifi", "apps", "now_playing", "sleep_display"]

    static let mac = Tool(
        name: "mac",
        description: """
        Control this Mac. Actions: notify (title, message) — macOS notification; say (text) — speak aloud; \
        clipboard_get; clipboard_set (text) — Universal Clipboard makes it pasteable on the user's nearby \
        iPhone/iPad; open (target: URL, file or app name; app? to open with); screenshot (path?); volume (level 0-100 to \
        set, omit to read); dark_mode (mode on|off|toggle); battery; wifi; apps (running apps); now_playing (Music app); \
        sleep_display.
        """,
        schema: actionSchema(macActions, [
            "title": ["type": "string"], "message": ["type": "string"], "text": ["type": "string"],
            "target": ["type": "string"], "app": ["type": "string"], "path": ["type": "string"],
            "level": ["type": "integer"], "mode": ["type": "string", "enum": ["on", "off", "toggle"]],
        ]),
        approval: { args, _ in
            switch action(args) {
            case "notify", "say", "battery", "wifi", "apps", "now_playing": return .none
            case "volume": return args["level"] == nil ? .none : .ask
            default: return .ask
            }
        },
        summary: summarize(["target", "text", "message", "level", "mode"]),
        run: { args, ctx in
            switch action(args) {
            case "notify":
                _ = try await runOSAScript("on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run",
                                           args: [args["title"] as? String ?? "iAgent", try str(args, "message")])
                return "Notification shown."
            case "say":
                // Text goes in on stdin so it can never be parsed as `say` options (-o file, -v voice).
                _ = try await runChecked(["say", "-f", "-"], timeout: 300, stdin: Data(try str(args, "text").utf8))
                return "Spoken."
            case "clipboard_get":
                return truncate(try await runChecked(["pbpaste"]), max: 20_000)
            case "clipboard_set":
                _ = try await runChecked(["pbcopy"], stdin: Data(try str(args, "text").utf8))
                return "Copied to clipboard (available on nearby devices via Universal Clipboard)."
            case "open":
                let target = try str(args, "target")
                var argv = ["open"]
                if let app = args["app"] as? String { argv += ["-a", try operand(app, "app")] }
                let looksLikeURL = target.contains("://")
                let looksLikePath = target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix(".")
                if !looksLikeURL && !looksLikePath && args["app"] == nil {
                    argv += ["-a", try operand(target, "target")]   // bare name: an application
                } else {
                    argv.append(looksLikeURL ? try operand(target, "target") : ctx.resolve(target).path)
                }
                _ = try await runChecked(argv)
                return "Opened \(target)."
            case "screenshot":
                let path = (args["path"] as? String).map { ctx.resolve($0).path } ?? timestampedPath("screenshot", "png")
                _ = try await runChecked(["screencapture", "-x", path])
                guard FileManager.default.fileExists(atPath: path) else {
                    throw AgentError("No screenshot written — grant Screen Recording to your terminal app in System Settings → Privacy & Security.")
                }
                return "Saved screenshot to \(path)"
            case "volume":
                if let level = int(args, "level") {
                    _ = try await runOSAScript("on run argv\nset volume output volume (item 1 of argv as integer)\nend run",
                                               args: [String(min(max(level, 0), 100))])
                }
                return "Output volume: " + (try await runOSAScript("output volume of (get volume settings)"))
            case "dark_mode":
                let mode = args["mode"] as? String ?? "toggle"
                let expr = mode == "on" ? "true" : mode == "off" ? "false" : "not dark mode"
                let result = try await runOSAScript("""
                tell application "System Events" to tell appearance preferences
                  set dark mode to \(expr)
                  return dark mode
                end tell
                """)
                return "Dark mode: \(result == "true" ? "on" : "off")"
            case "battery":
                return try await runChecked(["pmset", "-g", "batt"])
            case "wifi":
                let ip = (try? await runChecked(["ipconfig", "getifaddr", "en0"])) ?? "no IP on en0"
                let summary = (try? await runChecked(["networksetup", "-getairportnetwork", "en0"])) ?? ""
                return [summary, "IP: \(ip)"].filter { !$0.isEmpty }.joined(separator: "\n")
            case "apps":
                return try await runOSAScript("Application('System Events').processes.whose({backgroundOnly: false}).name().join('\\n')",
                                              javascript: true)
            case "now_playing":
                return try await runOSAScript("""
                if application "Music" is not running then return "Music is not running"
                tell application "Music"
                  if player state is stopped then return "Music: stopped"
                  return (player state as text) & ": " & name of current track & " — " & artist of current track
                end tell
                """)
            case "sleep_display":
                _ = try await runChecked(["pmset", "displaysleepnow"])
                return "Display sleeping."
            default:
                throw AgentError("Unknown action '\(action(args))'")
            }
        })

    // MARK: applescript

    static let appleScript = Tool(
        name: "applescript",
        description: """
        Run AppleScript or JavaScript for Automation (JXA) to control any scriptable Mac app (Music, Safari, Mail, \
        Finder, Photos, Keynote, System Events, ...). Pass dynamic values via `args` (received as `on run argv` / \
        `function run(argv)`) instead of splicing them into the script. Prefer the dedicated tools when one fits.
        """,
        schema: schema([
            "script": ["type": "string"],
            "language": ["type": "string", "enum": ["applescript", "javascript"], "description": "Default applescript"],
            "args": ["type": "array", "items": ["type": "string"]],
        ], required: ["script"]),
        approval: { _, _ in .ask },
        summary: { args in
            let s = (args["script"] as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
            return s.count > 100 ? String(s.prefix(100)) + "…" : s
        },
        preview: { args in
            (args["script"] as? String ?? "").components(separatedBy: "\n").map { Style.yellow("    " + $0) }.joined(separator: "\n")
        },
        run: { args, _ in
            let out = try await runOSAScript(try str(args, "script"), javascript: (args["language"] as? String) == "javascript",
                                             args: args["args"] as? [String] ?? [], timeout: 300)
            return out.isEmpty ? "(no output)" : out
        })
}
