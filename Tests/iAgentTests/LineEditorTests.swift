import Foundation
import Testing
@testable import iAgent

// The REPL prompt's editing, history, completion and wrapping logic (the raw-terminal I/O is exercised by hand).

@Suite struct LineEditorTests {
    @Test func editsAtTheCursor() {
        var b = LineBuffer("hello world")
        b.moveWordLeft()
        #expect(b.cursor == 6)
        b.insert("big ")
        #expect(b.text == "hello big world")
        b.deleteWordLeft()
        #expect(b.text == "hello world" && b.cursor == 6)
        b.killToEnd()
        #expect(b.text == "hello ")
        b.killToStart()
        #expect(b.text == "" && b.cursor == 0)
        b.backspace()
        #expect(b.text == "")
    }

    @Test func homeEndAndVerticalMovesStayOnLogicalLines() {
        var b = LineBuffer("first line\nab\nthird")
        #expect(b.onLastLine && !b.onFirstLine)
        b.moveUp()                        // col 5 → clamped to the end of "ab"
        #expect(b.cursor == 13)
        b.moveUp()
        #expect(b.cursor == 2 && b.onFirstLine)
        b.moveEnd()
        #expect(b.cursor == 10)
        b.moveDown()
        b.moveHome()
        #expect(b.cursor == 11)
    }

    @Test func charactersAreNeverSplit() {
        var b = LineBuffer("a👍🏽é")
        b.backspace()
        b.backspace()
        #expect(b.text == "a")
    }

    @Test func historyRecallsAndRestoresTheDraft() {
        var h = InputHistory()
        h.add("one"); h.add("two"); h.add("two"); h.add("  ")
        #expect(h.entries == ["one", "two"])
        #expect(h.previous(current: "draft") == "two")
        #expect(h.previous(current: "two") == "one")
        #expect(h.previous(current: "one") == nil)
        #expect(h.next() == "two")
        #expect(h.next() == "draft")
        #expect(h.next() == nil)
    }

    @Test func historyIsBounded() {
        var h = InputHistory()
        for i in 0...InputHistory.limit { h.add("\(i)") }
        #expect(h.entries.count == InputHistory.limit && h.entries.first == "1")
    }

    @Test func slashCompletionPrefersPrefixMatches() {
        let cmds = ["/help", "/model", "/clear", "/cost", "/tools"].map { SlashCommand(name: $0, args: "", summary: "") }
        #expect(SlashCompletion.matches("/", in: cmds).count == 5)
        #expect(SlashCompletion.matches("/c", in: cmds).map(\.name) == ["/clear", "/cost"])
        #expect(SlashCompletion.matches("/o", in: cmds).map(\.name) == ["/model", "/cost", "/tools"])
        #expect(SlashCompletion.matches("/model gpt", in: cmds).isEmpty)
        #expect(SlashCompletion.matches("hi /c", in: cmds).isEmpty)
    }

    @Test func layoutWrapsAndPlacesTheCursor() {
        let l = PromptLayout.make(LineBuffer("abcdefgh"), width: 8, prompt: "> ", continuation: ". ")
        #expect(l.rows == ["> abcdef", "  gh"])
        #expect(l.cursorRow == 1 && l.cursorCol == 4)

        // Text that exactly fills the row puts the cursor at the start of the next one, not past the edge.
        let full = PromptLayout.make(LineBuffer("abcdef"), width: 8, prompt: "> ", continuation: ". ")
        #expect(full.rows == ["> abcdef", "  "] && full.cursorRow == 1 && full.cursorCol == 2)

        var b = LineBuffer("ab\ncd")
        b.cursor = 2
        let multi = PromptLayout.make(b, width: 20, prompt: "> ", continuation: ". ")
        #expect(multi.rows == ["> ab", ". cd"] && multi.cursorRow == 0 && multi.cursorCol == 4)
    }

    @Test func layoutCountsWideCharactersAndHidesControls() {
        #expect(PromptLayout.columns("中") == 2 && PromptLayout.columns("👍") == 2 && PromptLayout.columns("a") == 1)
        let l = PromptLayout.make(LineBuffer("中文\u{1B}[2J"), width: 40, prompt: "> ", continuation: ". ")
        #expect(l.rows == ["> 中文?[2J"] && l.cursorCol == 10)
    }

    @Test func decodesKeysSentAsCSIu() {
        typealias K = LineEditor.Key
        #expect(LineEditor.encodedKey("32u") == K.text(" "))               // Space under "report all keys"
        #expect(LineEditor.encodedKey("27;1;32~") == K.text(" "))          // xterm modifyOtherKeys
        #expect(LineEditor.encodedKey("97;2u") == K.text("A"))
        #expect(LineEditor.encodedKey("97;2;65u") == K.text("A"))          // with the reported text
        #expect(LineEditor.encodedKey("97;1:3u") == K.ignore)              // key release
        #expect(LineEditor.encodedKey("13u") == K.enter && LineEditor.encodedKey("13;2u") == K.newline)
        #expect(LineEditor.encodedKey("127u") == K.backspace && LineEditor.encodedKey("127;3u") == K.deleteWord)
        #expect(LineEditor.encodedKey("99;5u") == K.ctrlC && LineEditor.encodedKey("100;5u") == K.ctrlD)
        #expect(LineEditor.encodedKey("98;3u") == K.wordLeft && LineEditor.encodedKey("27u") == K.escape)
        #expect(LineEditor.encodedKey("57399u") == K.ignore && LineEditor.encodedKey("200~") == nil)
    }
}
