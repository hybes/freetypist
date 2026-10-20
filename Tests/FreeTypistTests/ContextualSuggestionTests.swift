import AppKit
import XCTest
@testable import FreeTypist

final class ContextualSuggestionTests: XCTestCase {
    @MainActor
    func testPredictionDelayDoesNotDependOnTypingASpace() {
        XCTAssertEqual(CompletionEngine.predictionDelayMs(configured: 200, force: false), 200)
        XCTAssertEqual(CompletionEngine.predictionDelayMs(configured: 80, force: false), 80)
        XCTAssertEqual(CompletionEngine.predictionDelayMs(configured: 40, force: false), 40)
        XCTAssertEqual(CompletionEngine.predictionDelayMs(configured: -1, force: false), 0)
        XCTAssertEqual(CompletionEngine.predictionDelayMs(configured: 200, force: true), 0)
    }

    private func settings() -> AppSettings {
        let suite = "com.freetypist.tests.context.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.debounceMs = 0
        settings.activeProvider = .mock
        settings.recordWritingForPersonalization = false
        settings.useClipboardContext = false
        settings.enableWordAlternatives = false
        return settings
    }

    private func snapshot(_ text: String, caret: Int? = nil) -> TextInputSnapshot {
        TextInputSnapshot(identity: 42, text: text,
                          selection: NSRange(location: caret ?? text.utf16.count, length: 0))
    }

    @MainActor
    func testValidWordsAndCodeVocabularyAreNotRewritten() {
        for word in ["I", "lets", "wont", "cant", "navbar", "frontend", "useState", "API", "zustand",
                     "prioritize", "finalize", "prioritise", "finalise", "color", "colour"] {
            let text = "The code uses \(word) "
            XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: text), word)
            XCTAssertNil(SentenceSpellingCorrector.correction(in: snapshot(text)), word)
            let range = (text as NSString).range(of: word)
            XCTAssertNil(SentenceSpellingCorrector.wordCorrection(in: snapshot(text, caret: range.location + 1)), word)
        }
        for text in ["I", "I ", "Please im", "Please ive"] {
            XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: text), text)
        }
        XCTAssertEqual(SmartWritingFeatures.detectAutocorrect(in: "im ")?.correctedWord, "I'm ")
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "We should prioritize "))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "Now we can finalize "))
    }

    @MainActor
    func testSentenceContextProtectsUnknownIdentifiersWithoutHidingClearTypos() throws {
        let prose = "This brings hapiness."
        XCTAssertEqual(SentenceSpellingCorrector.correction(in: snapshot(prose))?.edit.result.text,
                       "This brings happiness.")
        let code = "The variable hapiness controls the navbar and needs a replaecment for speelling."
        let correction = try XCTUnwrap(SentenceSpellingCorrector.correction(in: snapshot(code)))
        XCTAssertEqual(correction.count, 2)
        XCTAssertEqual(correction.edit.result.text,
                       "The variable hapiness controls the navbar and needs a replacement for spelling.")
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "The variable hapiness "))
        XCTAssertNil(SentenceSpellingCorrector.wordCorrection(in: snapshot(code, caret: 16)))
        // Cached decisions must not carry a technical-context veto into prose.
        XCTAssertEqual(SentenceSpellingCorrector.correction(in: snapshot(prose))?.edit.result.text,
                       "This brings happiness.")
    }

    func testPredictionsCannotTurnACompletePronounIntoAContraction() {
        for (prefix, output) in [("I", "'m ready"), ("I", "I'm ready"), ("I ", "I'm ready"),
                                  ("we", "’re ready"), ("I think it", "'s ready")] {
            XCTAssertEqual(PromptBuilder.cleanCompletionText(output, precedingText: prefix), "")
        }
        XCTAssertEqual(PromptBuilder.cleanCompletionText("m ready", precedingText: "I'"), "m ready")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("can help", precedingText: "I "), "can help")
    }

    func testModelPrefillKeepsWordTokenBoundariesWithoutChangingUserSpacing() {
        let context = PromptContext(precedingText: "  The navbar needs to ")
        XCTAssertEqual(PromptBuilder.completionMessages(context: context).last?["content"], "  The navbar needs to")
        XCTAssertEqual(PromptBuilder.cleanCompletionText(" be responsive", precedingText: context.precedingText),
                       "be responsive")
        XCTAssertEqual(PromptBuilder.completionMessages(context: PromptContext(precedingText: "The nav")).last?["content"],
                       "The")
        let nextSentence = PromptContext(precedingText: "The code works.")
        XCTAssertEqual(PromptBuilder.completionMessages(context: nextSentence).last?["content"], "The code works.")
        XCTAssertEqual(PromptBuilder.buildSystemPrompt(context: nextSentence),
                       PromptBuilder.buildSystemPrompt(context: PromptContext(precedingText: "The code works")),
                       "A sentence boundary must not invalidate the cached system instructions")
    }

    func testRegeneratingPartialWordsPreservesExactlyWhatTheWriterTyped() throws {
        for (before, generated, expected) in [
            ("We need to improve the perform", " performance of the app.", "We need to improve the performance of the app."),
            ("Can you send me the docum", " document?", "Can you send me the document?"),
            ("Please send the\ndocum", "document.", "Please send the\ndocument."),
            ("Please send the\n\n  docum", "  document.", "Please send the\n\n  document."),
            ("The navbar needs to", " to be responsive.", "The navbar needs to be responsive."),
            ("The navbar needs to ", " be responsive.", "The navbar needs to be responsive."),
            ("I", "I can help.", "I can help."),
            ("I'", "I'm ready.", "I'm ready."),
            ("Le caf", " café est ouvert.", "Le café est ouvert."),
            ("Done.", " We can deploy.", "Done. We can deploy.")
        ] {
            let context = PromptContext(precedingText: before)
            var stream = CompletionStream()
            let event: [String: Any] = ["choices": [["delta": ["content": generated], "finish_reason": "stop"]]]
            try stream.consume("data: " + String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self))
            let suffix = stream.completion(context: context)
            XCTAssertEqual(before + suffix, expected)
            let input = snapshot(before)
            let edit = input.context.replacingSelection(with: suffix, deleteBackwardsCount: 0)
            XCTAssertEqual(edit.text, expected)
        }
    }

    func testRegeneratedPrefixIsNeverDisplayedOrAcceptedAsNewText() throws {
        let context = PromptContext(precedingText: "Check the docum")
        var stream = CompletionStream()
        try stream.consume(#"data: {"choices":[{"delta":{"content":" doc"}}]}"#)
        XCTAssertEqual(stream.completion(context: context), "")
        try stream.consume(#"data: {"choices":[{"delta":{"content":"ument for "}}]}"#)
        XCTAssertEqual(stream.completion(context: context), "ent for ")

        var wrong = CompletionStream()
        try wrong.consume(#"data: {"choices":[{"delta":{"content":" documentation "},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(wrong.completion(context: PromptContext(precedingText: "Check the docux")), "")

        let single = PromptBuilder.completionPrompt(context: PromptContext(precedingText: "I"))
        XCTAssertEqual(single.regeneratedPrefix, "I")
        XCTAssertNotNil(single.grammar)
        XCTAssertFalse(single.grammar!.contains("['’]"), "A complete pronoun must not grow an apostrophe")
    }

    func testNativeModelSuffixKeepsItsBoundaryInsteadOfGuessingFromADictionary() {
        // "perform" is a valid word, so a dictionary-based join previously
        // inserted an extra space before its valid continuation.
        XCTAssertEqual(PromptBuilder.cleanCompletionText("ance", precedingText: "perform",
                                                         preservesWordBoundary: true), "ance")
        XCTAssertEqual(PromptBuilder.cleanCompletionText(" update", precedingText: "the",
                                                         preservesWordBoundary: true), " update")
    }

    @MainActor
    func testEarlierMistakesDoNotBlockNextWordsButReturnAtSentenceEnd() async throws {
        let engine = CompletionEngine(settings: settings(), provider: PredictableProvider())
        for text in ["Check speelling and then ", "Check speelling and reeplacement before we ", "The navbar needs ", "I ",
                     "The navbar needs to", "We need to improve the perform", "Can you send the docum"] {
            engine.onTextContextChanged(precedingText: text, bundleId: "com.freetypist.playground")
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(engine.currentSuggestion?.fullText, "continue writing", text)
            XCTAssertEqual(engine.currentSuggestion?.replacementLength, 0)
            XCTAssertNil(engine.paragraphSpellingSuggestion)
        }
        engine.onTextContextChanged(precedingText: "Check speelling and reeplacement before we finish.",
                                    bundleId: "com.freetypist.playground")
        XCTAssertEqual(engine.paragraphSpellingSuggestion?.count, 2)
        engine.dismiss()
    }

    @MainActor
    func testSentencePredictionsNeedNoSpaceAndReturnStillEndsTheParagraph() async throws {
        let engine = CompletionEngine(settings: settings(), provider: PredictableProvider())
        for (text, shouldPredict) in [("The code works.", true), ("The code works. ", true),
                                      ("The code works.\n", false)] {
            engine.onTextContextChanged(precedingText: text, bundleId: "com.freetypist.playground")
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(engine.currentSuggestion != nil, shouldPredict, text)
        }
        engine.dismiss()
    }

    @MainActor
    func testTypingTheSuggestedWordsStillRequestsAFollowUp() async throws {
        let engine = CompletionEngine(settings: settings(), provider: PredictableProvider())
        engine.onTextContextChanged(precedingText: "We can ", bundleId: "com.freetypist.playground")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.currentSuggestion?.fullText, "continue writing")
        engine.onTextContextChanged(precedingText: "We can continue writing", bundleId: "com.freetypist.playground")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.currentSuggestion?.fullText, "continue writing")
        engine.dismiss()
    }

    func testStreamWaitsForWholeWordsAndPreservesUnicodeAndTruncation() throws {
        let context = PromptContext(precedingText: "Thank you for ")
        var stream = CompletionStream()
        try stream.consume(#"data: {"choices":[{"delta":{"content":"your"}}]}"#)
        XCTAssertEqual(stream.completion(context: context), "")
        try stream.consume(#"data: {"choices":[{"delta":{"content":" help with caf"}}]}"#)
        XCTAssertEqual(stream.completion(context: context).trimmingCharacters(in: .whitespaces), "your help with")
        try stream.consume(#"data: {"choices":[{"delta":{"content":"é."},"finish_reason":"stop"}]}"#)
        XCTAssertTrue(stream.finished)
        XCTAssertEqual(stream.completion(context: context), "your help with café.")
        var cutOff = CompletionStream()
        try cutOff.consume(#"data: {"choices":[{"delta":{"content":"the new comp"},"finish_reason":"length"}]}"#)
        XCTAssertEqual(cutOff.completion(context: context).trimmingCharacters(in: .whitespaces), "the new")
        XCTAssertThrowsError(try cutOff.consume(#"data: {"error":{"message":"failed"}}"#))
        XCTAssertThrowsError(try cutOff.consume("data: {invalid"))
        var number = CompletionStream()
        try number.consume(#"data: {"choices":[{"delta":{"content":"1"}}]}"#)
        XCTAssertEqual(number.completion(context: context), "")
        try number.consume(#"data: {"choices":[{"delta":{"content":"000"}}]}"#)
        XCTAssertEqual(number.completion(context: context), "")
        try number.consume(#"data: {"choices":[{"delta":{"content":" items"}}]}"#)
        XCTAssertEqual(number.completion(context: context).trimmingCharacters(in: .whitespaces), "1000")
    }

    @MainActor
    func testStreamCanBeAcceptedBeforeCompletionAndLateResultsCannotReappear() async throws {
        let engine = CompletionEngine(settings: settings(), provider: SlowStreamingProvider())
        engine.onTextContextChanged(precedingText: "We can ", bundleId: "com.freetypist.playground")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(engine.isGenerating)
        XCTAssertEqual(engine.currentSuggestion?.fullText, "start")
        let acceptance = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        XCTAssertEqual(acceptance.replacement(in: snapshot("We can "))?.result.text, "We can start")
        engine.commitAcceptance(acceptance)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertFalse(engine.isGenerating)
    }

    @MainActor
    func testChangingContextCancelsStreamAndOldWordsDoNotOverwriteCorrections() async throws {
        let engine = CompletionEngine(settings: settings(), provider: SlowStreamingProvider())
        engine.onTextContextChanged(precedingText: "We can ", bundleId: "com.freetypist.playground")
        try await Task.sleep(for: .milliseconds(30))
        engine.onTextContextChanged(precedingText: "Check speelling ", bundleId: "com.freetypist.playground")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(engine.activeAutocorrect?.correctedWord, "spelling ")
        XCTAssertEqual(engine.currentSuggestion?.replacementLength, 10)
        engine.dismiss()
    }
}

private struct PredictableProvider: ModelProvider {
    func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        ("continue writing", 10)
    }
    func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        (true, "", 0)
    }
}

private struct SlowStreamingProvider: ModelProvider {
    func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        ("start now", 150)
    }
    func complete(context: PromptContext, settings: AppSettings,
                  onProgress: @escaping @Sendable (String, Int) async -> Void) async throws -> (text: String, latencyMs: Int) {
        await onProgress("start", 10)
        try? await Task.sleep(for: .milliseconds(150))
        // Deliberately deliver after cancellation to exercise the engine's guard.
        await onProgress("start now", 150)
        return ("start now", 150)
    }
    func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        (true, "", 0)
    }
}
