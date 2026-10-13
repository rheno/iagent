import Foundation

// MARK: - Interactive prompt: raw-mode line editor with history and a `/` command menu

/// A REPL command, shown in the `/` autocomplete menu and in /help.
struct SlashCommand {
    let name: String
    let args: String
    let summary: String
}

/// The text being edited plus a cursor. Characters (not bytes or scalars) so the cursor never splits a grapheme.
struct LineBuffer: Equatable {
    private(set) var chars: [Character] = []
    var cursor = 0

    init(_ text: String = "") { chars = Array(text); cursor = chars.count }

    var text: String { String(chars) }
    var isEmpty: Bool { chars.isEmpty }
    var atEnd: Bool { cursor == chars.count }

    private var lineStart: Int { var i = cursor; while i > 0 && chars[i - 1] != "\n" { i -= 1 }; return i }
    private var lineEnd: Int { var i = cursor; while i < chars.count && chars[i] != "\n" { i += 1 }; return i }
    var onFirstLine: Bool { !chars[..<cursor].contains("\n") }
    var onLastLine: Bool { !chars[cursor...].contains("\n") }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    private var wordLeft: Int {
        var i = cursor
        while i > 0 && !Self.isWord(chars[i - 1]) { i -= 1 }
        while i > 0 && Self.isWord(chars[i - 1]) { i -= 1 }
        return i
    }
    private var wordRight: Int {
        var i = cursor
        while i < chars.count && !Self.isWord(chars[i]) { i += 1 }
        while i < chars.count && Self.isWord(chars[i]) { i += 1 }
        return i
    }

    mutating func insert(_ s: String) { let new = Array(s); chars.insert(contentsOf: new, at: cursor); cursor += new.count }
    mutating func backspace() { guard cursor > 0 else { return }; cursor -= 1; chars.remove(at: cursor) }
    mutating func deleteForward() { if cursor < chars.count { chars.remove(at: cursor) } }
    mutating func moveLeft() { cursor = max(0, cursor - 1) }
    mutating func moveRight() { cursor = min(chars.count, cursor + 1) }
    mutating func moveHome() { cursor = lineStart }
    mutating func moveEnd() { cursor = lineEnd }
    mutating func moveWordLeft() { cursor = wordLeft }
    mutating func moveWordRight() { cursor = wordRight }
    mutating func deleteWordLeft() { let s = wordLeft; chars.removeSubrange(s..<cursor); cursor = s }
    mutating func killToEnd() { chars.removeSubrange(cursor..<lineEnd) }
    mutating func killToStart() { let s = lineStart; chars.removeSubrange(s..<cursor); cursor = s }

    /// Same column on the previous / next line of a multi-line input.
    mutating func moveUp() {
        guard !onFirstLine else { return }
        let col = cursor - lineStart
        cursor = lineStart - 1
        cursor = min(lineStart + col, cursor)
    }
    mutating func moveDown() {
        guard !onLastLine else { return }
        let col = cursor - lineStart
        cursor = lineEnd + 1
        cursor = min(cursor + col, lineEnd)
    }
}

/// Up/Down recall of earlier inputs. Kept in memory only: prompts can contain secrets, and iAgent writes nothing to disk.
struct InputHistory {
    private(set) var entries: [String] = []
    private var index: Int?
    private var draft = ""
    static let limit = 500

    mutating func add(_ entry: String) {
        index = nil
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entries.last != entry else { return }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst() }
    }

    /// The previous entry, remembering `current` so Down can return to it; nil at the oldest entry.
    mutating func previous(current: String) -> String? {
        switch index {
        case nil where !entries.isEmpty: draft = current; index = entries.count - 1
        case let i? where i > 0: index = i - 1
        default: return nil
        }
        return entries[index!]
    }

    /// The next entry, or the unsent draft after the newest one; nil when not browsing.
    mutating func next() -> String? {
        guard let i = index else { return nil }
        if i + 1 < entries.count { index = i + 1; return entries[i + 1] }
        index = nil
        return draft
    }
}

enum SlashCompletion {
    /// Commands for a partly typed `/name`: prefix matches first, then names that merely contain it.
    static func matches(_ input: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: \.isWhitespace) else { return [] }
        let q = input.dropFirst().lowercased()
        let prefix = commands.filter { $0.name.dropFirst().lowercased().hasPrefix(q) }
        let inner = commands.filter { c in !prefix.contains { $0.name == c.name } && c.name.lowercased().contains(q) }
        return prefix + inner
    }
}

/// Where the prompt's text lands on screen: one string per terminal row, and the cursor's row and column.
struct PromptLayout {
    var rows: [String]
    var cursorRow: Int
    var cursorCol: Int

    /// Wraps the buffer at `width` columns. Logical lines start with `continuation`, soft-wrapped rows are indented.
    static func make(_ buf: LineBuffer, width: Int, prompt: String, continuation: String, promptWidth: Int = 2) -> PromptLayout {
        let width = max(width, promptWidth + 4)
        var rows: [String] = [], row = prompt, col = promptWidth
        var cursorRow = 0, cursorCol = promptWidth
        for (i, ch) in buf.chars.enumerated() {
            if ch == "\n" {
                if i == buf.cursor { cursorRow = rows.count; cursorCol = col }
                rows.append(row); row = continuation; col = promptWidth
                continue
            }
            let (glyph, w) = display(ch)
            if col + w > width { rows.append(row); row = String(repeating: " ", count: promptWidth); col = promptWidth }
            if i == buf.cursor { cursorRow = rows.count; cursorCol = col }
            row += glyph; col += w
        }
        if buf.atEnd {
            if col >= width { rows.append(row); row = String(repeating: " ", count: promptWidth); col = promptWidth }
            cursorRow = rows.count; cursorCol = col
        }
        rows.append(row)
        return PromptLayout(rows: rows, cursorRow: cursorRow, cursorCol: cursorCol)
    }

    /// What to draw for a character and how many columns it takes. Control characters are drawn as `?` so
    /// pasted escape sequences can't move the cursor or restyle the terminal.
    static func display(_ ch: Character) -> (String, Int) {
        if ch == "\t" { return ("    ", 4) }
        guard let s = ch.unicodeScalars.first else { return ("", 0) }
        if s.value < 0x20 || (0x7F..<0xA0).contains(s.value) { return ("?", 1) }
        return (String(ch), columns(ch))
    }

    static func columns(_ ch: Character) -> Int {
        guard let s = ch.unicodeScalars.first else { return 0 }
        if s.properties.isEmojiPresentation || ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return [.nonspacingMark, .enclosingMark].contains(s.properties.generalCategory) ? 0 : 1
        }
    }
}

/// Reads REPL input in raw mode: editing keys, Up/Down history, a `/` command menu, Tab completion, bracketed paste.
final class LineEditor {
    let commands: [SlashCommand]
    var history = InputHistory()
    private var saved = termios()
    private var drawnCursorRow = 0
    static let menuSize = 8
    /// Shown at the right of the hint row under the input box, e.g. the model and context use.
    var status = ""

    init(commands: [SlashCommand]) { self.commands = commands }

    /// Needs a real terminal on both ends; otherwise the REPL falls back to plain line reads.
    static var isSupported: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    enum Key: Equatable {
        case text(String), paste(String), enter, newline, backspace, delete, left, right, up, down, home, end
        case wordLeft, wordRight, deleteWord, killEnd, killStart, tab, escape, ctrlC, ctrlD, clearScreen, ignore
    }

    /// One submitted input, or nil for Ctrl-D on an empty prompt, Ctrl-C twice, or end of input.
    func read() -> String? {
        guard enableRawMode() else { return nil }
        defer { disableRawMode() }
        var buf = LineBuffer()
        var selected = 0, menuDismissed = false, exitArmed = false
        drawnCursorRow = 0

        func menu() -> [SlashCommand] {
            menuDismissed || !buf.atEnd ? [] : SlashCompletion.matches(buf.text, in: commands)
        }
        func finish(_ result: String?) -> String? {
            buf.cursor = buf.chars.count
            draw(buf, menu: [], selected: 0, notice: nil, boxed: false)   // the input stays in the transcript, unframed
            write("\r\n")
            if let result { history.add(result) }
            return result
        }

        draw(buf, menu: menu(), selected: 0, notice: nil)
        while let key = readKey() {
            let matches = menu()
            var edited = false
            if case .ctrlC = key {} else { exitArmed = false }
            switch key {
            case .text(let s): buf.insert(s); edited = true
            case .paste(let s): buf.insert(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")); edited = true
            case .newline: buf.insert("\n"); edited = true
            case .enter:
                if !matches.isEmpty { buf = LineBuffer(matches[min(selected, matches.count - 1)].name) }
                if buf.atEnd, buf.chars.last == "\\" { buf.backspace(); buf.insert("\n"); edited = true; break }
                return finish(buf.text)
            case .tab:
                if !matches.isEmpty {
                    let c = matches[min(selected, matches.count - 1)]
                    buf = LineBuffer(c.name + (c.args.isEmpty ? "" : " "))
                    edited = true
                }
            case .up:
                if !matches.isEmpty { selected = (selected + matches.count - 1) % matches.count }
                else if !buf.onFirstLine { buf.moveUp() }
                else if let h = history.previous(current: buf.text) { buf = LineBuffer(h); menuDismissed = true }
            case .down:
                if !matches.isEmpty { selected = (selected + 1) % matches.count }
                else if !buf.onLastLine { buf.moveDown() }
                else if let h = history.next() { buf = LineBuffer(h); menuDismissed = true }
            case .backspace: buf.backspace(); edited = true
            case .delete: buf.deleteForward(); edited = true
            case .left: buf.moveLeft()
            case .right: buf.moveRight()
            case .home: buf.moveHome()
            case .end: buf.moveEnd()
            case .wordLeft: buf.moveWordLeft()
            case .wordRight: buf.moveWordRight()
            case .deleteWord: buf.deleteWordLeft(); edited = true
            case .killEnd: buf.killToEnd(); edited = true
            case .killStart: buf.killToStart(); edited = true
            case .escape: menuDismissed = true
            case .clearScreen: write("\u{1B}[H\u{1B}[2J"); drawnCursorRow = 0
            case .ctrlD:
                if buf.isEmpty { return finish(nil) }
                buf.deleteForward(); edited = true
            case .ctrlC:
                if !buf.isEmpty { buf = LineBuffer(); edited = true }
                else if exitArmed { return finish(nil) }
                else { exitArmed = true }
            case .ignore: break
            }
            if edited { selected = 0; menuDismissed = false }
            draw(buf, menu: menu(), selected: selected, notice: exitArmed ? "Press Ctrl-C again to exit" : nil)
        }
        return finish(nil)
    }

    // MARK: Choice menu

    /// A Claude Code–style numbered menu under `question`, answered with ↑/↓ and Enter, a digit, or y/a/n (Esc picks
    /// the last option). The menu is erased once answered. nil for Ctrl-C/Ctrl-D or end of input.
    func choose(_ question: String, options: [String]) -> Int? {
        guard !options.isEmpty, enableRawMode() else { return nil }
        defer { disableRawMode() }
        let width = terminalWidth()
        func clip(_ s: String) -> String { s.count > width - 6 ? String(s.prefix(width - 7)) + "…" : s }
        var selected = 0, drawn = 0
        func draw(erase: Bool = false) {
            var out = "\u{1B}[?25l" + (drawn > 0 ? "\u{1B}[\(drawn)A" : "") + "\r\u{1B}[J"
            if erase {
                write(out + "\u{1B}[?25h")
                return
            }
            let rows = [Style.bold("  " + clip(question))] + options.enumerated().map { i, o in
                i == selected ? Style.cyan(Style.bold("  ❯ \(i + 1).")) + " " + Style.cyan(clip(o)) : Style.dim("    \(i + 1).") + " " + clip(o)
            }
            out += rows.joined(separator: "\r\n")
            drawn = rows.count - 1
            write(out)
        }
        draw()
        defer { draw(erase: true) }
        while let key = readKey() {
            switch key {
            case .up: selected = (selected + options.count - 1) % options.count
            case .down, .tab: selected = (selected + 1) % options.count
            case .enter: return selected
            case .escape: return options.count - 1
            case .ctrlC, .ctrlD: return nil
            case .text(let t):
                if let n = Int(t), (1...options.count).contains(n) { return n - 1 }
                switch t.lowercased() {
                case "y": return 0
                case "a" where options.count == 3: return 1   // "always", as the old [y]es/[a]lways/[n]o prompt
                case "n": return options.count - 1
                default: break
                }
            default: break
            }
            draw()
        }
        return nil
    }

    // MARK: Drawing

    /// Redraws the prompt in place: back to its first row, clear below, write it all, then park the cursor.
    /// `boxed`: framed by rules above and below (Claude Code style), with a hint and status row under it.
    private func draw(_ buf: LineBuffer, menu: [SlashCommand], selected: Int, notice: String?, boxed: Bool = true) {
        let width = terminalWidth()
        let layout = PromptLayout.make(buf, width: width, prompt: Style.bold(Style.magenta("❯ ")), continuation: Style.dim("… "))
        let rule = Style.dim(String(repeating: "─", count: width))
        var rows = (boxed ? [rule] : []) + layout.rows
        let top = boxed ? 1 : 0
        if boxed {
            rows.append(rule)
            let hint = "  / commands · ↑ history · ⌥⏎ newline · ctrl-c exit"
            let room = width - hint.count - status.count - 2
            rows.append(Style.dim(room > 0 ? hint + String(repeating: " ", count: room) + status : "  " + status))
        }
        if !menu.isEmpty {
            let sel = min(selected, menu.count - 1)
            let first = min(max(0, sel - Self.menuSize + 1), max(0, menu.count - Self.menuSize))
            let nameWidth = (menu.map { ($0.name + " " + $0.args).count }.max() ?? 0) + 2
            for (i, c) in menu.enumerated().dropFirst(first).prefix(Self.menuSize) {
                let name = (c.name + " " + c.args).padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let summary = String(c.summary.prefix(max(0, width - nameWidth - 5)))
                rows.append(i == sel ? Style.cyan(Style.bold("  › " + name)) + Style.cyan(summary)
                                     : "    " + name + Style.dim(summary))
            }
            if menu.count > Self.menuSize { rows.append(Style.dim("    (\(menu.count - Self.menuSize) more)")) }
        }
        if let notice { rows.append(Style.dim("  " + notice)) }

        var out = "\u{1B}[?25l"
        if drawnCursorRow > 0 { out += "\u{1B}[\(drawnCursorRow)A" }
        out += "\r\u{1B}[J" + rows.joined(separator: "\r\n")
        let up = rows.count - 1 - (layout.cursorRow + top)
        if up > 0 { out += "\u{1B}[\(up)A" }
        out += "\r" + (layout.cursorCol > 0 ? "\u{1B}[\(layout.cursorCol)C" : "") + "\u{1B}[?25h"
        drawnCursorRow = layout.cursorRow + top
        write(out)
    }

    private func terminalWidth() -> Int { terminalColumns() }

    private func write(_ s: String) { emit(s) }

    // MARK: Terminal mode

    private func enableRawMode() -> Bool {
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return false }
        var raw = saved
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)   // Ctrl-C arrives as a key, not SIGINT
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return false }
        // Bracketed paste, so a pasted newline can't submit; and our own kitty keyboard mode (disambiguate only), so
        // Shift-Enter is reported and a mode another program left on can't turn plain keys like Space into CSI u.
        write("\u{1B}[?2004h\u{1B}[>1u")
        return true
    }

    private func disableRawMode() {
        write("\u{1B}[<u\u{1B}[?2004l")
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    // MARK: Input decoding

    private func readByte(timeoutMs: Int32? = nil) -> UInt8? {
        if let timeoutMs {
            var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, timeoutMs) > 0 else { return nil }
        }
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(STDIN_FILENO, &b, 1)
            if n == 1 { return b }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    private func readKey() -> Key? {
        guard let b = readByte() else { return nil }
        switch b {
        case 0x1B: return readEscape()
        case 0x20..<0x7F, 0x80...: return .text(readUTF8(lead: b))
        default: return Self.controlKey(b)
        }
    }

    static func controlKey(_ b: UInt8) -> Key {
        switch b {
        case 0x0D: return .enter
        case 0x0A: return .newline                 // Ctrl-J
        case 0x7F, 0x08: return .backspace
        case 0x01: return .home
        case 0x05: return .end
        case 0x02: return .left
        case 0x06: return .right
        case 0x10: return .up
        case 0x0E: return .down
        case 0x0B: return .killEnd
        case 0x15: return .killStart
        case 0x17: return .deleteWord
        case 0x09: return .tab
        case 0x03: return .ctrlC
        case 0x04: return .ctrlD
        case 0x0C: return .clearScreen
        case 0x1B: return .escape
        default: return .ignore
        }
    }

    /// A key sent as `CSI code[:alts];mods[:event][;text] u` (kitty keyboard protocol) or `CSI 27;mods;code ~`
    /// (xterm modifyOtherKeys), which Ghostty, kitty, WezTerm and iTerm2 use when a program asks for them.
    static func encodedKey(_ seq: String) -> Key? {
        var fields: [Substring]
        if seq.hasSuffix("u") {
            fields = seq.dropLast().split(separator: ";", omittingEmptySubsequences: false)
        } else if seq.hasPrefix("27;"), seq.hasSuffix("~") {
            fields = seq.dropFirst(3).dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            fields.swapAt(0, 1)
        } else { return nil }
        guard let code = fields[0].split(separator: ":").first.flatMap({ UInt32($0) }), let scalar = UnicodeScalar(code)
        else { return nil }
        let modField = fields.count > 1 ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
        if modField.count > 1, modField[1] == "3" { return .ignore }   // key release
        let mods = (modField.first.flatMap { Int($0) } ?? 1) - 1
        let shift = mods & 1 != 0, alt = mods & 2 != 0, ctrl = mods & 4 != 0, other = mods & 0x38 != 0
        switch code {
        case 13: return shift || alt ? .newline : .enter
        case 9: return .tab
        case 8, 127: return alt ? .deleteWord : .backspace
        case 27: return .escape
        case 0xE000...0xF8FF: return .ignore                     // function and media keys
        default: break
        }
        if ctrl || alt || other {
            let lower = Character(scalar).lowercased()
            switch (ctrl, alt, other) {
            case (true, false, false) where ("a"..."z").contains(lower): return controlKey(UInt8(code | 0x20) & 0x1F)
            case (false, true, false) where lower == "b": return .wordLeft
            case (false, true, false) where lower == "f": return .wordRight
            default: return .ignore
            }
        }
        if fields.count > 2 {                                      // the text the key produces, when reported
            let text = String(String.UnicodeScalarView(fields[2].split(separator: ":").compactMap { UInt32($0).flatMap(UnicodeScalar.init) }))
            if !text.isEmpty { return .text(text) }
        }
        guard code >= 0x20 else { return .ignore }
        return .text(shift ? Character(scalar).uppercased() : String(scalar))
    }

    private func readUTF8(lead: UInt8) -> String {
        let extra = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
        var bytes = [lead]
        for _ in 0..<extra { if let b = readByte(timeoutMs: 50) { bytes.append(b) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readEscape() -> Key {
        guard let b = readByte(timeoutMs: 40) else { return .escape }
        switch b {
        case UInt8(ascii: "["):
            var seq = ""
            while let c = readByte(timeoutMs: 40) {
                seq.append(Character(UnicodeScalar(c)))
                if (0x40...0x7E).contains(c) { break }
            }
            switch seq {
            case "A": return .up
            case "B": return .down
            case "C": return .right
            case "D": return .left
            case "H", "1~", "7~": return .home
            case "F", "4~", "8~": return .end
            case "3~": return .delete
            case "1;3C", "1;5C", "1;9C": return .wordRight
            case "1;3D", "1;5D", "1;9D": return .wordLeft
            case "200~": return .paste(readPaste())
            default: return Self.encodedKey(seq) ?? .ignore
            }
        case UInt8(ascii: "O"):
            switch readByte(timeoutMs: 40) {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            default: return .ignore
            }
        case UInt8(ascii: "b"): return .wordLeft     // Option-Left with "Option as Meta"
        case UInt8(ascii: "f"): return .wordRight
        case 0x7F: return .deleteWord                // Option-Backspace
        case 0x0D: return .newline                   // Option-Enter
        default: return .ignore
        }
    }

    /// Everything up to the bracketed-paste end marker, capped so a runaway paste can't exhaust memory.
    private func readPaste() -> String {
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC [ 2 0 1 ~
        var bytes: [UInt8] = []
        while let b = readByte(timeoutMs: 500) {
            bytes.append(b)
            if bytes.count >= end.count && Array(bytes.suffix(end.count)) == end { bytes.removeLast(end.count); break }
            if bytes.count > 1_000_000 { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
