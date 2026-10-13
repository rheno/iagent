import Foundation

// MARK: - Terminal output

enum Style {
    static let enabled = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    private static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { wrap("1", s) }
    static func dim(_ s: String) -> String { wrap("2", s) }
    static func italic(_ s: String) -> String { wrap("3", s) }
    static func underline(_ s: String) -> String { wrap("4", s) }
    /// Inline code and code blocks in replies: Apple's purple.
    static func code(_ s: String) -> String { wrap("38;5;141", s) }
    static func red(_ s: String) -> String { wrap("31", s) }
    static func green(_ s: String) -> String { wrap("32", s) }
    static func yellow(_ s: String) -> String { wrap("33", s) }
    static func blue(_ s: String) -> String { wrap("34", s) }
    static func magenta(_ s: String) -> String { wrap("35", s) }
    static func cyan(_ s: String) -> String { wrap("36", s) }
}

/// Unbuffered write to stdout (print() is block-buffered when stdout is not a TTY).
func emit(_ s: String) {
    Spinner.shared.stop()   // never print over the working indicator
    fputs(s, stdout)
    fflush(stdout)
}

/// The app icon from the binary's __TEXT,__iagent_icon section (see Package.swift), drawn beside the REPL banner.
enum Logo {
    static let rows = 3, textColumn = 9   // image height in rows; banner text starts this many columns in

    /// Terminals that draw inline images via the kitty graphics protocol. Not through tmux/screen, which drop it.
    static var supported: Bool {
        let env = ProcessInfo.processInfo.environment
        guard Style.enabled, env["TMUX"] == nil, !(env["TERM"] ?? "").hasPrefix("screen") else { return false }
        return env["TERM_PROGRAM"] == "ghostty" || env["TERM"] == "xterm-kitty" || env["KITTY_WINDOW_ID"] != nil
    }

    static var png: Data? {
        var size: UInt = 0
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let p = getsectiondata(header, "__TEXT", "__iagent_icon", &size), size > 0 else { return nil }
        return Data(bytes: p, count: Int(size))
    }

    /// Draws `png` at the cursor, `rows` tall, without moving the cursor. Payload goes in 4096-byte chunks.
    static func kittyImage(_ png: Data) -> String {
        let b64 = Array(png.base64EncodedString().utf8)
        var out = "", i = 0
        repeat {
            let end = min(i + 4096, b64.count), more = end < b64.count ? 1 : 0
            let control = i == 0 ? "a=T,f=100,r=\(rows),C=1,q=2,m=\(more)" : "m=\(more)"
            out += "\u{1B}_G\(control);" + String(decoding: b64[i..<end], as: UTF8.self) + "\u{1B}\\"
            i = end
        } while i < b64.count
        return out
    }

    /// Prints the banner lines, with the icon to their left when the terminal can draw it.
    static func banner(_ lines: [String]) {
        guard supported, let png else { emit(lines.map { $0 + "\n" }.joined()); return }
        let lines = lines + Array(repeating: "", count: max(0, rows - lines.count))
        // Make room first (scrolling if at the bottom), go back up, draw the image, then the text beside it.
        emit(String(repeating: "\n", count: lines.count) + "\u{1B}[\(lines.count)A" + kittyImage(png)
             + lines.map { "\u{1B}[\(textColumn)C" + $0 + "\n" }.joined())
    }
}

func emitError(_ s: String) {
    Spinner.shared.stop()
    fputs(Style.red(Sanitize.terminal(s)) + "\n", stderr)   // may contain server-provided text
}

// MARK: - JSON helpers (JSONSerialization keeps arbitrary tool schemas/inputs simple)

enum JSON {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func data(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    }

    static func string(_ obj: Any, pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct AgentError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func truncate(_ s: String, max: Int = 30_000) -> String {
    guard s.count > max else { return s }
    let head = s.prefix(max)
    return head + "\n... [truncated \(s.count - max) characters]"
}

// MARK: - Ctrl-C handling: cancel the running turn, or exit when idle

final class Interrupter {
    static let shared = Interrupter()
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var source: DispatchSourceSignal?

    func install() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { [weak self] in self?.fire() }
        src.resume()
        source = src
    }

    func track(_ t: Task<Bool, Never>?) {
        lock.lock(); task = t; lock.unlock()
    }

    /// Ctrl-C read as a key (raw mode, e.g. at a permission menu) does what SIGINT does: cancel the running turn.
    func interruptTurn() {
        lock.lock(); let t = task; lock.unlock()
        if let t, !t.isCancelled {
            t.cancel()
            emit(Style.yellow("⏹  Interrupted") + "\n")
        }
    }

    private func fire() {
        lock.lock(); let t = task; lock.unlock()
        if let t, !t.isCancelled {
            t.cancel()
            emit("\n" + Style.yellow("⏹  Interrupted") + "\n")
        } else {
            emit("\n")
            exit(130)
        }
    }
}
