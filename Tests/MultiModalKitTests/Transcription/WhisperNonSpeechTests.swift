import XCTest
@testable import MultiModalKitWhisper

final class WhisperNonSpeechTests: XCTestCase {
    func testStripsBracketedAndParenthesizedNonSpeechMarkers() {
        XCTAssertEqual(WhisperEngine.stripNonSpeechTokens("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperEngine.stripNonSpeechTokens("(baby babbling)"), "")
        XCTAssertEqual(WhisperEngine.stripNonSpeechTokens("(laughter) بسم الله"), "بسم الله")
        XCTAssertEqual(WhisperEngine.stripNonSpeechTokens("الحمد لله [MUSIC]"), "الحمد لله")
    }

    func testKeepsArabicParentheses() {
        // Only Latin-letter markers are control tokens; spoken Arabic in
        // parentheses is real text and must survive.
        XCTAssertEqual(
            WhisperEngine.stripNonSpeechTokens("قال (وهو يبكي)"),
            "قال (وهو يبكي)")
    }
}
