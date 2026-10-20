import AppKit

struct SentenceSpellingCorrection {
    let edit: TextReplacement
    let count: Int
    let wordEdits: [TextReplacement]
}

/// Checks the current paragraph only, preserving wording, punctuation and whitespace.
/// No model or network request is involved in an Enter-key spelling check.
@MainActor
enum SentenceSpellingCorrector {
    private static let words = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}]*(?:['’][\p{L}\p{M}]+)*"#)
    private static let protectedText = try! NSRegularExpression(
        pattern: #"`[^`]*(?:`|$)|(?:https?://|www\.)\S+|[^\s]+@[^\s]+|\S*[/_:=#\\]\S*|\b\S+\.\p{L}{2,}\b|\b\S*\d\S*\b"#)

    static func correction(in snapshot: TextInputSnapshot) -> SentenceSpellingCorrection? {
        guard snapshot.isValid, snapshot.selection.length == 0 else { return nil }
        let context = snapshot.context
        // Enter in the middle of a line retains its native editing behaviour.
        guard context.followingText.isEmpty || context.followingText.first?.isNewline == true else { return nil }
        let prefix = context.precedingText
        let start = prefix.lastIndex(where: \.isNewline).map { prefix.index(after: $0) } ?? prefix.startIndex
        let paragraph = String(prefix[start...])
        guard !paragraph.isEmpty, paragraph.utf16.count <= 2_000 else { return nil }
        let offset = snapshot.selection.location - paragraph.utf16.count
        let range = NSRange(location: 0, length: paragraph.utf16.count)
        let protected = protectedText.matches(in: paragraph, range: range).map(\.range)
        let nsText = paragraph as NSString
        var changes: [(NSRange, String)] = []
        for match in words.matches(in: paragraph, range: range) {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let word = nsText.substring(with: match.range)
            guard let fixed = SmartWritingFeatures.completedWordCorrection(word), fixed != word else { continue }
            changes.append((match.range, fixed))
        }
        guard let first = changes.first, let last = changes.last else { return nil }
        let span = NSRange(location: first.0.location, length: NSMaxRange(last.0) - first.0.location)
        var replacement = nsText.substring(with: span)
        for (wordRange, fixed) in changes.reversed() {
            replacement = (replacement as NSString).replacingCharacters(
                in: NSRange(location: wordRange.location - span.location, length: wordRange.length), with: fixed)
        }
        let newCaret = snapshot.selection.location + replacement.utf16.count - span.length
        guard let edit = TextReplacement(original: snapshot,
            range: NSRange(location: offset + span.location, length: span.length),
            insertion: replacement, caret: newCaret) else { return nil }
        // Controls such as Electron may expose selection but no AX text setter.
        // Replace individual words from right to left so each Unicode insertion
        // is atomic and earlier ranges remain valid.
        var wordEdits: [TextReplacement] = []
        var current = snapshot
        for (range, fixed) in changes.reversed() {
            guard let wordEdit = TextReplacement(original: current,
                range: NSRange(location: offset + range.location, length: range.length),
                insertion: fixed, caret: current.selection.location + fixed.utf16.count - range.length) else { return nil }
            wordEdits.append(wordEdit)
            current = wordEdit.result
        }
        return SentenceSpellingCorrection(edit: edit, count: changes.count, wordEdits: wordEdits)
    }
}
