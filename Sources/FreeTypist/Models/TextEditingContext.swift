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
        self.selection = Range(range, in: text) == nil ? NSRange(location: length, length: 0) : range
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
