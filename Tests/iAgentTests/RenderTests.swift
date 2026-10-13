import Foundation
import Testing
@testable import iAgent

// Claude Code–style rendering of replies and tool results. Colors are off under `swift test`, so output is plain.

@Suite struct RenderTests {
    func render(_ text: String, width: Int = 40, chunk: Int = 3) -> String {
        var md = MarkdownStream(width: width)
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty { out += md.feed(String(rest.prefix(chunk))); rest = rest.dropFirst(chunk) }
        return out + md.flush()
    }

    @Test func replyGetsABulletAndIndentedLines() {
        #expect(render("Hello.\n\nSecond paragraph.") == "⏺ Hello.\n\n  Second paragraph.\n")
        #expect(render("\n\nHi") == "⏺ Hi\n")                        // no leading blank lines
        #expect(render("a\n\n\n\nb") == "⏺ a\n\n  b\n")              // blank runs collapse
    }

    @Test func markdownIsRendered() {
        #expect(render("# Title\nUse **bold**, *it*, `code` and [docs](https://x.dev).")
                == "⏺ Title\n  Use bold, it, code and docs\n  (https://x.dev).\n")
        #expect(render("- one\n- two\n1. first") == "⏺ • one\n  • two\n  1. first\n")
        #expect(render("```swift\nlet x = 1\n```\nDone") == "⏺   let x = 1\n  Done\n")
        #expect(render("> quoted") == "⏺ │ quoted\n")
        #expect(render("snake_case_name and 2 * 3 * 4") == "⏺ snake_case_name and 2 * 3 * 4\n")
    }

    @Test func longLinesWrapUnderTheBullet() {
        let out = render("alpha beta gamma delta epsilon zeta eta theta", width: 20)
        #expect(out == "⏺ alpha beta gamma\n  delta epsilon zeta\n  eta theta\n")
        #expect(render("- a list item that wraps around", width: 20) == "⏺ • a list item that\n    wraps around\n")
    }

    @Test func toolResultsAreSummarized() {
        #expect(ToolDisplay.name("edit_file") == "Update")
        #expect(ToolDisplay.name("unknown_tool") == "unknown_tool")
        #expect(ToolDisplay.result("read_file", "     1\tone\n     2\ttwo") == "Read 2 lines")
        #expect(ToolDisplay.result("read_file", "(empty file)") == "Read 0 lines (empty file)")
        #expect(ToolDisplay.result("read_file", "     1\tlet x = 1\n     2\t") == "Read 1 line")
        #expect(ToolDisplay.result("glob", "a.swift\nb.swift\n... (3 more)") == "Found 5 files")
        #expect(ToolDisplay.result("glob", "No files matched *.x") == nil)
        #expect(ToolDisplay.result("grep", "a.swift:1: x\n(1 credential/secret file(s) were not searched; use read_file on them explicitly if needed)") == "Found 1 matching line")
        #expect(ToolDisplay.result("bash", "hello") == nil)
    }

    @Test func bannerIconIsAFixedSizeTextTile() {
        let rows = Logo.tile().map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
        #expect(rows == [" ▄▄▄▄▄▄ ", "   ✦    ", " ❯ ı_   ", " ▀▀▀▀▀▀ "])
        #expect(rows.allSatisfy { $0.reduce(0) { $0 + PromptLayout.columns($1) } == Logo.width })
    }

    @Test func spinnerLineShowsLabelAndTime() {
        let line = Spinner.line(label: "Thinking", frame: 3, seconds: 5)
        #expect(line.contains("(5s · ctrl-c to interrupt)"))
        #expect(line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).contains("Thinking…"))
    }
}
