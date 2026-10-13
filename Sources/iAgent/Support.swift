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

/// The app icon beside the REPL banner.
enum Logo {
    static let width = 7

    /// The icon's blue → purple gradient, left to right.
    static let from = (r: 84, g: 104, b: 245), to = (r: 182, g: 88, b: 240)

    /// The app icon drawn with text, so it shows in any color terminal (Terminal, iTerm2, VS Code, tmux…) and on
    /// light or dark themes: a rounded frame around `❯ı_`, with a ✦ in the top edge as the dot of the i, all in the
    /// icon's gradient. No background fill, so no blocky edges.
    static let shape = ["╭──✦──╮", "│ ❯ı_ │", "╰─────╯"]

    static func tile() -> [String] {
        shape.enumerated().map { row, line in
            line.enumerated().map { col, ch in
                let t = (Double(col) + Double(row) * 0.5) / Double(width + 1)
                let mix = { (a: Int, b: Int) in Int(Double(a) + Double(b - a) * t) }
                let bold = "✦❯ı_".contains(ch) ? "\u{1B}[1m" : ""
                return bold + sgr(38, (mix(from.r, to.r), mix(from.g, to.g), mix(from.b, to.b))) + String(ch) + "\u{1B}[0m"
            }.joined()
        }
    }

    /// A foreground (38) or background (48) color: 24-bit when the terminal says it has it, else the nearest
    /// xterm-256 color (Terminal.app).
    static func sgr(_ kind: Int, _ c: (r: Int, g: Int, b: Int)) -> String {
        if Spinner.trueColor { return "\u{1B}[\(kind);2;\(c.r);\(c.g);\(c.b)m" }
        let levels = [0, 95, 135, 175, 215, 255]
        func nearest(_ v: Int) -> Int { levels.indices.min { abs(levels[$0] - v) < abs(levels[$1] - v) }! }
        return "\u{1B}[\(kind);5;\(16 + 36 * nearest(c.r) + 6 * nearest(c.g) + nearest(c.b))m"
    }

    /// Prints the banner lines with the icon to their left (plain lines when color is off).
    static func banner(_ lines: [String]) {
        guard Style.enabled else { emit(lines.map { $0 + "\n" }.joined()); return }
        let icon = tile()
        let lines = lines + Array(repeating: "", count: max(0, icon.count - lines.count))
        emit(lines.enumerated().map { i, line in
            (i < icon.count ? icon[i] : String(repeating: " ", count: width)) + "  " + line + "\n"
        }.joined())
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
