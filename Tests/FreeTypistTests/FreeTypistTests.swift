import XCTest
@testable import FreeTypist

final class FreeTypistTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let id = UUID().uuidString
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("freetypist-tests-\(id)").path
        setenv("FREETYPIST_DATA_DIRECTORY", path, 1)
        setenv("FREETYPIST_DEFAULTS_SUITE", "com.freetypist.tests.\(id)", 1)
        AppSettings.shared.useClipboardContext = false
        AppSettings.shared.readSurroundingWindowText = false
        AppSettings.shared.trackCrossAppContext = false
        AppSettings.shared.trackMultiClipboardHistory = false
        AppSettings.shared.includeSystemAndUserMetadata = false
    }

    func testCompletionItemWordSplitting() {
        var item = CompletionItem(fullText: " your help with this project!", providerName: "Test", latencyMs: 15)
        XCTAssertEqual(item.remainingText, " your help with this project!")
        XCTAssertEqual(item.nextWord, " your")
        
        let word1 = item.advanceOneWord()
        XCTAssertEqual(word1, " your")
        XCTAssertEqual(item.remainingText, " help with this project!")

        let word2 = item.advanceOneWord()
        XCTAssertEqual(word2, " help")
        XCTAssertEqual(item.remainingText, " with this project!")

        let word3 = item.advanceOneWord()
        XCTAssertEqual(word3, " with")
        XCTAssertEqual(item.remainingText, " this project!")
    }

    func testPromptCleaningAndReasoningStripping() {
        let raw1 = "```swift\nlet x = 10\n```"
        let cleaned1 = PromptBuilder.cleanCompletionText(raw1, precedingText: "test")
        XCTAssertEqual(cleaned1, "let x = 10")

        let raw2 = "\"and have a great day!\""
        let cleaned2 = PromptBuilder.cleanCompletionText(raw2, precedingText: "Thanks, ")
        XCTAssertEqual(cleaned2, "and have a great day!")

        let raw3 = "Sure, here is the continuation: to make sure it works."
        let cleaned3 = PromptBuilder.cleanCompletionText(raw3, precedingText: "we need ")
        XCTAssertEqual(cleaned3, "to make sure it works.")

        let raw4 = " your help and feedback."
        let cleaned4 = PromptBuilder.cleanCompletionText(raw4, precedingText: "Thank you for ")
        XCTAssertEqual(cleaned4, "your help and feedback.")

        // Gemma 4 / Qwen 3 thought blocks
        let raw5 = "<|thought|>Thinking about continuation...<|thought|>your time and consideration."
        let cleaned5 = PromptBuilder.cleanCompletionText(raw5, precedingText: "Thank you for ")
        XCTAssertEqual(cleaned5, "your time and consideration.")

        let raw6 = "<think>\nLet's continue the sentence.\n</think>\nreaching out today!"
        let cleaned6 = PromptBuilder.cleanCompletionText(raw6, precedingText: "Thanks for ")
        XCTAssertEqual(cleaned6, "reaching out today!")

        XCTAssertEqual(PromptBuilder.cleanCompletionText(" we should start now", precedingText: "I think we should "), "start now")
        XCTAssertEqual(PromptBuilder.cleanCompletionText("shoulder muscles", precedingText: "we should "), "shoulder muscles")
    }

    func testSecretSanitizer() {
        let openAISample = "Here is my key sk-proj-1234567890abcdefghijklmnop for testing"
        XCTAssertTrue(SecretSanitizer.containsSecrets(openAISample))
        let (sanitized, redactedTypes) = SecretSanitizer.sanitize(openAISample)
        XCTAssertFalse(sanitized.contains("sk-proj-1234567890abcdefghijklmnop"))
        XCTAssertTrue(sanitized.contains("[REDACTED]"))
        XCTAssertFalse(redactedTypes.isEmpty)

        let safeText = "Looking forward to syncing with the engineering team tomorrow at 10am."
        XCTAssertFalse(SecretSanitizer.containsSecrets(safeText))
        XCTAssertEqual(SecretSanitizer.sanitize(safeText).sanitized, safeText)
    }

    @MainActor
    func testConstantLearningEngine() {
        let engine = LearningEngine.shared
        engine.recordAcceptedCompletion(
            precedingText: "We deployed the ",
            acceptedText: "zero-latency inference pipeline to staging this morning.",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            domain: nil,
            windowTitle: "#engineering"
        )

        let predicted = engine.predictFromLearnedHistory(
            precedingText: "We deployed the ",
            strength: .strong
        )
        XCTAssertNotNil(predicted)
        XCTAssertTrue(predicted?.lowercased().contains("zero-latency") == true || predicted?.isEmpty == false)

        let rag = engine.relevantWritingSamples(
            for: "inference pipeline",
            appBundleId: "com.tinyspeck.slackmacgap",
            domain: nil,
            strength: .balanced
        )
        XCTAssertFalse(rag.isEmpty)
    }

    @MainActor
    func testSmartWritingFeaturesEmojiAndAutocorrect() {
        // Shortcode emoji
        let rocketMatches = SmartWritingFeatures.matchEmoji(
            in: "Deploying now :roc",
            enableShortcodes: true,
            enableEmoticons: true,
            skinTone: .neutral,
            includeNeutralSkinTone: true
        )
        XCTAssertFalse(rocketMatches.isEmpty)
        XCTAssertEqual(rocketMatches.first?.emoji, "🚀")

        // :crylaugh shortcode emoji
        let cryLaughMatches = SmartWritingFeatures.matchEmoji(
            in: "That was hilarious :crylaugh",
            enableShortcodes: true,
            enableEmoticons: false,
            skinTone: .neutral,
            includeNeutralSkinTone: true
        )
        XCTAssertFalse(cryLaughMatches.isEmpty)
        XCTAssertEqual(cryLaughMatches.first?.emoji, "😂")

        // Emoticon emoji
        let smileMatches = SmartWritingFeatures.matchEmoji(
            in: "Sounds great :-)",
            enableShortcodes: true,
            enableEmoticons: true,
            skinTone: .neutral,
            includeNeutralSkinTone: true
        )
        XCTAssertFalse(smileMatches.isEmpty)
        XCTAssertEqual(smileMatches.first?.emoji, "🙂")

        // Inline Autocorrect — classic spelling typo
        let typo = SmartWritingFeatures.detectAutocorrect(in: "I will definately ")
        XCTAssertNotNil(typo)
        XCTAssertEqual(typo?.misspelledWord, "definately")
        XCTAssertEqual(typo?.correctedWord, "definitely ")

        // Inline Autocorrect — extra trailing char ("focuso" -> "focus")
        let focusTypo = SmartWritingFeatures.detectAutocorrect(in: "Let's focuso")
        XCTAssertNotNil(focusTypo)
        XCTAssertEqual(focusTypo?.misspelledWord, "focuso")
        XCTAssertEqual(focusTypo?.correctedWord, "focus")

        // Inline Autocorrect — stuttered prefix ("expeexperience" -> "experience")
        let stutterTypo = SmartWritingFeatures.detectAutocorrect(in: "A nicer user expeexperience")
        XCTAssertNotNil(stutterTypo)
        XCTAssertEqual(stutterTypo?.misspelledWord, "expeexperience")
        XCTAssertEqual(stutterTypo?.correctedWord, "experience")

        // Inline Autocorrect — missing apostrophe contractions
        let imTypo = SmartWritingFeatures.detectAutocorrect(in: "im ")
        XCTAssertNotNil(imTypo)
        XCTAssertEqual(imTypo?.correctedWord, "I'm ")

        let dontTypo = SmartWritingFeatures.detectAutocorrect(in: "Please dont ")
        XCTAssertNotNil(dontTypo)
        XCTAssertEqual(dontTypo?.correctedWord, "don't ")

        // Word Alternatives
        let alts = SmartWritingFeatures.generateWordAlternatives(
            primarySuggestion: "your help and feedback on this!",
            precedingText: "Thank you for ",
            tone: .professional
        )
        XCTAssertGreaterThanOrEqual(alts.count, 2)

        // Contextual Thesaurus
        let synonyms = SmartWritingFeatures.lookupSynonyms(for: "important")
        XCTAssertFalse(synonyms.isEmpty)
        XCTAssertTrue(synonyms.contains(where: { $0.text == "critical" || $0.text == "essential" }))
    }

    @MainActor
    func testMockProviderMatchesPlaygroundPrompt() async throws {
        let provider = MockProvider()
        let settings = AppSettings.shared
        let context = PromptContext(precedingText: "Thank you for ")

        let (text, _) = try await provider.complete(context: context, settings: settings)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testPromptBuilderSystemPrompt() {
        let context = PromptContext(
            precedingText: "Please let me know if",
            appName: "Slack",
            windowTitle: "#product-launch",
            personaDescription: "Concise developer",
            toneInstruction: "Casual",
            learnedSamples: ["Sounds good — let's ship it today."]
        )

        let prompt = PromptBuilder.buildSystemPrompt(context: context)
        XCTAssertTrue(prompt.contains("Slack"))
        XCTAssertTrue(prompt.contains("#product-launch"))
        XCTAssertTrue(prompt.contains("Concise developer"))
        XCTAssertTrue(prompt.contains("Casual"))
    }

    @MainActor
    func testMockProviderCompletion() async throws {
        let provider = MockProvider()
        let settings = AppSettings.shared
        let context = PromptContext(precedingText: "thank you for")

        let (text, latency) = try await provider.complete(context: context, settings: settings)
        XCTAssertFalse(text.isEmpty)
        XCTAssertGreaterThanOrEqual(latency, 0)
    }

    @MainActor
    func testOfflinePredictorNeverReturnsCannedFiller() async throws {
        let provider = MockProvider()
        let settings = AppSettings.shared
        let previousTone = settings.selectedTone
        settings.selectedTone = .concise
        defer { settings.selectedTone = previousTone }

        // Known multi-word prefix should return a real continuation
        let knownContext = PromptContext(precedingText: "In order to ")
        let (knownCompletion, _) = try await provider.complete(context: knownContext, settings: settings)
        XCTAssertFalse(knownCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(knownCompletion.lowercased().contains("for the next check"))

        // Random unmatched phrase should return empty string rather than canned garbage
        let randomContext = PromptContext(precedingText: "zxqv plmk ")
        let (randomCompletion, _) = try await provider.complete(context: randomContext, settings: settings)
        XCTAssertEqual(randomCompletion, "")
    }

    func testGGUFMagicHeaderVerification() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let encryptedFile = tmpDir.appendingPathComponent("fake_encrypted.gguf")
        let validFile = tmpDir.appendingPathComponent("valid_header.gguf")
        defer {
            try? FileManager.default.removeItem(at: encryptedFile)
            try? FileManager.default.removeItem(at: validFile)
        }

        try Data([0x3F, 0x2D, 0x3F, 0x28, 0x00, 0x01, 0x02, 0x03]).write(to: encryptedFile)
        try Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00]).write(to: validFile)

        XCTAssertFalse(LocalModelManager.isValidStandardGGUF(atPath: encryptedFile.path))
        XCTAssertTrue(LocalModelManager.isValidStandardGGUF(atPath: validFile.path))
    }

    @MainActor
    func testCotypistMigratorStatsAndLearningImport() throws {
        let tmpStatsURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cotypist_stats.json")
        defer { try? FileManager.default.removeItem(at: tmpStatsURL) }

        let sampleJSON = """
        {
          "lastMilestoneDate": "2026-10-16",
          "lastMilestoneThreshold": 20,
          "perDay": {
            "2026-10-15": {
              "long": { "characterCount": 42, "completionCount": 3, "wordCountAboveLengthThreshold": 5, "wordCountTotal": 8 },
              "short": { "characterCount": 636, "completionCount": 126, "wordCountAboveLengthThreshold": 110, "wordCountTotal": 126 }
            }
          }
        }
        """
        try sampleJSON.data(using: .utf8)!.write(to: tmpStatsURL)

        let parsed = CotypistMigrator.shared.parseCompletionStatsJSON(at: tmpStatsURL)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.completionsAccepted, 129)
        XCTAssertEqual(parsed.first?.wordsSaved, 134)

        let migRec = WritingHistoryRecord(
            appBundleIdentifier: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            textUpToCursor: "Let's deploy the updated Metal inference build right after standup.",
            wordCount: 10,
            wasAcceptedCompletion: true
        )
        let res = LearningEngine.shared.importMigratedRecords([migRec])
        XCTAssertGreaterThanOrEqual(res.recordsAdded, 0)
    }

    @MainActor
    func testAppExclusion() {
        let settings = AppSettings.shared
        XCTAssertTrue(settings.isAppExcluded(bundleIdentifier: "com.agilebits.onepassword"))
        XCTAssertFalse(settings.isAppExcluded(bundleIdentifier: "com.apple.Safari"))
    }

    @MainActor
    func testLatencyUsesRecordedMeasurementsAndEmptyDaysStayZero() {
        let stats = StatsManager(userDefaults: UserDefaults(suiteName: "com.freetypist.tests.latency.\(UUID().uuidString)")!,
                                 statsFileURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        stats.recordAccepted(text: "test")
        XCTAssertEqual(stats.records(for: .last7Days).last?.avgLatencyMs, 0)
        for latency in [10, 30, 50] { stats.recordShown(latencyMs: latency) }
        XCTAssertEqual(stats.records(for: .last7Days).last?.avgLatencyMs, 30)
        XCTAssertEqual(stats.records(for: .last7Days).first?.avgLatencyMs, 0)
    }

    @MainActor
    func testStatsManager() {
        let stats = StatsManager.shared
        let beforeWords = stats.totalWordsSaved
        stats.recordShown(latencyMs: 18, fromCache: false)
        stats.recordAccepted(text: "this is a test completion of eight words", appName: "Playground")
        XCTAssertEqual(stats.totalWordsSaved, beforeWords + 8)
        XCTAssertGreaterThan(stats.estimatedTimeSavedMinutes, 0)
        XCTAssertFalse(stats.dailyHistory.isEmpty)
    }

    private func freshStats() -> StatsManager {
        let defaults = UserDefaults(suiteName: "com.freetypist.tests.stats.\(UUID().uuidString)")!
        let url = AppStorage.directory.appendingPathComponent("stats-\(UUID().uuidString).json")
        return StatsManager(userDefaults: defaults, statsFileURL: url)
    }

    @MainActor
    private func makeEngine(provider: any ModelProvider = StubProvider()) -> CompletionEngine {
        let settings = AppSettings.shared
        settings.isEnabled = true
        settings.pausedUntilDate = nil
        settings.pausedAppBundleId = nil
        settings.enableSlashCommands = true
        settings.enableEmojiSuggestions = true
        settings.showSuggestedTypoFixes = true
        settings.hideCompletionsOnSuspectedTypo = true
        settings.enableMidLineCompletions = true
        settings.enableContextualSynonyms = true
        settings.includeTrailingSpaceOnWordAccept = true
        settings.includeTrailingPunctuationOnWordAccept = true
        settings.debounceMs = 0
        return CompletionEngine(settings: settings, stats: freshStats(),
                                learning: LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString)),
                                provider: provider)
    }

    func testStatisticsStartEmptyAndProvideNinetyDays() {
        let stats = freshStats()
        XCTAssertEqual(stats.totalWordsSaved, 0)
        XCTAssertEqual(stats.todayWordsSaved, 0)
        XCTAssertEqual(stats.currentStreakDays, 0)
        XCTAssertEqual(stats.dailyAverageWords, 0)
        XCTAssertEqual(stats.acceptanceRatePercentage, 0)
        XCTAssertTrue(stats.dailyHistory.isEmpty)
        XCTAssertEqual(stats.records(for: .last90Days).count, 90)
        XCTAssertTrue(stats.records(for: .last90Days).allSatisfy { $0.wordsSaved == 0 })
        stats.recordAccepted(text: "   ")
        XCTAssertEqual(stats.totalCompletionsAccepted, 0)
    }

    func testStatisticsImportIsIdempotentAcrossRelaunches() {
        let defaults = UserDefaults(suiteName: "com.freetypist.tests.import.\(UUID().uuidString)")!
        let url = AppStorage.directory.appendingPathComponent("stats-\(UUID().uuidString).json")
        let stats = StatsManager(userDefaults: defaults, statsFileURL: url)
        stats.recordAccepted(text: "two words")
        var imported = DayStatsRecord(dateString: StatsManager.currentDayString(), completionsAccepted: 10,
                                      completionsShown: 12, wordsSaved: 100, charactersSaved: 500)
        XCTAssertEqual(stats.importCotypistStats(dailyRecords: [imported]).wordsImported, 100)
        XCTAssertEqual(stats.totalWordsSaved, 102)
        XCTAssertEqual(stats.todayWordsSaved, 102)
        XCTAssertEqual(stats.importCotypistStats(dailyRecords: [imported]).daysImported, 0)
        let reloaded = StatsManager(userDefaults: defaults, statsFileURL: url)
        XCTAssertEqual(reloaded.importCotypistStats(dailyRecords: [imported]).wordsImported, 0)
        imported.wordsSaved += 20
        XCTAssertEqual(reloaded.importCotypistStats(dailyRecords: [imported]).wordsImported, 20)
        XCTAssertEqual(reloaded.totalWordsSaved, 122)
    }

    func testStreakStopsAtCalendarGaps() throws {
        let calendar = Calendar.current
        let yesterday = StatsManager.currentDayString(for: calendar.date(byAdding: .day, value: -1, to: Date())!)
        let threeDaysAgo = StatsManager.currentDayString(for: calendar.date(byAdding: .day, value: -3, to: Date())!)
        let url = AppStorage.directory.appendingPathComponent("streak-\(UUID().uuidString).json")
        try JSONEncoder().encode([DayStatsRecord(dateString: yesterday, wordsSaved: 20),
                                  DayStatsRecord(dateString: threeDaysAgo, wordsSaved: 20)]).write(to: url)
        let stats = StatsManager(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, statsFileURL: url)
        XCTAssertEqual(stats.currentStreakDays, 1)
    }

    func testTextEditingUsesCaretAndPreservesUnicodeAndFollowingText() {
        let before = "👩🏽‍💻 Please dont "
        let text = before + "delete this ending"
        let context = TextEditingContext(text: text, selection: NSRange(location: before.utf16.count, length: 0))
        let result = context.replacingSelection(with: "don't ", deleteBackwardsCount: 5)
        XCTAssertEqual(result.text, "👩🏽‍💻 Please don't delete this ending")
        XCTAssertEqual(result.selection.location, "👩🏽‍💻 Please don't ".utf16.count)
        XCTAssertEqual(context.followingText, "delete this ending")
    }

    func testSynonymReplacementUsesSelectedOccurrence() {
        let text = "good, and good again"
        let context = TextEditingContext(text: text, selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(context.replacingSelection(with: "excellent").text, "excellent, and good again")
    }

    func testEmojiRecognisesClosingColonAndShortExactCodes() {
        for (code, emoji) in [(":rocket:", "🚀"), (":x:", "❌"), (":joy:", "😂")] {
            let matches = SmartWritingFeatures.matchEmoji(in: "Hello " + code, enableShortcodes: true,
                enableEmoticons: false, skinTone: .neutral, includeNeutralSkinTone: true)
            XCTAssertEqual(matches.first?.emoji, emoji, code)
            XCTAssertEqual(matches.first?.replacementLength, code.count)
        }
    }

    @MainActor
    func testAutocorrectDoesNotDeleteWhitespaceAwayFromCaret() {
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "dont  "))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "dont\n"))
        XCTAssertNil(SmartWritingFeatures.detectAutocorrect(in: "cannot "))
        let repeated = SmartWritingFeatures.detectAutocorrect(in: "the  the ")
        XCTAssertEqual(repeated?.replacementLength, 9)
        XCTAssertEqual(repeated?.correctedWord, "the ")
    }

    @MainActor
    func testAbbreviationsReplaceTheTriggerAndRetainSpacing() {
        let engine = makeEngine()
        AppSettings.shared.personalDictionary["lmk"] = "let me know"
        engine.onTextContextChanged(precedingText: "Please LMK  ")
        let accepted = engine.acceptFull()
        XCTAssertEqual(accepted?.textToInsert, "let me know  ")
        XCTAssertEqual(accepted?.deleteBackwardsCount, 5)
        let context = TextEditingContext(text: "Please LMK  ", selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(context.replacingSelection(with: accepted!.textToInsert,
                                                  deleteBackwardsCount: accepted!.deleteBackwardsCount).text,
                       "Please let me know  ")
    }

    @MainActor
    func testReplacementKindsDoNotLeakIntoEachOther() {
        let engine = makeEngine()
        engine.onTextContextChanged(precedingText: "/date")
        XCTAssertNotNil(engine.activeSlashCommand)
        engine.onTextContextChanged(precedingText: "Please dont ")
        XCTAssertNil(engine.activeSlashCommand)
        XCTAssertNotNil(engine.activeAutocorrect)
        engine.onTextContextChanged(precedingText: "Deploy :rocket:")
        XCTAssertNil(engine.activeAutocorrect)
        XCTAssertEqual(engine.activeEmojiCandidates.first?.emoji, "🚀")
        let accepted = engine.acceptFull()
        XCTAssertEqual(accepted?.textToInsert, "🚀")
        XCTAssertEqual(accepted?.deleteBackwardsCount, 8)
        XCTAssertNil(engine.currentSuggestion)
    }

    @MainActor
    func testDelayedCompletionCannotReplaceSnippetOrReappearAfterDismissal() async throws {
        let engine = makeEngine(provider: StubProvider(delay: 0.08))
        engine.onTextContextChanged(precedingText: "Thank you for ", force: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        engine.onTextContextChanged(precedingText: "/date")
        XCTAssertFalse(engine.isGenerating)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(engine.activeSlashCommand)
        XCTAssertTrue(engine.currentSuggestion?.providerName.hasPrefix("Slash") == true)
        engine.onTextContextChanged(precedingText: "Thank you for ", force: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        engine.dismiss()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertFalse(engine.isGenerating)
    }

    @MainActor
    func testEditingClearsOldSuggestionWhileNextRequestIsPending() async throws {
        let engine = makeEngine(provider: StubProvider(delay: 0.03))
        engine.onTextContextChanged(precedingText: "Thank you for ", force: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(engine.currentSuggestion)
        engine.onTextContextChanged(precedingText: "We will meet ", force: true)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(engine.acceptFull())
        engine.dismiss()
    }

    @MainActor
    func testDuplicateEditorCallbacksDoNotCancelInference() async throws {
        let engine = makeEngine(provider: StubProvider(delay: 0.08))
        engine.onTextContextChanged(precedingText: "Thank you for ", force: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(engine.isGenerating)
        engine.onTextContextChanged(precedingText: "Thank you for ")
        XCTAssertTrue(engine.isGenerating)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(engine.currentSuggestion?.remainingText, "your help and feedback.")
        XCTAssertFalse(engine.isGenerating)
    }

    @MainActor
    func testDisablingAppImmediatelyDismissesSuggestion() {
        let engine = makeEngine()
        engine.onTextContextChanged(precedingText: "/date")
        XCTAssertNotNil(engine.currentSuggestion)
        AppSettings.shared.isEnabled = false
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(engine.acceptFull())
        AppSettings.shared.isEnabled = true
    }

    @MainActor
    func testSelectingWordShowsSynonymsWithoutContinuation() {
        let engine = makeEngine()
        engine.onTextContextChanged(precedingText: "This is ", followingText: " work", selectedText: "important")
        XCTAssertFalse(engine.activeSynonyms.isEmpty)
        XCTAssertNil(engine.currentSuggestion)
        engine.dismiss()
        XCTAssertTrue(engine.activeSynonyms.isEmpty)
    }

    @MainActor
    func testWordAcceptanceKeepsWhitespaceConsistent() async throws {
        let engine = makeEngine(provider: StubProvider(text: " your help."))
        engine.onTextContextChanged(precedingText: "Thank you for", force: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(engine.acceptNextWord(), " your ")
        XCTAssertEqual(engine.currentSuggestion?.remainingText, "help.")
        XCTAssertEqual(engine.acceptFull()?.textToInsert, "help.")
    }

    @MainActor
    func testLearningWordAcceptsMergeWithoutDuplicatedText() {
        AppSettings.shared.recordWritingForPersonalization = true
        let engine = LearningEngine(storageURL: AppStorage.directory.appendingPathComponent(UUID().uuidString))
        engine.recordAcceptedCompletion(precedingText: "We will ", acceptedText: "ship ", appName: "Test", bundleId: "test.app")
        engine.recordAcceptedCompletion(precedingText: "We will ship ", acceptedText: "tomorrow.", appName: "Test", bundleId: "test.app")
        XCTAssertEqual(engine.historyRecords.count, 1)
        XCTAssertEqual(engine.historyRecords.first?.textUpToCursor, "We will ")
        XCTAssertEqual(engine.historyRecords.first?.acceptedCompletion, "ship tomorrow.")
        engine.eraseAllHistory()
    }

    @MainActor
    func testErasedLearningStaysEmptyAfterRelaunch() {
        AppSettings.shared.recordWritingForPersonalization = true
        let url = AppStorage.directory.appendingPathComponent(UUID().uuidString)
        let engine = LearningEngine(storageURL: url)
        XCTAssertTrue(engine.historyRecords.isEmpty)
        engine.recordAcceptedCompletion(precedingText: "Special regression ", acceptedText: "vocabularyquux appears here.", appName: "Test", bundleId: "test.app")
        let id = engine.historyRecords[0].id
        engine.deleteRecord(id: id)
        XCTAssertTrue(engine.learnedPhrases.isEmpty)
        XCTAssertTrue(engine.vocabularyCounts.isEmpty)
        engine.eraseAllHistory()
        let reloaded = LearningEngine(storageURL: url)
        XCTAssertTrue(reloaded.historyRecords.isEmpty)
        XCTAssertTrue(reloaded.learnedPhrases.isEmpty)
    }

    @MainActor
    func testContextExclusionsAndToggleAreHonoured() {
        let collector = DeepContextCollector.shared
        AppSettings.shared.trackCrossAppContext = true
        collector.recordCrossAppSnapshot(appName: "Passwords", bundleId: "com.apple.Passwords", windowTitle: "Private", domainOrURL: nil, snippet: "Never record this")
        XCTAssertFalse(collector.crossAppTrail.contains { $0.bundleId == "com.apple.Passwords" })
        collector.recordCrossAppSnapshot(appName: "Test", bundleId: "test.context", windowTitle: "Test", domainOrURL: nil, snippet: "Visible test context")
        XCTAssertTrue(collector.crossAppTrail.contains { $0.bundleId == "test.context" })
        AppSettings.shared.trackCrossAppContext = false
        XCTAssertFalse(collector.buildSynthesizedContextSummary(currentAppName: "Test", currentBundleId: "other.app", activeFieldText: "").contains("Visible test context"))
        collector.clearCrossAppTrail()
    }

    func testCaretRectAllowsDisplaysLeftOfPrimaryScreen() {
        XCTAssertTrue(AccessibilityService.isPlausibleAXRect(CGRect(x: -1200, y: 100, width: 1, height: 18)))
        XCTAssertFalse(AccessibilityService.isPlausibleAXRect(CGRect(x: CGFloat.infinity, y: 100, width: 1, height: 18)))
        XCTAssertFalse(AccessibilityService.isPlausibleAXRect(.zero))
    }

    @MainActor
    func testSelectedModelSurvivesScanningAndRelaunch() throws {
        let directory = AppStorage.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let models = Array(LocalModelInfo.catalog.prefix(2))
        try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]).write(to: directory.appendingPathComponent(models[0].filename))
        let manager = LocalModelManager(models: models, directory: directory)
        manager.selectedModel = models[1]
        manager.scanLocalModels()
        XCTAssertEqual(manager.selectedModel, models[1])
        XCTAssertNil(manager.activeModelPath())
        let reloaded = LocalModelManager(models: models, directory: directory)
        XCTAssertEqual(reloaded.selectedModel, models[1])
        XCTAssertTrue(reloaded.isModelDownloaded(models[0]))
    }

    func testPermissionReadinessRequiresBothAccessibilityAndAnActiveHook() {
        XCTAssertEqual(AccessibilityReadiness(accessGranted: false, hookRunning: false), .needsAccess)
        XCTAssertEqual(AccessibilityReadiness(accessGranted: false, hookRunning: true), .needsAccess)
        XCTAssertEqual(AccessibilityReadiness(accessGranted: true, hookRunning: false), .needsKeyboardHook)
        XCTAssertEqual(AccessibilityReadiness(accessGranted: true, hookRunning: true), .ready)
    }

    @MainActor
    func testLocalModelDefaultsFollowMemoryAndPreserveAnExplicitChoice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for (ram, expectedID) in [(8, "qwen-3.5-0.8b"), (16, "qwen-3.5-2b"), (32, "qwen-3.5-2b"), (64, "qwen-3.5-2b")] {
            let manager = LocalModelManager(directory: AppStorage.directory.appendingPathComponent(UUID().uuidString), defaults: defaults, memoryGB: ram)
            XCTAssertEqual(manager.selectedModel.id, expectedID)
            XCTAssertEqual(manager.recommendedModel.id, expectedID)
        }
        let manager = LocalModelManager(directory: AppStorage.directory.appendingPathComponent(UUID().uuidString), defaults: defaults, memoryGB: 32)
        manager.selectedModel = LocalModelInfo.catalog.first { $0.id == "qwen-3.5-4b" }!
        let reloaded = LocalModelManager(directory: manager.freeTypistModelsDirectory, defaults: defaults, memoryGB: 32)
        XCTAssertEqual(reloaded.selectedModel.id, "qwen-3.5-4b")
    }

    @MainActor
    func testSetupResumesAndOnlyMarksARealOrExplicitlySkippedTypingCheck() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let setup = SetupState(defaults: defaults)
        XCTAssertFalse(setup.isCompleted)
        setup.step = .accessibility
        setup.verifiedModelID = "qwen-3.5-2b"
        let reloaded = SetupState(defaults: defaults)
        XCTAssertEqual(reloaded.step, .accessibility)
        XCTAssertEqual(reloaded.verifiedModelID, "qwen-3.5-2b")
        XCTAssertFalse(reloaded.finish())
        reloaded.didAcceptCompletion = true
        XCTAssertTrue(reloaded.finish())
        XCTAssertTrue(SetupState(defaults: defaults).isCompleted)
        XCTAssertTrue(defaults.bool(forKey: "ft_setupTypingTestPassed"))
        let skippedDefaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertTrue(SetupState(defaults: skippedDefaults).finish(skipTypingTest: true))
        XCTAssertFalse(skippedDefaults.bool(forKey: "ft_setupTypingTestPassed"))
    }

    @MainActor
    func testRelaunchPreservesReviewIsolationWithoutPassingOtherEnvironmentSecrets() {
        let arguments = PermissionManager.relaunchArguments(appURL: URL(fileURLWithPath: "/Applications/FreeTypist.app"), processID: 123,
            environment: ["FREETYPIST_DATA_DIRECTORY": "/tmp/isolated", "FREETYPIST_DEFAULTS_SUITE": "test.suite", "UNRELATED_SECRET": "private"])
        XCTAssertTrue(arguments.contains("FREETYPIST_DATA_DIRECTORY=/tmp/isolated"))
        XCTAssertTrue(arguments.contains("FREETYPIST_DEFAULTS_SUITE=test.suite"))
        XCTAssertTrue(arguments.contains("--wait-for-pid=123"))
        XCTAssertFalse(arguments.joined().contains("private"))
    }

    @MainActor
    func testFreshWritingDefaultsAndExistingPreferencesAreRespected() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.activeProvider, .localEmbedded)
        XCTAssertTrue(settings.enableEmojiSuggestions)
        XCTAssertFalse(settings.useClipboardContext)
        XCTAssertFalse(settings.trackCrossAppContext)
        XCTAssertTrue(settings.paragraphSpellingShortcutEnabled)
        settings.enableEmojiSuggestions = false
        settings.useClipboardContext = true
        settings.paragraphSpellingShortcutEnabled = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.enableEmojiSuggestions)
        XCTAssertTrue(reloaded.useClipboardContext)
        XCTAssertFalse(reloaded.paragraphSpellingShortcutEnabled)
    }

    @MainActor
    func testAcceptanceRequiresCurrentContextAndWaitsForConfirmation() throws {
        let engine = makeEngine()
        engine.onTextContextChanged(precedingText: "Ship :rocket:", followingText: " today", bundleId: "test.editor")
        let matching = TextEditingContext(text: "Ship :rocket: today", selection: NSRange(location: 13, length: 0))
        XCTAssertTrue(engine.matchesContext(matching, bundleId: "test.editor"))
        XCTAssertFalse(engine.matchesContext(matching, bundleId: "other.editor"))
        XCTAssertFalse(engine.matchesContext(TextEditingContext(text: "Changed :rocket: today",
            selection: NSRange(location: 16, length: 0)), bundleId: "test.editor"))
        let prepared = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        XCTAssertEqual(prepared.text, "🚀")
        XCTAssertEqual(prepared.deleteCount, 8)
        XCTAssertNotNil(engine.currentSuggestion)
        engine.commitAcceptance(prepared)
        XCTAssertNil(engine.currentSuggestion)
    }

    @MainActor
    func testAStaleAcceptanceCannotConsumeANewSuggestion() throws {
        let engine = makeEngine()
        engine.onTextContextChanged(precedingText: "Ship :rocket:")
        let prepared = try XCTUnwrap(engine.prepareAcceptance(nextWord: false))
        engine.onTextContextChanged(precedingText: "Please dont ")
        engine.commitAcceptance(prepared)
        XCTAssertEqual(engine.activeAutocorrect?.correctedWord, "don't ")
    }

    @MainActor
    func testSingleWordAcceptanceKeepsDeferredPunctuation() async throws {
        let engine = makeEngine(provider: StubProvider(text: "help."))
        AppSettings.shared.includeTrailingPunctuationOnWordAccept = false
        defer { AppSettings.shared.includeTrailingPunctuationOnWordAccept = true }
        engine.onTextContextChanged(precedingText: "Thank you for your ", force: true)
        try await Task.sleep(for: .milliseconds(40))
        let prepared = try XCTUnwrap(engine.prepareAcceptance(nextWord: true))
        XCTAssertEqual(prepared.text, "help")
        engine.commitAcceptance(prepared)
        XCTAssertEqual(engine.currentSuggestion?.remainingText, ".")
        XCTAssertEqual(engine.acceptFull()?.textToInsert, ".")
    }

    @MainActor
    func testStrictModelCheckCannotPassWithTheBuiltInPredictor() async {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        do {
            _ = try await EmbeddedLocalProvider(allowFallback: false).complete(context: PromptContext(precedingText: "Thank you for "), settings: settings)
            XCTFail("A missing model must not pass setup by returning a predictor result.")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    @MainActor
    func testModelDownloadSuccessAndInvalidFileAndHTTPError() async throws {
        let previousProvider = AppSettings.shared.activeProvider
        AppSettings.shared.activeProvider = .mock
        defer { AppSettings.shared.activeProvider = previousProvider }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        for (path, shouldSucceed) in [("valid", true), ("invalid", false), ("missing", false), ("truncated", false)] {
            let model = LocalModelInfo(id: path, name: path, sizeText: "8 bytes", expectedSizeBytes: path == "truncated" ? 16 : 8,
                filename: path + ".gguf", downloadURLString: "https://freetypist.invalid/" + path, minRAMGigabytes: 0)
            let manager = LocalModelManager(models: [model], directory: AppStorage.directory.appendingPathComponent(UUID().uuidString), sessionConfiguration: configuration)
            manager.startDownload(model: model)
            for _ in 0..<100 {
                if !manager.isDownloading { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(manager.isDownloading, manager.downloadStatusMessage)
            XCTAssertEqual(manager.isModelDownloaded(model), shouldSucceed, manager.downloadStatusMessage)
            if shouldSucceed {
                XCTAssertEqual(manager.selectedModel, model)
                XCTAssertEqual(manager.downloadProgress, 1)
            } else {
                XCTAssertTrue(manager.downloadStatusMessage.lowercased().contains("fail") || manager.downloadStatusMessage.contains("not a valid") || manager.downloadStatusMessage.contains("incomplete"))
            }
        }
    }

    @MainActor
    func testCancellingDownloadDoesNotPublishLateResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let model = LocalModelInfo(id: "cancelled", name: "Cancelled", sizeText: "8 bytes", expectedSizeBytes: 8,
            filename: "cancelled.gguf", downloadURLString: "https://freetypist.invalid/valid", minRAMGigabytes: 0)
        let manager = LocalModelManager(models: [model], directory: AppStorage.directory.appendingPathComponent(UUID().uuidString), sessionConfiguration: configuration)
        manager.startDownload(model: model)
        manager.cancelDownload()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(manager.isDownloading)
        XCTAssertFalse(manager.isModelDownloaded(model))
        XCTAssertEqual(manager.downloadStatusMessage, "Download cancelled.")
    }
}

private struct StubProvider: ModelProvider {
    var text = "your help and feedback."
    var delay: TimeInterval = 0

    func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        if delay > 0 {
            // Deliberately finish after cancellation to exercise stale-result protection.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        return (text, Int(delay * 1000))
    }

    func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        (true, "Test provider", 0)
    }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "freetypist.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = request.url!.lastPathComponent == "missing" ? 404 : 200
        let data = ["valid", "truncated"].contains(request.url!.lastPathComponent)
            ? Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]) : Data("Not a GGUF".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
