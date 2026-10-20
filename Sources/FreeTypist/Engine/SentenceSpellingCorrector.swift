import AppKit

struct SentenceSpellingCorrection {
    let edit: TextReplacement
    let count: Int
    let wordEdits: [TextReplacement]

    var spellingPairs: [(String, String)] {
        wordEdits.map { (($0.original.text as NSString).substring(with: $0.range), $0.insertion) }
    }

    /// Preserve the tail when applying a correction through the Playground's native undo path.
    var trailingInsertion: String {
        (edit.result.text as NSString).substring(with: NSRange(
            location: edit.range.location, length: edit.result.selection.location - edit.range.location))
    }
    var trailingLength: Int {
        (edit.original.text as NSString).substring(with: NSRange(
            location: edit.range.location, length: edit.original.selection.location - edit.range.location)).count
    }
}

/// Checks the current paragraph only, preserving wording, punctuation and whitespace.
/// No model or network request is involved in a paragraph spelling check.
@MainActor
enum SentenceSpellingCorrector {
    private static let words = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}]*(?:['’][\p{L}\p{M}]+)*"#)
    private static let protectedText = try! NSRegularExpression(
        pattern: #"`[^`]*(?:`|$)|(?:https?://|www\.)\S+|[^\s]+@[^\s]+|\S*[/_:=#\\]\S*|\b\S+\.\p{L}{2,}\b|\b\S*\d\S*\b"#)

    /// Check the complete word under the cursor, or an exactly selected word.
    /// Do not interpret the prefix before a click as an unfinished misspelling.
    static func wordCorrection(in snapshot: TextInputSnapshot, ignoredWords: Set<String> = [],
                               feedback: [String: SpellingFeedback] = [:],
                               ignoredRanges: [NSRange] = []) -> TextReplacement? {
        guard snapshot.isValid else { return nil }
        let text = snapshot.text as NSString
        let paragraphRange = text.paragraphRange(for: snapshot.selection)
        guard paragraphRange.length <= 2_000 else { return nil }
        let paragraph = text.substring(with: paragraphRange)
        let range = NSRange(location: 0, length: paragraph.utf16.count)
        let selection = NSRange(location: snapshot.selection.location - paragraphRange.location,
                                length: snapshot.selection.length)
        guard let match = words.matches(in: paragraph, range: range).first(where: {
            if selection.length > 0 { return $0.range == selection }
            return selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range)
        }), !protectedText.matches(in: paragraph, range: range).contains(where: {
            NSIntersectionRange($0.range, match.range).length > 0
        }) else { return nil }
        let absoluteRange = NSRange(location: paragraphRange.location + match.range.location, length: match.range.length)
        guard !ignoredRanges.contains(where: { NSIntersectionRange($0, absoluteRange).length > 0 }) else { return nil }
        let word = (paragraph as NSString).substring(with: match.range)
        guard let fixed = SmartWritingFeatures.completedWordCorrection(word, ignoredWords: ignoredWords, feedback: feedback),
              fixed != word else { return nil }
        return TextReplacement(original: snapshot,
            range: absoluteRange, insertion: fixed)
    }

    static func correction(in snapshot: TextInputSnapshot, ignoredWords: Set<String> = [],
                           feedback: [String: SpellingFeedback] = [:],
                           ignoredRanges: [NSRange] = []) -> SentenceSpellingCorrection? {
        guard snapshot.isValid, snapshot.selection.length == 0 else { return nil }
        let context = snapshot.context
        // Leave text after the cursor untouched.
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
            let absoluteRange = NSRange(location: offset + match.range.location, length: match.range.length)
            guard !ignoredRanges.contains(where: { NSIntersectionRange($0, absoluteRange).length > 0 }) else { continue }
            let word = nsText.substring(with: match.range)
            guard let fixed = SmartWritingFeatures.completedWordCorrection(word, ignoredWords: ignoredWords, feedback: feedback),
                  fixed != word else { continue }
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
