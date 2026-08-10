/// Word error rate — the bake-off's ruler (D-025, AC-42).
///
/// WER = (substitutions + insertions + deletions) ÷ reference words, after
/// normalization: lowercase, punctuation stripped. The standard measure for
/// speech recognition, computed by word-level edit distance. Lives in the
/// testing product because it is measurement equipment, not pipeline.
import Foundation

public enum WordErrorRate {
    public struct Score: Sendable, Equatable {
        public let referenceWords: Int
        public let substitutions: Int
        public let insertions: Int
        public let deletions: Int

        /// 0.0 = perfect. Can exceed 1.0 when the hypothesis rambles.
        public var wer: Double {
            guard referenceWords > 0 else { return hypothesisIsEmptyToo ? 0 : 1 }
            return Double(substitutions + insertions + deletions) / Double(referenceWords)
        }

        let hypothesisIsEmptyToo: Bool
    }

    /// Lowercase, strip everything that is not a letter, number or space —
    /// and spell digits out ("20" → "twenty"), because the scoring rules in
    /// the fixture say numbers-as-words and a rule that is written but not
    /// implemented is a lie. Locale fixed to en_US for determinism.
    public static func normalize(_ text: String) -> [String] {
        var cleaned = ""
        for character in text.lowercased() {
            cleaned.append(character.isLetter || character.isNumber ? character : " ")
        }
        return cleaned.split(separator: " ").flatMap { token -> [String] in
            let word = String(token)
            guard word.allSatisfy(\.isNumber), let value = Int(word) else { return [word] }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            guard let spelled = formatter.string(from: NSNumber(value: value)) else { return [word] }
            var respelled = ""
            for character in spelled.lowercased() {
                respelled.append(character.isLetter ? character : " ")
            }
            return respelled.split(separator: " ").map(String.init)
        }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)

        // Word-level edit distance with an operation backtrace.
        // dp[i][j] = cheapest way to turn ref[0..<i] into hyp[0..<j].
        var dp = Array(repeating: Array(repeating: 0, count: hyp.count + 1),
                       count: ref.count + 1)
        for i in 0...ref.count { dp[i][0] = i }
        for j in 0...hyp.count { dp[0][j] = j }
        if !ref.isEmpty && !hyp.isEmpty {
            for i in 1...ref.count {
                for j in 1...hyp.count {
                    if ref[i - 1] == hyp[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1]
                    } else {
                        dp[i][j] = 1 + min(dp[i - 1][j - 1],   // substitute
                                           dp[i - 1][j],       // delete from ref
                                           dp[i][j - 1])       // insert from hyp
                    }
                }
            }
        }

        // Walk the table backwards to count each operation kind exactly.
        var i = ref.count, j = hyp.count
        var substitutions = 0, insertions = 0, deletions = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && ref[i - 1] == hyp[j - 1] && dp[i][j] == dp[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                substitutions += 1; i -= 1; j -= 1
            } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                deletions += 1; i -= 1
            } else {
                insertions += 1; j -= 1
            }
        }

        return Score(referenceWords: ref.count, substitutions: substitutions,
                     insertions: insertions, deletions: deletions,
                     hypothesisIsEmptyToo: hyp.isEmpty)
    }
}
