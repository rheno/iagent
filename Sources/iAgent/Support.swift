import Foundation

// MARK: - Terminal output

enum Style {
    static let enabled = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    private static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { wrap("1", s) }
    static func dim(_ s: String) -> String { wrap("2", s) }
    static func red(_ s: String) -> String { wrap("31", s) }
    static func green(_ s: String) -> String { wrap("32", s) }
    static func yellow(_ s: String) -> String { wrap("33", s) }
    static func blue(_ s: String) -> String { wrap("34", s) }
    static func magenta(_ s: String) -> String { wrap("35", s) }
    static func cyan(_ s: String) -> String { wrap("36", s) }
}

/// Unbuffered write to stdout (print() is block-buffered when stdout is not a TTY).
func emit(_ s: String) {
    fputs(s, stdout)
    fflush(stdout)
}

func emitError(_ s: String) {
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
