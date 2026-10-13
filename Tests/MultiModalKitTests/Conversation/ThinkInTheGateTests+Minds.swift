// 5d PIECE 4 — F-47 A: WHO MAY ACT, mind by mind (D-144).
//
// A mind that may act — run a tool — is never opened early, inside the reply
// gate: its act could happen before the person has finished. Each real mind
// answers from the tools it was given; a mind with none only talks.

@testable import MultiModalKit
@testable import MultiModalKitMLX
import MultiModalKitTesting
import Testing

@Suite("F-47 · who may act, mind by mind")
struct MayActTests {

    static let aTool = ScriptedTool(name: "log_meal", plan: .answers("logged"))

    @Test("the Apple mind may act exactly when it was given tools")
    @available(macOS 26.0, iOS 26.0, *)
    func theAppleMind() throws {
        let talks = try AppleReplyGenerator(source: ScriptedSnapshotSource(.snapshots(["hi"])))
        let acts = try AppleReplyGenerator(source: ScriptedSnapshotSource(.snapshots(["hi"])),
                                           tools: ToolTable([Self.aTool.tool]))
        #expect(!talks.mayActDuringReply, "no tools: it only talks, and may open early")
        #expect(acts.mayActDuringReply, "with tools: never early")
    }

    @Test("the MLX mind may act exactly when its source was given tools")
    func theMLXMind() throws {
        let talks = try MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"])))
        let acts = try MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"]),
                                                                     tools: ToolTable([Self.aTool.tool])))
        #expect(!talks.mayActDuringReply)
        #expect(acts.mayActDuringReply)
    }
}
