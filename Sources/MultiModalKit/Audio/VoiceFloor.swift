import Synchronization

/// THE VOICE GOES FIRST (5d piece 5, D-147–D-149): a small floor shared by the
/// voice and the mind, which run on one GPU.
///
///     voice:  let hold = floor.take()   … decode the first phrase …   hold.giveBack()
///     mind:   between two tokens:  await floor.waitWhileTaken()
///
/// While the voice holds the floor, the mind starts no new token; it goes on the
/// moment the floor is given back. The mind is far ahead of the speech, so the
/// wait is never heard; the voice decodes alone (×1.56–1.58 faster on the Mac,
/// AC-377). Handed to both organs by the app that builds them; neither the
/// coordinator nor a mind or voice that is not given one changes.
public final class VoiceFloor: Sendable {
    public init() {}

    /// The voice takes the floor. Give the hold back on EVERY way the work ends.
    public func take() -> FloorHold { FloorHold() }

    /// Whether any hold is out.
    public var isTaken: Bool { false }

    /// The mind: returns at once when the floor is free; otherwise waits until
    /// it is given back — or until the waiting task is cancelled.
    public func waitWhileTaken() async {}

    /// How many tasks are waiting now (a fact for tests).
    var waiting: Int { 0 }
}

/// One hold on the floor. Given back once; a second `giveBack` does nothing.
public final class FloorHold: Sendable {
    public func giveBack() {}
}
