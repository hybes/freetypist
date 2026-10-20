import AppKit
import XCTest
@testable import FreeTypist

final class TextReplacementTests: XCTestCase {
    private func snapshot(_ text: String, caret: Int? = nil) -> TextInputSnapshot {
        TextInputSnapshot(identity: 42, text: text, selection: NSRange(location: caret ?? text.utf16.count, length: 0))
    }

    @MainActor
    func testSentenceCorrectsTheUsersDoubledLettersWithoutRewriting() throws {
        let text = "ok sweet, please check the aactual reeplacement stuff, and speelling corrections over a full sentencee!"
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: snapshot(text)))
        XCTAssertEqual(correction.count, 4)
        XCTAssertEqual(correction.edit.result.text,
                       "ok sweet, please check the actual replacement stuff, and spelling corrections over a full sentence!")
        XCTAssertEqual(correction.edit.result.selection.location, correction.edit.result.text.utf16.count)
        XCTAssertNil(SentenceSpellingCorrector.correction(in: correction.edit.result))
    }

    @MainActor
    func testSentencePreservesEmojiAccentsPunctuationAndEarlierParagraphs() throws {
        let text = "An earlier typo: definately.\n👩🏽‍💻 Café — I definately  need speelling help, thanks! 🚀"
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: snapshot(text)))
        XCTAssertEqual(correction.edit.result.text,
                       "An earlier typo: definately.\n👩🏽‍💻 Café — I definitely  need spelling help, thanks! 🚀")
        XCTAssertEqual(correction.edit.result.selection.location, correction.edit.result.text.utf16.count)
    }

    @MainActor
    func testSentenceLeavesValidWordsNamesBritishSpellingAndCodeAlone() {
        for text in [
            "I feel ill. Please fill in the form. Here is my ID.",
            "Ben Hybert uses FreeTypist and Cotypist.",
            "We organise the colour catalogue at the centre.",
            "https://example.com/speelling contact speelling@example.com",
            "Use `speelling` and my_speelling_variable at /tmp/speelling.txt.",
            "Reference ABC123speelling and :rocket:.",
            "She lets them go to and fro. Thanks!",
            "A naïve café visitor said hello."
        ] {
            XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot(text)), text)
        }
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "the form "))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "feel ill "))
    }

    @MainActor
    func testSentenceDoesNotTouchSelectionsMidLineOrOversizeParagraphs() {
        let text = "definately more words"
        XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot(text, caret: 10)))
        XCTAssertNil(SentenceSpellingCorrector.correction(in: TextInputSnapshot(
            identity: 42, text: text, selection: NSRange(location: 0, length: 10))))
        XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot(String(repeating: "word ", count: 410) + "definately")))
        XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot("")))
    }

    @MainActor
    func testSentenceBeforeNewlineRetainsFollowingParagraph() throws {
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in:
            snapshot("A speelling test.\nKeep this sentencee.", caret: "A speelling test.".utf16.count)))
        XCTAssertEqual(correction.edit.result.text, "A spelling test.\nKeep this sentencee.")
        XCTAssertEqual(correction.edit.result.selection.location, "A spelling test.".utf16.count)
    }

    @MainActor
    func testNativeEditorCorrectionAndUndoUseTheRealTextView() throws {
        let editor = GhostAwareNSTextView()
        let undoProvider = TestUndoProvider()
        editor.delegate = undoProvider
        editor.allowsUndo = true
        editor.paragraphSpellingShortcutEnabled = true
        editor.string = "👩🏽‍💻 Check aactual speelling, please!"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var corrections = 0
        editor.onSentenceCorrected = { corrections = $0 }
        undoProvider.undo.beginUndoGrouping()
        XCTAssertTrue(editor.performSentenceSpellingCheck())
        undoProvider.undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "👩🏽‍💻 Check actual spelling, please!")
        XCTAssertEqual(corrections, 2)
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
        XCTAssertFalse(editor.performSentenceSpellingCheck())
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "👩🏽‍💻 Check aactual speelling, please!")
    }

    @MainActor
    func testNativeEditorSettingOffLeavesTextAlone() {
        let editor = GhostAwareNSTextView()
        editor.paragraphSpellingShortcutEnabled = false
        editor.string = "Check speelling"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertFalse(editor.performSentenceSpellingCheck())
        XCTAssertEqual(editor.string, "Check speelling")
    }

    @MainActor
    func testVerifiedWriterReplacesOnlyRequestedRangeAndRestoresCaret() async throws {
        let original = snapshot("👩🏽‍💻 aactual speelling! Afterwards.")
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: original))
        let target = TestTarget(original)
        let result = await TextReplacementWriter.apply(correction.edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value, correction.edit.result)
        XCTAssertEqual(target.typedChunks, [])
    }

    @MainActor
    func testWriterWaitsForAsynchronousSelectionAndTextAcknowledgement() async throws {
        let original = snapshot("A speelling test. Keep the end!")
        let edit = try XCTUnwrap(SentenceSpellingCorrector.correction(in: original)).edit
        let target = TestTarget(original)
        target.delayed = true
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value, edit.result)
        XCTAssertTrue(target.typedChunks.isEmpty)
    }

    @MainActor
    func testUnicodeFallbackReplacesTheSelectedShortcodeOnce() async throws {
        let original = snapshot("Ship :rocket: today", caret: "Ship :rocket:".utf16.count)
        let edit = try XCTUnwrap(TextReplacement.trailing("🚀", count: 8, in: original))
        let target = TestTarget(original)
        target.directWrite = .unsupported
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value.text, "Ship 🚀 today")
        XCTAssertEqual(target.value.selection.location, "Ship 🚀".utf16.count)
        XCTAssertEqual(target.typedChunks, ["🚀"])
    }

    @MainActor
    func testLongInsertionFallbackPreservesUnicode() async throws {
        let original = snapshot("👩🏽‍💻 ")
        let edit = try XCTUnwrap(TextReplacement.trailing("Café visitors can enjoy the sunshine today.", count: 0, in: original))
        let target = TestTarget(original)
        target.directWrite = .unsupported
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value, edit.result)
        XCTAssertGreaterThan(target.typedChunks.count, 1)
        XCTAssertTrue(target.typedChunks.allSatisfy { $0.utf16.count <= 20 })
    }

    @MainActor
    func testLongReplacementRequiresAnAtomicWriteToProtectTheOriginal() async throws {
        let original = snapshot("aactual spelling is a long sentence with a final sentencee!")
        let edit = try XCTUnwrap(SentenceSpellingCorrector.correction(in: original)).edit
        let target = TestTarget(original)
        target.directWrite = .unsupported
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(target.value, original)
        XCTAssertTrue(target.typedChunks.isEmpty)
    }

    @MainActor
    func testSentenceCorrectsSeparateWordsInControlsWithoutAnAXTextSetter() async throws {
        let original = snapshot("👩🏽‍💻 outsiide the playgroundnd, it doesnt offer suitable correcetions.")
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: original))
        let target = TestTarget(original)
        target.directWrite = .unsupported
        let result = await TextReplacementWriter.apply(correction, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value.text, "👩🏽‍💻 outside the playground, it doesn't offer suitable corrections.")
        XCTAssertEqual(target.value.selection.location, target.value.text.utf16.count)
        XCTAssertEqual(target.typedChunks, ["corrections", "doesn't", "playground", "outside"])
    }

    @MainActor
    func testSentenceBatchStopsWhenFocusChangesWithoutDeletingTheRest() async throws {
        let original = snapshot("aactual text with a final sentencee.")
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: original))
        let target = TestTarget(original)
        target.directWrite = .unsupported
        target.loseFocusAfterChunk = true
        let result = await TextReplacementWriter.apply(correction, to: target)
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(target.value.text, "aactual text with a final sentence.")
        XCTAssertEqual(target.typedChunks, ["sentence"])
    }

    @MainActor
    func testWriterDeclinesStaleTextFocusAndMovedCursor() async throws {
        let original = snapshot("Ship :rocket:")
        let edit = try XCTUnwrap(TextReplacement.trailing("🚀", count: 8, in: original))
        for changed in [snapshot("Ship :rocket: now"),
                        snapshot(original.text, caret: 0),
                        TextInputSnapshot(identity: 99, text: original.text, selection: original.selection)] {
            let target = TestTarget(changed)
            let result = await TextReplacementWriter.apply(edit, to: target)
            XCTAssertEqual(result, .stale)
            XCTAssertEqual(target.value, changed)
            XCTAssertEqual(target.selectionWrites, 0)
        }
    }

    @MainActor
    func testWriterDoesNotTypeIfSelectionIsIgnored() async throws {
        let original = snapshot("Ship :rocket:")
        let target = TestTarget(original)
        target.ignoresSelection = true
        let edit = try XCTUnwrap(TextReplacement.trailing("🚀", count: 8, in: original))
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(target.value, original)
        XCTAssertTrue(target.typedChunks.isEmpty)
    }

    @MainActor
    func testAcknowledgedButIgnoredWriteDoesNotDuplicateOrFallBack() async throws {
        let original = snapshot("Ship :rocket:")
        let target = TestTarget(original)
        target.directWrite = .ignored
        let edit = try XCTUnwrap(TextReplacement.trailing("🚀", count: 8, in: original))
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(target.value, original)
        XCTAssertTrue(target.typedChunks.isEmpty)
    }

    @MainActor
    func testKnownUnsupportedSetterIsNeverCalledEvenIfItWouldAcknowledge() async throws {
        let original = snapshot("Check speelling, please!", caret: "Check speelling".utf16.count)
        let target = TestTarget(original)
        target.directWrite = .ignored
        target.directSupport = false
        let edit = try XCTUnwrap(TextReplacement.trailing("spelling", count: 9, in: original))
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.directWrites, 0)
        XCTAssertEqual(target.value.text, "Check spelling, please!")
        XCTAssertEqual(target.typedChunks, ["spelling"])
    }

    @MainActor
    func testKeyboardInsertionWaitsForSeparateValueAndSelectionUpdates() async throws {
        // Equal-length text keeps an old selection valid while AX catches up.
        let original = snapshot("Fix teh now", caret: 7)
        let target = TestTarget(original)
        target.directSupport = false
        target.delayedKeyboardSelection = true
        let edit = try XCTUnwrap(TextReplacement.trailing("the", count: 3, in: original))
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value, edit.result)
        XCTAssertEqual(target.typedChunks, ["the"])
    }

    @MainActor
    func testShortenedWordCanTemporarilyExposeItsOldLongerSelection() async throws {
        let original = snapshot("speelling")
        let target = TestTarget(original)
        target.directSupport = false
        target.delayedKeyboardSelection = true
        let edit = try XCTUnwrap(TextReplacement.trailing("spelling", count: 9, in: original))
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(target.value, edit.result)
        XCTAssertEqual(target.typedChunks, ["spelling"])
    }

    @MainActor
    func testReturnAndKeypadEnterMatchNativeEditorBehaviourWithoutCorrecting() throws {
        for code: UInt16 in [36, 76] {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                                  styleMask: [], backing: .buffered, defer: false)
            let editor = GhostAwareNSTextView()
            window.contentView = editor
            window.makeFirstResponder(editor)
            editor.paragraphSpellingShortcutEnabled = true
            editor.string = "Check speelling."
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: code))
            editor.keyDown(with: event)
            XCTAssertEqual(editor.string, "Check speelling.\n")
        }
    }

    @MainActor
    func testParagraphShortcutCorrectsMultipleEarlierWordsWithoutSubmitting() throws {
        let editor = GhostAwareNSTextView()
        editor.string = "The aactual reeplacement has speelling mistakes in this sentencee."
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.string, "The actual replacement has spelling mistakes in this sentence.")
    }

    @MainActor
    func testChangingFocusDuringFallbackStopsFurtherTyping() async throws {
        let original = snapshot("Replace these words")
        let edit = try XCTUnwrap(TextReplacement.trailing(String(repeating: "new words ", count: 10),
                                                         count: 0, in: original))
        let target = TestTarget(original)
        target.directWrite = .unsupported
        target.loseFocusAfterChunk = true
        let result = await TextReplacementWriter.apply(edit, to: target)
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(target.typedChunks.count, 1)
    }

    @MainActor
    func testReplacementRejectsInvalidUnicodeRangesAndExcessiveDeletion() {
        let text = snapshot("🚀 hello")
        XCTAssertNil(TextReplacement(original: text, range: NSRange(location: 1, length: 1), insertion: "x"))
        XCTAssertNil(TextReplacement.trailing("x", count: 50, in: text))
        XCTAssertNil(TextReplacement.trailing("x", count: -1, in: text))
        let chunks = TextReplacementWriter.unicodeChunks("👩🏽‍💻 " + String(repeating: "café ", count: 10))
        XCTAssertEqual(chunks.joined(), "👩🏽‍💻 " + String(repeating: "café ", count: 10))
    }
}

@MainActor
private final class TestUndoProvider: NSObject, NSTextViewDelegate {
    let undo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}

@MainActor
private final class TestTarget: TextReplacementTarget {
    var supportsDirectReplacement: Bool? { directSupport ?? (directWrite != .unsupported) }
    var directSupport: Bool?
    enum DirectWrite { case supported, unsupported, ignored }
    var value: TextInputSnapshot
    var directWrite = DirectWrite.supported
    var ignoresSelection = false
    var loseFocusAfterChunk = false
    var focused = true
    var delayed = false
    var selectionWrites = 0
    var directWrites = 0
    var delayedKeyboardSelection = false
    var typedChunks: [String] = []
    init(_ value: TextInputSnapshot) { self.value = value }
    func snapshot() -> TextInputSnapshot? { focused ? value : nil }
    func select(_ range: NSRange) -> Bool {
        selectionWrites += 1
        if !ignoresSelection {
            if delayed {
                Task { try? await Task.sleep(for: .milliseconds(5)); self.setSelection(range) }
            } else { setSelection(range) }
        }
        return true
    }
    private func setSelection(_ range: NSRange) {
        value = TextInputSnapshot(identity: value.identity, text: value.text, selection: range)
    }
    func replaceSelectedText(_ text: String) -> Bool {
        directWrites += 1
        if directWrite == .unsupported { return false }
        if directWrite == .supported {
            if delayed {
                Task { try? await Task.sleep(for: .milliseconds(5)); self.write(text) }
            } else { write(text) }
        }
        return true
    }
    func typeText(_ text: String) -> Bool {
        typedChunks.append(text)
        let previousSelection = value.selection
        write(text)
        if delayedKeyboardSelection {
            let finalSelection = value.selection
            setSelection(previousSelection)
            Task { try? await Task.sleep(for: .milliseconds(150)); self.setSelection(finalSelection) }
        }
        if loseFocusAfterChunk { focused = false }
        return true
    }
    private func write(_ text: String) {
        let new = value.context.replacingSelection(with: text)
        value = TextInputSnapshot(identity: value.identity, text: new.text, selection: new.selection)
    }
}
