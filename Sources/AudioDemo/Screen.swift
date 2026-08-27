import Foundation
import MultiModalKit

// The demo's terminal owner: the `Screen` actor, and nothing else.

/// One owner for the terminal: permanent lines above, one live status line
/// below (level bar + the current partial). Two event streams write here
/// concurrently; the actor serializes them so the screen never tears.
actor Screen {
    private var speaking = false
    private var levelBar = ""
    private var partial = ""
    private var reply = ""
    private var turnState: TurnState?
    private var drops = 0

    func set(turnState: TurnState) {
        self.turnState = turnState
        render()
    }

    func set(reply: String) {
        self.reply = reply
        render()
    }

    func set(speaking: Bool) {
        self.speaking = speaking
        if !speaking { levelBar = "" }
        render()
    }

    func set(level: Int, drops: Int) {
        self.levelBar = String(repeating: "█", count: level)
        self.drops = drops
        render()
    }

    func set(partial: String) {
        self.partial = partial
        render()
    }

    func log(_ line: String) {
        print("\r\u{1B}[K\(line)")
        render()
    }

    private func render() {
        let icon = speaking ? "🗣" : "…"
        let turnIcon = switch turnState {
        case .thinking: "  💭"
        case .speaking: "  🤖 \(reply.suffix(36))"
        default: ""
        }
        let text = partial.isEmpty ? "" : "  \(partial.suffix(48))"
        let dropText = drops > 0 ? "  dropped:\(drops)" : ""
        let bar = levelBar.padding(toLength: 24, withPad: "·", startingAt: 0)
        print("\r\u{1B}[K\(icon) [\(bar)]\(text)\(turnIcon)\(dropText)",
              terminator: "")
    }
}
