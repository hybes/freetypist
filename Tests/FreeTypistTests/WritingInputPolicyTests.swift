import AppKit
import XCTest
@testable import FreeTypist

final class WritingInputPolicyTests: XCTestCase {
    func testSearchAddressAndHostControlsAreExcludedWithoutBlockingMessageEditors() {
        for label in ["Search hosts or tabs", "Search", "Filter hosts", "Address and search bar",
                      "URL", "Host name", "IP address", "Command palette", "Quick connect"] {
            XCTAssertFalse(WritingInputPolicy.allowsSuggestions(role: "AXTextField", subrole: nil, labels: [label]), label)
        }
        XCTAssertFalse(WritingInputPolicy.allowsSuggestions(role: "AXTextField", subrole: "AXSearchField", labels: []))
        XCTAssertFalse(WritingInputPolicy.allowsSuggestions(role: "AXTextField", subrole: "AXSecureTextField", labels: []))
        for label in ["Message", "Write a reply…", "Describe your search problem", "Notes", ""] {
            XCTAssertTrue(WritingInputPolicy.allowsSuggestions(role: "AXTextArea", subrole: nil, labels: [label]), label)
        }
    }

    func testParagraphCommandRequiresItsDedicatedShortcutAndNeverReturn() {
        XCTAssertTrue(WritingShortcut.checksParagraph(keyCode: 1, modifiers: [.control, .option]))
        for code: UInt16 in [36, 76, 48, 1] {
            for modifiers: NSEvent.ModifierFlags in [[], [.shift], [.command], [.option], [.control],
                                                     [.command, .control, .option]] {
                XCTAssertFalse(WritingShortcut.checksParagraph(keyCode: code, modifiers: modifiers))
            }
        }
    }

    @MainActor
    func testOldEnterPreferenceDoesNotControlTheNewShortcut() {
        let suite = "com.freetypist.test.enter-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ft_correctSentenceOnEnter")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.paragraphSpellingShortcutEnabled)
        settings.paragraphSpellingShortcutEnabled = false
        XCTAssertNil(defaults.object(forKey: "ft_correctSentenceOnEnter"))
        XCTAssertFalse(AppSettings(defaults: defaults).paragraphSpellingShortcutEnabled)
    }

    @MainActor
    func testIncompleteSearchTokenIsNotGuessedAsAnEnglishWord() {
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "allcl"))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "Search allcl"))
        XCTAssertEqual(SmartWritingFeatures.detectAutocorrect(in: "Please check the correcetions ")?.correctedWord, "corrections ")
    }
}
