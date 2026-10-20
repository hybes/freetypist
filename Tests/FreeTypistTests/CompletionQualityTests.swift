import XCTest
@testable import FreeTypist

final class CompletionQualityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let id = UUID().uuidString
        setenv("FREETYPIST_DATA_DIRECTORY", "/tmp/freetypist-quality-tests-\(id)", 1)
        setenv("FREETYPIST_DEFAULTS_SUITE", "com.freetypist.quality.\(id)", 1)
    }

    func testRejectsOldSentenceEchoesAndPreservesWordBoundaries() {
        let prefix = "Thank you for giving me the screenshot. We should make a way"
        XCTAssertEqual(PromptBuilder.cleanCompletionText("Thank you for giving me", precedingText: prefix), "")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("make a way make a way", precedingText: prefix), "")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("Thank you", precedingText: "Done."), " Thank you")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("can help", precedingText: "I"), " can help")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("I hope", precedingText: "as"), " I hope")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("tion", precedingText: "We need configura"), "tion")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("your help. Your help means a lot.", precedingText: "Thanks for "), "your help.")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("your help with this proj", precedingText: "Thanks for ",
                                                       maxWords: 7, truncated: true).trimmingCharacters(in: .whitespaces),
                       "your help with this")
    }

    func testPromptDoesNotTreatShortcutsOrUnrelatedWindowsAsThingsToWrite() {
        let context = PromptContext(precedingText: "Thank you for ", appName: "TextEdit",
                                    deepContextSummary: "T3 Code (Nightly): disable Cotypist and enable FreeTypist",
                                    dictionary: ["btw": "by the way", "eod": "by the end of the day"])
        XCTAssertFalse(PromptBuilder.buildSystemPrompt(context: context).contains("btw"))
        XCTAssertFalse(PromptBuilder.buildUserPrompt(context: context).contains("Cotypist"))
    }

    @MainActor
    func testInlineCorrectionsForReportedRepeatedKeystrokesAndPunctuation() {
        for (wrong, right) in [("outsiide", "outside"), ("playgroundnd", "playground"),
                               ("correcetions", "corrections"), ("reeplacement", "replacement"),
                               ("aactual", "actual"), ("speelling", "spelling"), ("sentencee", "sentence")] {
            for suffix in ["", " ", ", ", "."] {
                let result = SmartWritingFeatures.detectAutocorrect(in: "Please check \(wrong)\(suffix)")
                XCTAssertEqual(result?.correctedWord, right + suffix, wrong + suffix)
                XCTAssertEqual(result?.replacementLength, wrong.count + suffix.count, wrong + suffix)
            }
        }
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "https://example.com/outsiide"))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "configuration"))
    }

    @MainActor
    func testCorrectionDoesNotWaitForModelDebounce() {
        let defaults = UserDefaults(suiteName: "com.freetypist.quality.debounce.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.debounceMs = 1_000
        settings.showSuggestedTypoFixes = true
        settings.isEnabled = true
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Please check the correcetions, ",
                                    appName: "TextEdit", bundleId: "com.apple.TextEdit")
        XCTAssertEqual(engine.activeAutocorrect?.correctedWord, "corrections, ")
        XCTAssertFalse(engine.isGenerating)
        engine.dismiss()
    }

    @MainActor
    func testEarlierMistakesAreOfferedTogetherAtSentenceEndAndWordBoundary() async throws {
        let defaults = UserDefaults(suiteName: "com.freetypist.quality.paragraph.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.debounceMs = 0
        let engine = CompletionEngine(settings: settings)
        for ending in [".", " "] {
            let text = "👩🏽‍💻 Check aactual reeplacement and speelling in this sentencee please\(ending)"
            engine.onTextContextChanged(precedingText: text, appName: "TextEdit", bundleId: "com.apple.TextEdit")
            try await Task.sleep(for: .milliseconds(30))
            let correction = try XCTUnwrap(engine.paragraphSpellingSuggestion)
            XCTAssertEqual(correction.count, 4)
            let accepted = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
            XCTAssertTrue(accepted.checksParagraph)
            let context = TextEditingContext(text: text, selection: NSRange(location: text.utf16.count, length: 0))
            let updated = context.replacingSelection(with: accepted.text, deleteBackwardsCount: accepted.deleteCount)
            XCTAssertEqual(updated.text, "👩🏽‍💻 Check actual replacement and spelling in this sentence please\(ending)")
            XCTAssertEqual(updated.selection.location, updated.text.utf16.count)
            engine.commitAcceptance(accepted)
            XCTAssertNil(engine.paragraphSpellingSuggestion)
        }
    }

    @MainActor
    func testParagraphOfferHonoursAutocorrectSettingAndCancelsWithChangedDraft() async throws {
        let defaults = UserDefaults(suiteName: "com.freetypist.quality.paragraph-cancel.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.debounceMs = 20
        settings.showSuggestedTypoFixes = false
        let engine = CompletionEngine(settings: settings)
        engine.onTextContextChanged(precedingText: "Check speelling please.", bundleId: "test.editor")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(engine.paragraphSpellingSuggestion)
        settings.showSuggestedTypoFixes = true
        engine.onTextContextChanged(precedingText: "Check speelling please.", bundleId: "test.editor")
        engine.onTextContextChanged(precedingText: "A new correct sentence.", bundleId: "test.editor")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(engine.paragraphSpellingSuggestion)
        XCTAssertNil(engine.currentSuggestion)
        engine.dismiss()
    }

    @MainActor
    func testSentenceEndStillRecordsWritingWithoutRequestingAnotherSentence() async throws {
        let settings = AppSettings.shared
        settings.isEnabled = true
        settings.recordWritingForPersonalization = true
        settings.recordUnacceptedWriting = true
        settings.debounceMs = 0
        let learning = LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        let engine = CompletionEngine(settings: settings, learning: learning)
        engine.onTextContextChanged(precedingText: "We can finish the project tomorrow.",
                                    appName: "TextEdit", bundleId: "com.apple.TextEdit")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(learning.historyRecords.count, 1)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertFalse(engine.isGenerating)
        engine.dismiss()
    }
    @MainActor
    func testPlaygroundDoesNotTrainOnItsOwnAcceptedOutput() {
        let learning = LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        AppSettings.shared.recordWritingForPersonalization = true
        AppSettings.shared.recordUnacceptedWriting = true
        learning.recordAcceptedCompletion(precedingText: "Thank you for ",
                                          acceptedText: "giving me the screenshot of all the apps.",
                                          appName: "FreeTypist Playground", bundleId: "com.freetypist.playground")
        learning.recordPassiveTyping(text: "Thank you for giving me the screenshot of all the apps.",
                                     appName: "FreeTypist Playground", bundleId: "com.freetypist.playground")
        XCTAssertTrue(learning.historyRecords.isEmpty)
        XCTAssertNil(learning.predictFromLearnedHistory(precedingText: "Thank you for ", strength: .strong))
    }

    @MainActor
    func testUnrelatedHistoryIsNotUsedAsWritingContext() {
        let learning = LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        learning.trainOnCustomCorpus("We should maybe see if Cotypist is enabled and disable the other app.")
        XCTAssertTrue(learning.relevantWritingSamples(for: "Thank you for ", appBundleId: "com.freetypist.playground",
                                                      domain: nil, strength: .strong).isEmpty)
    }

    @MainActor
    func testRealModelRepeatedAcceptance() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FREETYPIST_QA_MODEL"] else {
            throw XCTSkip("Set FREETYPIST_QA_MODEL to run the actual local model.")
        }
        let settings = AppSettings.shared
        settings.activeProvider = .localEmbedded
        settings.personalizationStrength = .strong
        settings.readSurroundingWindowText = false
        settings.trackCrossAppContext = false
        settings.useClipboardContext = false
        settings.includeSystemAndUserMetadata = false
        settings.debounceMs = 140
        settings.completionLength = .long
        settings.batteryOnlyOnDemand = false
        settings.isEnabled = true
        let service = LocalInferenceService.shared
        service.serverPort = 58866
        service.startServer(for: modelPath)
        defer { service.stopServer() }
        for _ in 0..<600 {
            if service.isServerRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(service.isServerRunning, service.serverStatus)
        guard service.isServerRunning else { return }
        // Seed the kind of unrelated history shown in the report, without reading user data.
        let learning = LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        learning.trainOnCustomCorpus("We should maybe see if Cotypist is enabled and disable the other app.")
        for seed in ["Thank you for ", "I think we should ", "The replacement now works "] {
            let engine = CompletionEngine(settings: settings, learning: learning,
                                          provider: EmbeddedLocalProvider(allowFallback: false))
            var text = seed
            var acceptedCount = 0
            for step in 0..<6 {
                let start = Date()
                engine.onTextContextChanged(precedingText: text, appName: "FreeTypist Playground",
                                            bundleId: "com.freetypist.playground", force: false)
                for _ in 0..<200 {
                    if engine.currentSuggestion != nil { break }
                    if Date().timeIntervalSince(start) > 0.3 && !engine.isGenerating { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard let suggestion = engine.currentSuggestion else { break }
                XCTAssertEqual(suggestion.replacementLength, 0, "A model completion must not be recorrected: \(text)")
                XCTAssertFalse(suggestion.fullText.lowercased().contains("cotypist"))
                XCTAssertFalse(suggestion.fullText.lowercased().contains("screenshot"))
                for shortcut in ["btw", "fyi", "lmk", "eod", "tl;dr", "wfh"] {
                    XCTAssertFalse(suggestion.fullText.contains(shortcut), "Shortcut list leaked into generated text")
                }
                if step == 0 && seed == "Thank you for " {
                    XCTAssertFalse(suggestion.fullText.trimmingCharacters(in: .whitespaces).hasPrefix("I "),
                                   "The model replied rather than completing the sentence")
                }
                let input = TextEditingContext(text: text, selection: NSRange(location: text.utf16.count, length: 0))
                XCTAssertTrue(engine.matchesContext(input, bundleId: "com.freetypist.playground"))
                let accepted = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
                let updated = input.replacingSelection(with: accepted.text, deleteBackwardsCount: accepted.deleteCount)
                engine.commitAcceptance(accepted)
                text = updated.text
                acceptedCount += 1
                print("REAL MODEL step \(step + 1): \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms; \(text)")
            }
            XCTAssertGreaterThan(acceptedCount, 0, "No completion for \(seed)")
            engine.dismiss()
        }
    }
}
