import MultiModalKit

/// THE TOOL WITH AN ARGUMENT (4z, F-6 = A, AC-268): `set_timer(minutes:)`.
///
/// The session read (`SessionStub`) proved a CALL crosses the seam; this
/// one proves a NUMBER does. A reader says "set a timer for ten minutes",
/// the model calls `set_timer` with `minutes: 10`, and the turn's line
/// prints what arrived — the whole of 4z's phone half, checkable by
/// anyone, one number, no domain (D-108 F-6).
///
/// The same recorder as the session read (one evidence path, one
/// drain), so the row reads `CALLED · timer set: 10 minutes` when the
/// number came through and `tool 'set_timer' cannot run: argument
/// 'minutes' is missing` — the model's own sentence, F-4 = B — when it
/// did not. Nothing is timed for real: the stub RECORDS; a demo that
/// rang a bell would be measuring the bell.
enum TimerStub {
    static let name = "set_timer"
    static let description = "Set a countdown timer."
    static let parameters = [
        MultiModalKit.ToolParameter(name: "minutes",
                                    description: "how many minutes the timer runs",
                                    kind: .integer)
    ]

    /// What to say so the model has a number to pass. Written beside
    /// `SessionStub.sentenceToSay`, for the same reason it exists.
    static let sentenceToSay = "Set a timer for ten minutes."

    static func tool(recording recorder: SessionToolRecorder) -> ReplyTool {
        ReplyTool(name: name, description: description, parameters: parameters) { arguments in
            let minutes = try arguments.integer("minutes")
            let answer = "timer set: \(minutes) minutes"
            await recorder.record(answer)
            return answer
        }
    }
}
