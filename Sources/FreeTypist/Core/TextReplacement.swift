import Foundation

/// An exact, UTF-16 snapshot. A replacement must never be applied to a newer draft.
struct TextInputSnapshot: Equatable {
    let identity: UInt
    let text: String
    let selection: NSRange

    var context: TextEditingContext { TextEditingContext(text: text, selection: selection) }
    var isValid: Bool { TextEditingContext.isValidRange(selection, in: text) }
}

struct TextReplacement {
    let original: TextInputSnapshot
    let range: NSRange
    let insertion: String
    let result: TextInputSnapshot

    init?(original: TextInputSnapshot, range: NSRange, insertion: String, caret: Int? = nil) {
        guard original.isValid, TextEditingContext.isValidRange(range, in: original.text) else { return nil }
        let text = (original.text as NSString).replacingCharacters(in: range, with: insertion)
        let selection = NSRange(location: caret ?? range.location + insertion.utf16.count, length: 0)
        guard TextEditingContext.isValidRange(selection, in: text) else { return nil }
        self.original = original
        self.range = range
        self.insertion = insertion
        self.result = TextInputSnapshot(identity: original.identity, text: text, selection: selection)
    }

    static func trailing(_ insertion: String, count: Int, in snapshot: TextInputSnapshot) -> TextReplacement? {
        guard snapshot.isValid, count >= 0, count <= snapshot.context.precedingText.count else { return nil }
        let units = snapshot.context.precedingText.suffix(count).utf16.count
        return TextReplacement(original: snapshot,
            range: NSRange(location: snapshot.selection.location - units, length: units + snapshot.selection.length),
            insertion: insertion)
    }
}

@MainActor
protocol TextReplacementTarget: AnyObject {
    var supportsDirectReplacement: Bool? { get }
    /// Returns nil when focus, authorisation or the operation's validity changes.
    func snapshot() -> TextInputSnapshot?
    func select(_ range: NSRange) -> Bool
    func replaceSelectedText(_ text: String) -> Bool
    func typeText(_ text: String) -> Bool
}

extension TextReplacementTarget {
    var supportsDirectReplacement: Bool? { nil }
}

enum TextReplacementResult {
    case applied, stale, unsupported, interrupted
}

/// Uses a verified selection, never a blind sequence of Backspace keys.
@MainActor
enum TextReplacementWriter {
    static func apply(_ correction: SentenceSpellingCorrection, to target: any TextReplacementTarget) async -> TextReplacementResult {
        guard target.supportsDirectReplacement == false else {
            return await apply(correction.edit, to: target)
        }
        // Validate every chunk before editing anything. Never fall back after an
        // acknowledged but unverified AX write.
        guard correction.wordEdits.allSatisfy({ $0.insertion.utf16.count <= 20 }) else { return .unsupported }
        for edit in correction.wordEdits {
            let result = await apply(edit, to: target)
            guard result == .applied else { return result }
        }
        return target.snapshot() == correction.edit.result ? .applied : .interrupted
    }

    static func apply(_ edit: TextReplacement, to target: any TextReplacementTarget) async -> TextReplacementResult {
        guard target.snapshot() == edit.original else { return .stale }
        let selected = TextInputSnapshot(identity: edit.original.identity, text: edit.original.text, selection: edit.range)
        guard target.select(edit.range) else {
            restoreSelection(edit, target: target)
            return .unsupported
        }
        var selectionConfirmed = false
        for _ in 0..<12 {
            guard let now = target.snapshot() else { return .interrupted }
            if now == selected { selectionConfirmed = true; break }
            guard now == edit.original else { return .interrupted }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard selectionConfirmed else { restoreSelection(edit, target: target); return .unsupported }

        let requested = target.replaceSelectedText(edit.insertion)
        // Some apps acknowledge AX writes before exposing the updated value.
        if requested {
            for _ in 0..<8 {
                guard let now = target.snapshot() else { return .interrupted }
                if now.text == edit.result.text { return await finish(edit, target: target) }
                guard now == selected else { return .interrupted }
                try? await Task.sleep(for: .milliseconds(15))
            }
            // An acknowledged but unverified write is ambiguous: never duplicate it.
            restoreSelection(edit, target: target)
            return .unsupported
        }
        if target.snapshot()?.text == edit.result.text { return await finish(edit, target: target) }
        guard target.snapshot() == selected else { return .interrupted }

        // Electron and some native controls expose selection but not AXSelectedText writes.
        // Small Unicode events replace the verified selection without touching the clipboard.
        let chunks = unicodeChunks(edit.insertion)
        // A replacement must fit one keyboard event. If focus changes halfway
        // through a multi-event replacement, the rest of the original would be lost.
        // Long replacements therefore require an atomic Accessibility write.
        guard !chunks.isEmpty, chunks.allSatisfy({ $0.utf16.count <= 20 }),
              chunks.count == 1 || edit.range.length == 0 else {
            restoreSelection(edit, target: target)
            return .unsupported
        }
        var expected = selected
        for chunk in chunks {
            guard target.snapshot() == expected else { return .interrupted }
            guard target.typeText(chunk) else {
                restoreSelection(edit, target: target)
                return .unsupported
            }
            let changed = expected.context.replacingSelection(with: chunk)
            let next = TextInputSnapshot(identity: expected.identity, text: changed.text, selection: changed.selection)
            var confirmed = false
            for _ in 0..<12 {
                guard let now = target.snapshot() else { return .interrupted }
                if now == next { confirmed = true; break }
                guard now == expected else { return .interrupted }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard confirmed else {
                restoreSelection(edit, target: target)
                return .unsupported
            }
            expected = next
        }
        return await finish(edit, target: target)
    }

    private static func finish(_ edit: TextReplacement, target: any TextReplacementTarget) async -> TextReplacementResult {
        guard let now = target.snapshot(), now.text == edit.result.text else { return .interrupted }
        let insertedCaret = NSRange(location: edit.range.location + edit.insertion.utf16.count, length: 0)
        guard [insertedCaret, edit.range, edit.result.selection].contains(now.selection) else { return .interrupted }
        if now == edit.result { return .applied }
        guard target.select(edit.result.selection) else { return .unsupported }
        for _ in 0..<12 {
            guard let next = target.snapshot() else { return .interrupted }
            if next == edit.result { return .applied }
            guard next == now else { return .interrupted }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .unsupported
    }

    private static func restoreSelection(_ edit: TextReplacement, target: any TextReplacementTarget) {
        guard let now = target.snapshot(), now.text == edit.original.text,
              now.selection == edit.range else { return }
        _ = target.select(edit.original.selection)
    }

    static func unicodeChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        for character in text {
            let next = String(character)
            if !chunk.isEmpty && chunk.utf16.count + next.utf16.count > 20 {
                chunks.append(chunk)
                chunk = ""
            }
            // Keep extended emoji and combining sequences intact.
            chunk += next
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
}
