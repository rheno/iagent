import Foundation
import Testing
@testable import iAgent

/// Apple's on-device model (`fm`): fitting its 4,096-token context and the apple_fm tool's schema handling.
/// Counting is injected, so these run without the model.
@Suite struct AppleFMTests {
    /// About 4 characters per token, like English text.
    static func fakeCount(_ instructions: String, _ texts: [String]) async -> Int? {
        (instructions.count + texts.reduce(0) { $0 + $1.count }) / 4
    }

    @Test func instructionsThatWouldFillTheContextAreSkipped() async {
        let big = Agent.ProjectFile(name: "AGENTS.md", text: String(repeating: "x", count: 20_000))
        let small = Agent.ProjectFile(name: ".iagent.md", text: "Use Swift Testing.")
        let system = String(repeating: "s", count: 4_000)
        let fit = await AppleFM.fitInstructions([big, small], system: system, tools: [], count: Self.fakeCount)
        #expect(fit.files == [small])
        #expect(fit.base == (system.count + 2) / 4)   // the prompt plus "[]" for no tools
        #expect(await AppleFM.fitInstructions([small], system: system, tools: [], count: Self.fakeCount).files == [small])
        // Without fm, about 3 characters make a token.
        let estimated = await AppleFM.fitInstructions([big, small], system: system, tools: [], count: { _, _ in nil })
        #expect(estimated.files == [small])
        #expect(estimated.base == (system.count + 2) / 3)
    }

    @Test func messagesThatWontFitAreStoppedBeforeSending() async {
        let count: (String) async -> Int? = { $0.count / 4 }
        #expect(await AppleFM.overflowWarning("What is 2+2?", used: 1_500, count: count) == nil)
        let warning = await AppleFM.overflowWarning(String(repeating: "x", count: 10_000), used: 1_500, count: count)
        #expect(warning?.contains("/clear") == true)
        #expect(await AppleFM.overflowWarning("hi", used: AppleFM.contextSize - 100, count: count) != nil)
    }

    @Test func contextOverflowErrorsAreRecognized() {
        #expect(AppleFM.isContextOverflow(AgentError("Provider error: {\"message\":\"The session's transcript exceeded the model's context size.\"}")))
        #expect(!AppleFM.isContextOverflow(AgentError("Provider error: rate limited")))
    }

    @Test func theModelIsToldWhichModelItIs() {
        let prompt = Agent.buildSystemPrompt(cwd: URL(fileURLWithPath: "/tmp"), tools: [], instructions: [], model: "Apple's on-device Foundation Model")
        #expect(prompt.contains("- Model: you are Apple's on-device Foundation Model"))
    }

    @Test func plainJSONSchemaGetsWhatFmNeeds() throws {
        let plain: [String: Any] = [
            "type": "object",
            "properties": [
                "topics": ["type": "array", "items": ["type": "object", "properties": ["name": ["type": "string"]]]],
                "summary": ["type": "string"],
            ],
            "required": ["summary"],
        ]
        let s = AppleFM.fmSchema(plain)
        #expect(s["title"] as? String == "Result")
        #expect(s["additionalProperties"] as? Bool == false)
        #expect(s["x-order"] as? [String] == ["summary", "topics"])   // required first
        let item = try #require(((s["properties"] as? [String: Any])?["topics"] as? [String: Any])?["items"] as? [String: Any])
        #expect(item["title"] as? String == "ResultTopicsItem")
        #expect(item["additionalProperties"] as? Bool == false)
        #expect(item["x-order"] as? [String] == ["name"])
    }

    @Test func secretFilesFollowReadFileRules() throws {
        let box = try Sandbox()
        _ = try box.write(".env", "TOKEN=x")
        var ctx = box.ctx
        if case .blocked = AppleFM.tool.approval(["prompt": "x", "path": ".env"], ctx) {} else { Issue.record("a secret file must be blocked for a cloud model") }
        ctx.localOnly = true
        if case .sensitive = AppleFM.tool.approval(["prompt": "x", "path": ".env"], ctx) {} else { Issue.record("a secret file must be confirmed in local-only mode") }
        #expect(AppleFM.tool.approval(["prompt": "x"], ctx) == .none)
    }
}
