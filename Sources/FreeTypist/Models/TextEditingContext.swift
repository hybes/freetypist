import Foundation

/// AppKit selections use UTF-16 offsets; replacement lengths count visible characters.
struct TextEditingContext {
    let text: String
    let selection: NSRange

    init(text: String, selection: NSRange) {
        self.text = text
        let length = (text as NSString).length
        let location = min(max(0, selection.location), length)
        let range = NSRange(location: location, length: min(max(0, selection.length), length - location))
        self.selection = Self.isValidRange(range, in: text) ? range : NSRange(location: length, length: 0)
    }

    static func isValidRange(_ range: NSRange, in text: String) -> Bool {
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return false }
        let start = String.Index(utf16Offset: range.location, in: text)
        let end = String.Index(utf16Offset: NSMaxRange(range), in: text)
        return (start == text.endIndex || text.indices.contains(start))
            && (end == text.endIndex || text.indices.contains(end))
    }

    var precedingText: String { (text as NSString).substring(to: selection.location) }
    var selectedText: String { (text as NSString).substring(with: selection) }
    var followingText: String { (text as NSString).substring(from: selection.location + selection.length) }

    func replacingSelection(with insertion: String, deleteBackwardsCount: Int = 0) -> (text: String, selection: NSRange) {
        let removed = String(precedingText.suffix(max(0, deleteBackwardsCount))).utf16.count
        let range = NSRange(location: selection.location - removed, length: selection.length + removed)
        return ((text as NSString).replacingCharacters(in: range, with: insertion),
                NSRange(location: range.location + insertion.utf16.count, length: 0))
    }
}
