import Foundation

/// Collects child output up to a fixed cap so a runaway command (`yes`, a huge `cat`) can't exhaust memory.
final class OutputBuffer: @unchecked Sendable {
    static let cap = 10_000_000
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0
    private var eof = false
    /// Set by the reader on end-of-file: every process holding the pipe's write end has closed it.
    var finished: Bool {
        get { lock.lock(); defer { lock.unlock() }; return eof }
        set { lock.lock(); eof = newValue; lock.unlock() }
    }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(Self.cap - data.count, 0)
        data.append(d.prefix(room))
        dropped += d.count - min(d.count, room)
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: data, as: UTF8.self)
        return dropped > 0 ? "[output truncated: only the first \(Self.cap) bytes kept, \(dropped) more discarded]\n" + s : s
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let note: String   // "[timed out ...]" / "[interrupted ...]" or empty

    var ok: Bool { status == 0 && note.isEmpty }
    var combined: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Runs a program with an explicit argv (no shell, so model-supplied arguments can't inject commands).
/// The program is resolved on PATH via /usr/bin/env. Honors task cancellation and a timeout.
func runCommand(_ argv: [String], cwd: URL? = nil, timeout: Double = 60, stdin: Data? = nil,
                mergeStderr: Bool = false) async throws -> CommandResult {
    precondition(!argv.isEmpty)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.environment = SecretEnv.childEnvironment
    if let cwd { process.currentDirectoryURL = cwd }

    let outPipe = Pipe()
    let errPipe = mergeStderr ? outPipe : Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    let inPipe = stdin.map { _ in Pipe() }
    process.standardInput = inPipe ?? FileHandle.nullDevice

    let out = OutputBuffer()
    let err = OutputBuffer()
    outPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { out.finished = true } else { out.append(d) }
    }
    if !mergeStderr {
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { err.finished = true } else { err.append(d) }
        }
    } else {
        err.finished = true
    }

    do {
        try process.run()
    } catch {
        throw AgentError("Could not run \(argv[0]): \(error.localizedDescription)")
    }
    if let inPipe, let stdin {
        // Written in the background: a child that doesn't read more than the pipe buffer (64 KB) would otherwise
        // block us here, before the timeout below starts. Once the child is gone the write fails with EPIPE;
        // F_SETNOSIGPIPE makes that an error instead of a SIGPIPE that kills the agent.
        let input = inPipe.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? input.write(contentsOf: stdin)
            try? input.close()
        }
    }

    let deadline = Date().addingTimeInterval(timeout)
    var note = ""
    while process.isRunning {
        if Task.isCancelled { stop(process); note = "[interrupted by user]"; break }
        if Date() > deadline { stop(process); note = "[timed out after \(Int(timeout))s]"; break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    process.waitUntilExit()
    // Drain until EOF, but don't wait on a background child (`server &`) that inherited the pipe and keeps it open:
    // readToEnd() would block until that child exits, past any timeout and Ctrl-C.
    let drainDeadline = Date().addingTimeInterval(0.5)
    while !(out.finished && err.finished) && Date() < drainDeadline { usleep(20_000) }
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    return CommandResult(status: process.terminationStatus, stdout: out.string, stderr: err.string, note: note)
}

/// Stops the child and everything it started: SIGTERM to its process group (Process makes the child a group
/// leader), then SIGKILL if anything is still running after a grace period, so a command that ignores SIGTERM
/// can't hang the agent.
private func stop(_ process: Process) {
    let pid = process.processIdentifier
    if kill(-pid, SIGTERM) != 0 { process.terminate() }
    let grace = Date().addingTimeInterval(2)
    while process.isRunning && Date() < grace { usleep(50_000) }   // Task.sleep returns at once when cancelled
    if kill(-pid, SIGKILL) != 0 && process.isRunning { kill(pid, SIGKILL) }
}

/// Like runCommand, but throws with the command's own error output on failure and returns trimmed stdout.
func runChecked(_ argv: [String], timeout: Double = 60, stdin: Data? = nil) async throws -> String {
    let r = try await runCommand(argv, timeout: timeout, stdin: stdin)
    guard r.ok else {
        let detail = [r.combined, r.note].filter { !$0.isEmpty }.joined(separator: " ")
        throw AgentError("`\(argv.prefix(3).joined(separator: " "))` failed (exit \(r.status)): \(detail.isEmpty ? "no output" : detail)")
    }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `sandboxed` (local-only mode) runs the shell under LocalOnly.sandboxProfile: the command and everything it
/// starts lose network access, DNS, LaunchServices and Apple Events.
func runShell(_ command: String, cwd: URL, timeout: Double, sandboxed: Bool = false) async throws -> String {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let argv = (sandboxed ? ["/usr/bin/sandbox-exec", "-p", LocalOnly.sandboxProfile] : []) + [shell, "-c", command]
    let r = try await runCommand(argv, cwd: cwd, timeout: timeout, mergeStderr: true)
    let out = r.stdout.trimmingCharacters(in: .newlines)
    return (out.isEmpty ? "(no output)" : out) + (r.note.isEmpty ? "" : "\n" + r.note) + "\n[exit code \(r.status)]"
}

/// Runs AppleScript or JXA. Values are passed as argv to `on run argv` / `function run(argv)`,
/// never interpolated into the script source.
func runOSAScript(_ script: String, javascript: Bool = false, args: [String] = [], timeout: Double = 120) async throws -> String {
    var argv = ["osascript"]
    if javascript { argv += ["-l", "JavaScript"] }
    // `--` ends option parsing: without it a value like "-e" would be read as another script statement (CWE-88).
    argv += ["-e", script, "--"] + args
    let r = try await runCommand(argv, timeout: timeout)
    guard r.ok else {
        var msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not authorized") {
            msg += "\nHint: allow your terminal app under System Settings → Privacy & Security → Automation."
        }
        throw AgentError("osascript failed: \(msg.isEmpty ? r.note : msg)")
    }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Caches `which`/`xcrun --find` lookups for optional external tooling.
actor ToolAvailability {
    static let shared = ToolAvailability()
    private var cache: [String: Bool] = [:]

    func has(_ name: String) async -> Bool {
        if let v = cache[name] { return v }
        let argv = ["devicectl", "simctl"].contains(name) ? ["xcrun", "--find", name] : ["which", name]
        let v = (try? await runCommand(argv, timeout: 15))?.status == 0
        cache[name] = v
        return v
    }
}
