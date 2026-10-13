import Foundation

// MARK: - Terminal rendering in the style of Claude Code: ⏺ replies with markdown, Read(…)/Bash(…) tool lines,
// and a working indicator. Used only when Style.enabled (a color terminal); piped output stays plain text.

/// The "working" line shown while iAgent waits: an Apple Intelligence–style sparkle and a glow that sweeps across the
/// label in Apple's orange → pink → purple → blue, with the elapsed time. `emit` stops it before printing anything,
/// so it never draws over other output.
final class Spinner: @unchecked Sendable {
    static let shared = Spinner()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var label = "Thinking"
    private var started = Date()
    private var frame = 0

    /// Apple Intelligence colors, as 24-bit RGB and the nearest xterm-256 color.
    static let palette: [(r: Int, g: Int, b: Int, xterm: Int)] = [
        (255, 159, 10, 214), (255, 55, 95, 204), (191, 90, 242, 135), (10, 132, 255, 33), (100, 210, 255, 81),
    ]
    static let sparkles = ["✦", "✧", "⋆", "✧"]
    static let trueColor = ["truecolor", "24bit"].contains(ProcessInfo.processInfo.environment["COLORTERM"] ?? "")

    func start(_ label: String = "Thinking") {
        guard Style.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        self.label = label
        guard timer == nil else { return }
        started = Date()
        frame = 0
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: .milliseconds(90))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        fputs("\r\u{1B}[2K\u{1B}[?25h", stdout)
        fflush(stdout)
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard timer != nil else { return }
        frame += 1
        let line = Self.line(label: label, frame: frame, seconds: Int(Date().timeIntervalSince(started)))
        fputs("\u{1B}[?25l\r\u{1B}[2K" + line, stdout)
        fflush(stdout)
    }

    static func line(label: String, frame: Int, seconds: Int) -> String {
        let sparkle = color(sparkles[(frame / 3) % sparkles.count], at: Double(frame) * 0.15)
        let glow = (label + "…").enumerated().map { i, ch in
            color(String(ch), at: Double(i) * 0.18 - Double(frame) * 0.12)
        }.joined()
        return sparkle + " " + glow + Style.dim("  (\(seconds)s · ctrl-c to interrupt)")
    }

    /// `text` in the palette color at `position` (wrapping; fractions blend between neighbors in 24-bit color).
    static func color(_ text: String, at position: Double) -> String {
        let n = Double(palette.count)
        let p = (position.truncatingRemainder(dividingBy: n) + n).truncatingRemainder(dividingBy: n)
        let i = Int(p), f = p - Double(i)
        let a = palette[i], b = palette[(i + 1) % palette.count]
        if trueColor {
            let mix = { (x: Int, y: Int) in Int(Double(x) + (Double(y) - Double(x)) * f) }
            return "\u{1B}[1;38;2;\(mix(a.r, b.r));\(mix(a.g, b.g));\(mix(a.b, b.b))m\(text)\u{1B}[0m"
        }
        return "\u{1B}[1;38;5;\(f < 0.5 ? a.xterm : b.xterm)m\(text)\u{1B}[0m"
    }
}

/// How tools are shown in the transcript: `⏺ Read(Sources/main.swift)` and a one-line result like `⎿ Read 42 lines`.
enum ToolDisplay {
    static let names = [
        "read_file": "Read", "write_file": "Write", "edit_file": "Update", "glob": "Search", "grep": "Search",
        "bash": "Bash", "web_fetch": "Fetch", "apple_devices": "Devices", "ios_device": "iOSDevice",
        "simulator": "Simulator", "airdrop": "AirDrop", "reminders": "Reminders", "calendar": "Calendar",
        "contacts": "Contacts", "notes": "Notes", "messages": "Messages", "shortcuts": "Shortcuts", "mac": "Mac",
        "applescript": "AppleScript", "apple_fm": "AppleIntelligence",
    ]

    static func name(_ tool: String) -> String { names[tool] ?? tool }

    /// A one-line result for tools whose output is a listing, or nil to show the first lines of the output.
    static func result(_ tool: String, _ out: String) -> String? {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        /// The count in a trailing "... (N more …)" line.
        func more() -> Int {
            guard let last = lines.last, last.hasPrefix("... (") else { return 0 }
            return Int(last.dropFirst(5).prefix { $0.isNumber }) ?? 0
        }
        switch tool {
        case "read_file":
            if out == "(empty file)" { return "Read 0 lines (empty file)" }
            var numbered = lines.filter { $0.drop { $0 == " " }.first?.isNumber == true && $0.contains("\t") }
            if numbered.last?.hasSuffix("\t") == true { numbered.removeLast() }   // the empty line after a final newline
            let n = numbered.count
            return n > 0 ? "Read \(n) line\(n == 1 ? "" : "s")" : nil
        case "glob":
            if out.hasPrefix("No files") { return nil }
            let n = lines.filter { !$0.hasPrefix("... (") }.count + more()
            return "Found \(n) file\(n == 1 ? "" : "s")"
        case "grep":
            if out.hasPrefix("No matches") { return nil }
            let hits = lines.filter { !$0.hasPrefix("... (") && !$0.hasPrefix("(") }.count + more()
            return "Found \(hits) matching line\(hits == 1 ? "" : "s")"
        default:
            return nil
        }
    }
}

/// Renders a streamed markdown reply line by line: the first line gets a ⏺ bullet, the rest are indented under it and
/// word-wrapped to the terminal, with headings, lists, quotes, code blocks, **bold**, *italic*, `code` and links.
struct MarkdownStream {
    private var pending = ""
    private var inCode = false
    private var started = false
    private var blankRun = 0
    let width: Int

    init(width: Int) { self.width = max(width, 20) }

    /// Rendered output for every line completed by `chunk` (already sanitized).
    mutating func feed(_ chunk: String) -> String {
        pending += chunk
        var out = ""
        while let nl = pending.firstIndex(of: "\n") {
            out += render(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        return out
    }

    /// The last, unterminated line.
    mutating func flush() -> String {
        defer { pending = "" }
        return pending.isEmpty ? "" : render(pending)
    }

    private mutating func render(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inCode.toggle(); return "" }
        if inCode { return emitRows([Style.code("  " + line)], hanging: 4) }
        if trimmed.isEmpty {
            guard started, blankRun == 0 else { return "" }   // no leading or repeated blank lines
            blankRun += 1
            return "\n"
        }
        blankRun = 0

        let indent = line.prefix { $0 == " " }.count
        var body = trimmed
        var marker = "", hanging = 2
        if let level = Self.headingLevel(trimmed) {
            body = String(trimmed.dropFirst(level + 1))
            let rows = wrap(Self.spans(body), first: 0, rest: 0).map { Style.bold(level == 1 ? Style.underline($0) : $0) }
            return emitRows(rows, hanging: 2)
        } else if ["---", "***", "___"].contains(trimmed) {
            return emitRows([Style.dim(String(repeating: "─", count: min(width - 4, 40)))], hanging: 2)
        } else if trimmed.hasPrefix("> ") || trimmed == ">" {
            let rows = wrap(Self.spans(String(trimmed.dropFirst(2))), first: 2, rest: 2).map { Style.dim("│ " + $0) }
            return emitRows(rows, hanging: 2)
        } else if trimmed.hasPrefix("|") {
            return emitRows([line], hanging: 2)                // tables keep their columns
        } else if let rest = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
            body = String(trimmed.dropFirst(rest.count))
            marker = String(repeating: " ", count: indent) + "• "
        } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                  trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
            marker = String(repeating: " ", count: indent) + String(trimmed[...dot]) + " "
            body = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
        }
        hanging = 2 + marker.count
        let rows = wrap(Self.spans(body), first: marker.count, rest: marker.count)
        return emitRows(rows.enumerated().map { i, r in (i == 0 ? marker : String(repeating: " ", count: marker.count)) + r }, hanging: hanging)
    }

    /// Prefixes the first row of the reply with ⏺ and every other row with the indent.
    private mutating func emitRows(_ rows: [String], hanging: Int) -> String {
        rows.map { row in
            defer { started = true }
            return (started ? "  " : Style.bold("⏺") + " ") + row + "\n"
        }.joined()
    }

    // MARK: Inline markdown

    enum SpanStyle { case plain, bold, italic, code, link }
    typealias Span = (text: String, style: SpanStyle)

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && s.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }

    /// Splits a line into styled spans. An unclosed marker stays literal; `_` never italicizes (snake_case).
    static func spans(_ s: String) -> [Span] {
        var out: [Span] = [], plain = ""
        var i = s.startIndex
        func flushPlain() { if !plain.isEmpty { out.append((plain, .plain)); plain = "" } }
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                flushPlain(); out.append((String(rest[rest.index(after: rest.startIndex)..<end]), .code))
                i = s.index(after: end); continue
            }
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                flushPlain(); out.append((String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), .bold))
                i = end.upperBound; continue
            }
            if rest.hasPrefix("*"), !rest.hasPrefix("**"), rest.dropFirst().first.map({ $0 != " " }) == true,
               let end = rest.dropFirst().firstIndex(of: "*") {
                flushPlain(); out.append((String(rest[rest.index(after: rest.startIndex)..<end]), .italic))
                i = s.index(after: end); continue
            }
            if rest.hasPrefix("["), let close = rest.range(of: "]("), let paren = rest[close.upperBound...].firstIndex(of: ")") {
                flushPlain()
                let text = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                let url = String(rest[close.upperBound..<paren])
                out.append((text, .link))
                if url != text { out.append((" (\(url))", .plain)) }
                i = s.index(after: paren); continue
            }
            plain.append(s[i]); i = s.index(after: i)
        }
        flushPlain()
        return out
    }

    static func styled(_ s: String, _ style: SpanStyle) -> String {
        switch style {
        case .plain: s
        case .bold: Style.bold(s)
        case .italic: Style.italic(s)
        case .code: Style.code(s)
        case .link: Style.underline(Style.blue(s))
        }
    }

    /// Greedy word wrap of styled spans to the width left after the reply indent (2) and `first`/`rest` columns.
    /// A space is written only once the next word is known to fit on the same row.
    private func wrap(_ spans: [Span], first: Int, rest: Int) -> [String] {
        var rows: [String] = [], row = "", col = 0
        var limit = width - 2 - first
        var space: SpanStyle?
        func newRow() { rows.append(row); row = ""; col = 0; limit = width - 2 - rest; space = nil }
        func put(_ w: String, _ style: SpanStyle) {
            guard !w.isEmpty else { return }
            let wcols = w.reduce(0) { $0 + PromptLayout.columns($1) }
            let gap = space != nil && col > 0 ? 1 : 0
            if col > 0 && col + gap + wcols > limit { newRow() }
            if let s = space, col > 0 { row += Self.styled(" ", s); col += 1 }
            space = nil
            guard wcols > limit else { row += Self.styled(w, style); col += wcols; return }
            var chunk = ""                                         // a word longer than a row: split it
            for ch in w {
                let c = PromptLayout.columns(ch)
                if col + c > limit { row += Self.styled(chunk, style); chunk = ""; newRow() }
                chunk.append(ch); col += c
            }
            row += Self.styled(chunk, style)
        }
        for span in spans {
            var word = ""
            for ch in span.text {
                if ch == " " { put(word, span.style); word = ""; if col > 0 { space = span.style } } else { word.append(ch) }
            }
            put(word, span.style)
        }
        rows.append(row)
        return rows
    }
}
