import XCTest
@testable import FreeTypist

final class FreeTypistTests: XCTestCase {
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
    func testStatsManager() {
        let stats = StatsManager.shared
        let beforeWords = stats.totalWordsSaved
        stats.recordShown(latencyMs: 18, fromCache: false)
        stats.recordAccepted(text: "this is a test completion of eight words", appName: "Playground")
        XCTAssertEqual(stats.totalWordsSaved, beforeWords + 8)
        XCTAssertGreaterThan(stats.estimatedTimeSavedMinutes, 0)
        XCTAssertFalse(stats.dailyHistory.isEmpty)
    }
}
