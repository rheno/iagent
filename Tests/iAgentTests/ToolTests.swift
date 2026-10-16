import Foundation
import Testing
@testable import iAgent

// Behavior of the coding tools, called directly (approval is covered in SecurityTests).

@Suite struct ToolTests {
    @Test func readFileNumbersLinesAndPages() async throws {
        let box = try Sandbox()
        try box.write("a.txt", "one\ntwo\nthree")
        let all = try await Toolbox.readFile.run(["path": "a.txt"], box.ctx)
        #expect(all == "     1\tone\n     2\ttwo\n     3\tthree")
        let page = try await Toolbox.readFile.run(["path": "a.txt", "offset": 2, "limit": 1], box.ctx)
        #expect(page.hasPrefix("     2\ttwo"))
        #expect(page.contains("1 more lines"))
    }

    @Test func readFileRejectsBinary() async throws {
        let box = try Sandbox()
        try Data([0x00, 0x01, 0x02]).write(to: box.root.appendingPathComponent("b.bin"))
        await #expect(throws: AgentError.self) { try await Toolbox.readFile.run(["path": "b.bin"], box.ctx) }
    }

    @Test func writeFileCreatesParents() async throws {
        let box = try Sandbox()
        let out = try await Toolbox.writeFile.run(["path": "x/y/z.txt", "content": "hi\n"], box.ctx)
        #expect(out == "Created x/y/z.txt (2 lines)")
        #expect(try String(contentsOf: box.root.appendingPathComponent("x/y/z.txt"), encoding: .utf8) == "hi\n")
    }

    @Test func editFileRequiresUniqueMatch() async throws {
        let box = try Sandbox()
        let url = try box.write("e.txt", "foo bar foo")
        await #expect(throws: AgentError.self) {
            try await Toolbox.editFile.run(["path": "e.txt", "old_string": "foo", "new_string": "baz"], box.ctx)
        }
        await #expect(throws: AgentError.self) {
            try await Toolbox.editFile.run(["path": "e.txt", "old_string": "missing", "new_string": "baz"], box.ctx)
        }
        _ = try await Toolbox.editFile.run(["path": "e.txt", "old_string": "bar", "new_string": "qux"], box.ctx)
        #expect(try String(contentsOf: url, encoding: .utf8) == "foo qux foo")
        _ = try await Toolbox.editFile.run(["path": "e.txt", "old_string": "foo", "new_string": "z", "replace_all": true], box.ctx)
        #expect(try String(contentsOf: url, encoding: .utf8) == "z qux z")
    }

    @Test func globMatchesRootAndNestedAndSkipsBuildDirs() async throws {
        let box = try Sandbox()
        try box.write("main.swift", "")
        try box.write("Sources/a.swift", "")
        try box.write(".build/gen.swift", "")
        let out = try await Toolbox.glob.run(["pattern": "**/*.swift"], box.ctx)
        let files = Set(out.split(separator: "\n").map(String.init))
        #expect(files == ["main.swift", "Sources/a.swift"])
        let nested = try await Toolbox.glob.run(["pattern": "Sources/*.swift"], box.ctx)
        #expect(nested == "Sources/a.swift")
        // A search path through a symlink (/var → /private/var) must still match and display relative paths.
        let viaSymlink = try await Toolbox.glob.run(["pattern": "Sources/*.swift", "path": box.root.path], box.ctx)
        #expect(viaSymlink == "Sources/a.swift")
    }

    @Test func grepFindsMatchesButNeverOpensSecrets() async throws {
        let box = try Sandbox()
        try box.write("src/app.swift", "let token = load()\n")
        try box.write(".env", "TOKEN=hunter2\n")
        let out = try await Toolbox.grep.run(["pattern": "(?i)token"], box.ctx)
        #expect(out.contains("src/app.swift:1: let token = load()"))
        #expect(!out.contains("hunter2"))
        #expect(out.contains("1 credential/secret file(s) were not searched"))
    }

    @Test func bashReportsExitCode() async throws {
        let box = try Sandbox()
        let out = try await Toolbox.bash.run(["command": "echo hi; exit 3"], box.ctx)
        #expect(out == "hi\n[exit code 3]")
    }

    @Test func webFetchRejectsNonHTTPURLs() async throws {
        let box = try Sandbox()
        await #expect(throws: AgentError.self) { try await Toolbox.webFetch.run(["url": "file:///etc/passwd"], box.ctx) }
    }

    @Test func invalidJSONArgumentsAreReportedToTheModel() async throws {
        let box = try Sandbox()
        let call = ToolCall(id: "1", name: "read_file", arguments: "{\"path\": \"a.tx")
        let (out, isError) = await Toolbox.execute(call, tools: Toolbox.all(apple: false), ctx: box.ctx)
        #expect(isError)
        #expect(out.contains("INVALID_JSON"))
    }

    @Test func unknownToolsAreReported() async throws {
        let box = try Sandbox()
        let (out, isError) = await Toolbox.execute(ToolCall(id: "1", name: "nope", arguments: "{}"),
                                                   tools: Toolbox.all(apple: false), ctx: box.ctx)
        #expect(isError)
        #expect(out.contains("unknown tool 'nope'"))
    }

    @Test func everyToolHasAnObjectSchemaAndUniqueName() {
        let tools = Toolbox.all(apple: true)
        #expect(Set(tools.map(\.name)).count == tools.count)
        for t in tools { #expect(t.schema["type"] as? String == "object", "\(t.name)") }
    }
}

@Suite struct DateInputTests {
    @Test func relativeOffsetsCountFromNow() throws {
        let (d, hasTime) = try DateInput.parse("+2h")
        #expect(hasTime)
        #expect(abs(d.timeIntervalSinceNow - 7200) < 5)
        #expect(abs(try DateInput.parse("+1.5d").date.timeIntervalSinceNow - 129_600) < 5)
    }

    @Test(arguments: ["+nanm", "+infh", "+1e300d", "+-5m", "+99999999d"])
    func nonsenseOffsetsAreRejected(_ input: String) {
        #expect(throws: AgentError.self) { try DateInput.parse(input) }
    }
}
