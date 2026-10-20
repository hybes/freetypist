import AppKit
import XCTest
@testable import FreeTypist

final class SpellingLearningTests: XCTestCase {
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "com.freetypist.tests.spelling-learning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.activeProvider = .mock
        settings.minTriggerCharacters = 1_000
        settings.recordWritingForPersonalization = false
        settings.recordUnacceptedWriting = false
        return (settings, defaults)
    }

    private func snapshot(_ text: String, caret: Int? = nil) -> TextInputSnapshot {
        TextInputSnapshot(identity: 42, text: text,
                          selection: NSRange(location: caret ?? text.utf16.count, length: 0))
    }

    func testRememberedWordsPersistNormaliseAndCanBeRemoved() {
        let (settings, defaults) = makeSettings()
        XCTAssertTrue(settings.rememberSpelling(" Navbar "))
        XCTAssertFalse(settings.rememberSpelling("NAVBAR"))
        XCTAssertTrue(settings.rememberSpelling("cafe\u{301}"))
        for invalid in ["", "a", "two words", "navbar;", "https://example.com", "12345", String(repeating: "a", count: 49)] {
            XCTAssertFalse(settings.rememberSpelling(invalid), invalid)
        }
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.rememberedSpellings, ["navbar", "café"])
        XCTAssertTrue(reloaded.exportProfileJSON().contains("rememberedSpellings"))
        reloaded.forgetSpelling("NAVBAR")
        XCTAssertEqual(AppSettings(defaults: defaults).rememberedSpellings, ["café"])
        reloaded.learnSpellingPreferences = false
        XCTAssertFalse(AppSettings(defaults: defaults).learnSpellingPreferences)
    }

    @MainActor
    func testEscapeLowersConfidenceWithoutPermanentlyAcceptingTheWord() throws {
        let (settings, defaults) = makeSettings()
        // Warm the cache first: new spelling preferences must override cached guesses.
        XCTAssertEqual(SmartWritingFeatures.completedWordCorrection("speelling"), "spelling")
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Check speelling, ", bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.misspelledWord, "speelling")
        XCTAssertTrue(engine.handleEscape())
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        XCTAssertFalse(engine.handleEscape(), "A second Escape must go straight to the app.")
        let key = try XCTUnwrap(SpellingFeedback.key("speelling", correction: "spelling"))
        XCTAssertEqual(settings.spellingFeedback[key]?.weight, 1)
        for _ in 0..<3 {
            engine.onTextContextChanged(precedingText: "Check speelling, ", bundleId: "test.editor")
            XCTAssertNil(engine.currentSuggestion)
        }
        XCTAssertEqual(settings.spellingFeedback[key]?.weight, 1, "Refreshes must not count as extra negative feedback.")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.rememberedSpellings.isEmpty)
        XCTAssertEqual(reloaded.spellingFeedback[key]?.weight, 1)
        // A clear doubled-letter repair still has enough confidence in a new
        // context. One Escape is not an instruction to never correct this word.
        XCTAssertNotNil(SmartWritingFeatures.detectAutocorrect(in: "Other Speelling, ", feedback: reloaded.activeSpellingFeedback))
        XCTAssertEqual(SmartWritingFeatures.completedWordCorrection("speelling", feedback: reloaded.activeSpellingFeedback), "spelling")
        let clicked = snapshot("Check speelling and reeplacement.", caret: "Check spee".utf16.count)
        XCTAssertNotNil(SentenceSpellingCorrector.wordCorrection(in: clicked, feedback: reloaded.activeSpellingFeedback))
        let paragraph = try XCTUnwrap(SentenceSpellingCorrector.correction(in: snapshot(clicked.text),
            feedback: reloaded.activeSpellingFeedback))
        XCTAssertEqual(paragraph.count, 2)
        XCTAssertEqual(paragraph.edit.result.text, "Check spelling and replacement.")
        let restartedEngine = CompletionEngine(settings: reloaded)
        restartedEngine.onTextContextChanged(precedingText: clicked.context.precedingText,
            followingText: clicked.context.followingText, bundleId: "test.editor", caretMoved: true)
        XCTAssertNotNil(restartedEngine.currentSuggestion)
        restartedEngine.dismiss()

        settings.resetSpellingLearning()
        engine.onTextContextChanged(precedingText: "Check speelling, ", bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.correctedWord, "spelling, ")
        engine.dismiss()
    }

    @MainActor
    func testRememberedDeveloperTermsLeaveActualTyposCorrectable() throws {
        let (settings, _) = makeSettings()
        settings.rememberSpelling("navbar")
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Please update the navbar.", bundleId: "test.editor")
        XCTAssertNil(engine.currentSuggestion)
        let text = "Update the navbar and fix the speelling."
        let paragraph = try XCTUnwrap(engine.paragraphCorrection(in: snapshot(text)))
        XCTAssertEqual(paragraph.count, 1)
        XCTAssertEqual(paragraph.edit.result.text, "Update the navbar and fix the spelling.")
        engine.onTextContextChanged(precedingText: "Update the nav", followingText: "bar.", bundleId: "test.editor", caretMoved: true)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "Update the NAVBAR ", ignoredWords: settings.rememberedSpellings))
        engine.dismiss()
    }

    @MainActor
    func testParagraphRejectionSuppressesThoseOccurrencesWithoutLearningAllItsTypos() throws {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        let text = "Check speelling and reeplacement "
        engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
        XCTAssertEqual(engine.paragraphSpellingSuggestion?.count, 2)
        XCTAssertTrue(engine.handleEscape())
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        XCTAssertTrue(settings.spellingFeedback.isEmpty)
        engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
        XCTAssertNil(engine.currentSuggestion)
        engine.onTextContextChanged(precedingText: text + "today ", bundleId: "test.editor")
        XCTAssertNil(engine.currentSuggestion)

        let extended = text + "today in a sentencee "
        engine.onTextContextChanged(precedingText: extended, bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.misspelledWord, "sentencee")
        let paragraph = try XCTUnwrap(engine.paragraphCorrection(in: snapshot(extended)))
        XCTAssertEqual(paragraph.count, 1)
        XCTAssertEqual(paragraph.edit.result.text, text + "today in a sentence ")

        // Clicking a word explicitly still lets the user decide about that word.
        engine.onTextContextChanged(precedingText: "Check spee", followingText: "lling and reeplacement ",
                                    bundleId: "test.editor", caretMoved: true)
        XCTAssertEqual(engine.activeAutocorrect?.misspelledWord, "speelling")
        XCTAssertTrue(engine.handleEscape())
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        XCTAssertEqual(settings.spellingFeedback.values.map(\.word), ["speelling"])
    }

    @MainActor
    func testParagraphAcceptanceRechecksTheSameUndismissedEdits() throws {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        let original = "Check speelling and reeplacement "
        engine.onTextContextChanged(precedingText: original, bundleId: "test.editor")
        XCTAssertTrue(engine.handleEscape())
        let updated = snapshot(original + "for aactual correcetions today.")
        engine.onTextContextChanged(precedingText: updated.text, bundleId: "test.editor")
        XCTAssertEqual(engine.paragraphSpellingSuggestion?.count, 2)
        let acceptance = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        let plannedEdit = try XCTUnwrap(acceptance.replacement(in: updated))
        let rechecked = try XCTUnwrap(engine.paragraphCorrection(in: updated))
        XCTAssertEqual(plannedEdit.result.text, rechecked.edit.result.text)
        XCTAssertEqual(plannedEdit.result.text, original + "for actual corrections today.")
        engine.dismiss()
    }

    @MainActor
    func testLearningOptOutStillFirmlyDismissesWithoutSavingWords() {
        let (settings, defaults) = makeSettings()
        settings.learnSpellingPreferences = false
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        XCTAssertTrue(engine.handleEscape())
        for text in ["Check speelling ", "Check speelling today ", "Check speelling today."] {
            engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
            XCTAssertNil(engine.currentSuggestion)
        }
        XCTAssertTrue(AppSettings(defaults: defaults).rememberedSpellings.isEmpty)
        XCTAssertTrue(AppSettings(defaults: defaults).spellingFeedback.isEmpty)
        engine.onTextContextChanged(precedingText: "", bundleId: "test.editor")
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        XCTAssertNotNil(engine.activeAutocorrect, "Clearing the field starts a fresh draft.")
        engine.onTextContextChanged(precedingText: "Different speelling ", bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.misspelledWord, "speelling")
        engine.dismiss()
    }

    @MainActor
    func testContinuingARejectedFragmentCanStillOfferADifferentCorrection() {
        let (settings, _) = makeSettings()
        settings.learnSpellingPreferences = false
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Please speell", bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.misspelledWord, "speell")
        XCTAssertTrue(engine.handleEscape())
        engine.onTextContextChanged(precedingText: "Please speelling ", bundleId: "test.editor")
        XCTAssertEqual(engine.activeAutocorrect?.correctedWord, "spelling ")
        engine.dismiss()
    }

    @MainActor
    func testRoutineCancellationDoesNotLearnAndEscapePassThroughIsHonoured() {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        engine.dismiss()
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        XCTAssertNotNil(engine.activeAutocorrect)
        settings.escapeBehavior = .passToApp
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        XCTAssertFalse(engine.handleEscape())
        XCTAssertNotNil(engine.activeAutocorrect)
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        engine.dismiss()
    }

    @MainActor
    func testEscapePausePoliciesStillLearnFromExplicitWordRejection() {
        for behaviour in [EscapeKeyBehavior.pauseBriefly, .offUntilAppSwitch] {
            let (settings, _) = makeSettings()
            settings.escapeBehavior = behaviour
            let engine = CompletionEngine(settings: settings)
            engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
            XCTAssertTrue(engine.handleEscape())
            XCTAssertTrue(settings.isAppExcluded(bundleIdentifier: "test.editor"))
            XCTAssertTrue(settings.rememberedSpellings.isEmpty)
            XCTAssertEqual(settings.spellingFeedback.values.map(\.word), ["speelling"])
        }
    }

    @MainActor
    func testEmojiAndAbbreviationDismissalsDoNotTeachSpellings() {
        let (settings, _) = makeSettings()
        settings.enableEmojiSuggestions = true
        settings.personalDictionary["navbar"] = "navigation bar"
        let engine = CompletionEngine(settings: settings)
        for text in ["Ship :rocket:", "Make a navbar"] {
            engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
            XCTAssertNotNil(engine.currentSuggestion)
            XCTAssertTrue(engine.handleEscape())
            XCTAssertTrue(settings.rememberedSpellings.isEmpty)
            XCTAssertTrue(settings.spellingFeedback.isEmpty)
            engine.onTextContextChanged(precedingText: text, bundleId: "test.editor", caretMoved: true)
            XCTAssertNil(engine.currentSuggestion)
            engine.onTextContextChanged(precedingText: text, bundleId: "test.editor", force: true)
            XCTAssertNotNil(engine.currentSuggestion, "An explicit new request can restore a dismissed suggestion.")
            engine.dismiss()
        }
    }

    @MainActor
    func testSingleEarlierParagraphWordProvidesFeedbackWithoutLearningSurroundingText() {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "The speelling needs a check.", bundleId: "test.editor")
        XCTAssertEqual(engine.paragraphSpellingSuggestion?.count, 1)
        XCTAssertTrue(engine.handleEscape())
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        XCTAssertEqual(settings.spellingFeedback.values.map(\.word), ["speelling"])
    }

    @MainActor
    func testNativeEscapeKeepsTextAndExplicitParagraphAcceptanceReinforcesCorrections() throws {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        let editor = GhostAwareNSTextView()
        editor.spellingSettings = settings
        editor.string = "Check speelling and reeplacement."
        editor.setSelectedRange(NSRange(location: "Check spee".utf16.count, length: 0))
        let context = TextEditingContext(text: editor.string, selection: editor.selectedRange())
        engine.onTextContextChanged(precedingText: context.precedingText, followingText: context.followingText,
                                    bundleId: "test.editor", caretMoved: true)
        editor.hasInterceptableAction = true
        editor.onEscapeDismiss = { engine.handleEscape() }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        editor.keyDown(with: escape)
        XCTAssertEqual(editor.string, "Check speelling and reeplacement.")
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(editor.performSentenceSpellingCheck())
        XCTAssertEqual(editor.string, "Check spelling and replacement.")
        let key = try XCTUnwrap(SpellingFeedback.key("speelling", correction: "spelling"))
        XCTAssertLessThan(try XCTUnwrap(settings.spellingFeedback[key]?.weight), 0)
        engine.dismiss()
    }

    func testFeedbackDecaysAndOnlyAffectsTheSpecificProposedCorrection() throws {
        let (settings, defaults) = makeSettings()
        let date = Date()
        settings.recordSpellingFeedback([("navbar", "nabber ")], accepted: false, at: date)
        let key = try XCTUnwrap(SpellingFeedback.key("Navbar", correction: "Nabber."))
        let learned = try XCTUnwrap(AppSettings(defaults: defaults).spellingFeedback[key])
        XCTAssertEqual(learned.word, "navbar")
        XCTAssertEqual(learned.weight(at: date), 1)
        XCTAssertFalse(learned.allows(confidence: 0.72, at: date))
        XCTAssertTrue(learned.allows(confidence: 0.72, at: date.addingTimeInterval(7 * 24 * 60 * 60)))
        XCTAssertNil(settings.spellingFeedback[try XCTUnwrap(SpellingFeedback.key("navbar", correction: "nav bar"))])
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
    }

    @MainActor
    func testRepeatedRejectionsAffectAllSpellingPathsButEventuallyFade() throws {
        let (settings, _) = makeSettings()
        for _ in 0..<3 { settings.recordSpellingFeedback([("speelling", "spelling")], accepted: false) }
        let text = "Check speelling."
        let caret = snapshot(text, caret: "Check spee".utf16.count)
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: text, feedback: settings.activeSpellingFeedback))
        XCTAssertNil(SmartWritingFeatures.completedWordCorrection("speelling", feedback: settings.activeSpellingFeedback))
        XCTAssertNil(SentenceSpellingCorrector.wordCorrection(in: caret, feedback: settings.activeSpellingFeedback))
        XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot(text), feedback: settings.activeSpellingFeedback))
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
        XCTAssertNil(engine.currentSuggestion)

        settings.resetSpellingLearning()
        let oldDate = Date().addingTimeInterval(-21 * 24 * 60 * 60)
        for _ in 0..<3 { settings.recordSpellingFeedback([("speelling", "spelling")], accepted: false, at: oldDate) }
        engine.onTextContextChanged(precedingText: text, bundleId: "test.editor")
        XCTAssertNotNil(engine.activeAutocorrect, "Old feedback must not become a permanent ignore list.")
        engine.dismiss()
    }

    @MainActor
    func testConfirmedAcceptanceReversesNegativeFeedbackButPreparingAnEditDoesNotTrain() throws {
        let (settings, _) = makeSettings()
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "test.editor")
        let stale = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        XCTAssertTrue(settings.spellingFeedback.isEmpty)
        engine.dismiss()
        engine.commitAcceptance(stale)
        XCTAssertTrue(settings.spellingFeedback.isEmpty)

        settings.recordSpellingFeedback([("speelling", "spelling")], accepted: false)
        engine.onTextContextChanged(precedingText: "Other speelling ", bundleId: "test.editor")
        let confirmed = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        engine.commitAcceptance(confirmed)
        let key = try XCTUnwrap(SpellingFeedback.key("speelling", correction: "spelling"))
        XCTAssertLessThan(try XCTUnwrap(settings.spellingFeedback[key]?.weight), 0)
        XCTAssertTrue(settings.rememberedSpellings.isEmpty)
    }

    @MainActor
    func testManualWordProtectionIsSeparateFromAdaptiveLearning() throws {
        let (settings, _) = makeSettings()
        settings.rememberSpelling("speelling")
        let editor = GhostAwareNSTextView()
        editor.spellingSettings = settings
        editor.string = "Check speelling and reeplacement."
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(editor.performSentenceSpellingCheck())
        XCTAssertEqual(editor.string, "Check speelling and replacement.")
        settings.resetSpellingLearning()
        XCTAssertEqual(settings.rememberedSpellings, ["speelling"])
        settings.forgetSpelling("speelling")
        XCTAssertNotNil(SmartWritingFeatures.completedWordCorrection("speelling", ignoredWords: settings.rememberedSpellings))
    }
}
