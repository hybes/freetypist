import AppKit

enum WritingShortcut {
    /// Control–Option–S. Return, including keypad Enter, is never a writing command.
    static func checksParagraph(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 1 && modifiers.intersection([.command, .control, .option, .shift]) == [.control, .option]
    }
}

enum WritingInputPolicy {
    /// Use control metadata, never the user's draft, to distinguish prose from navigation.
    static func allowsSuggestions(role: String, subrole: String?, labels: [String]) -> Bool {
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
              subrole != "AXSecureTextField", subrole != "AXSearchField" else { return false }
        let navigationLabels = ["search", "find", "filter", "address", "url", "website", "hostname",
                                "host name", "ip address", "command", "jump to", "quick connect"]
        return !labels.contains { label in
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return navigationLabels.contains { term in
                label == term || label.hasPrefix(term + " ") || label.hasPrefix(term + "…")
                    || label.hasPrefix(term + "...") || label.hasPrefix(term + ":")
            }
        }
    }
}
