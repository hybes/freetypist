import Foundation

/// Local evidence about a specific proposed correction, not an accepted spelling.
/// Positive weight means "less likely"; acceptance moves the weight the other way.
public struct SpellingFeedback: Codable, Sendable {
    let word: String
    let correction: String
    var weight: Double
    var updatedAt: Date

    func weight(at date: Date) -> Double {
        let age = max(0, date.timeIntervalSince(updatedAt))
        return weight * pow(0.5, age / (3 * 24 * 60 * 60))
    }

    func allows(confidence: Double, at date: Date = Date()) -> Bool {
        confidence - 0.18 * weight(at: date) >= 0.6
    }

    static func words(_ word: String, correction: String) -> (String, String)? {
        guard let original = AppSettings.spellingKey(word) else { return nil }
        let replacement = correction.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .precomposedStringWithCanonicalMapping.lowercased()
        guard !replacement.isEmpty, replacement.count <= 100, replacement != original,
              replacement.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" || $0 == "-" }) else { return nil }
        return (original, replacement)
    }

    static func key(_ word: String, correction: String) -> String? {
        guard let (original, replacement) = words(word, correction: correction) else { return nil }
        return original + "\u{1f}" + replacement
    }
}
