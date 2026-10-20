import Cocoa
import Foundation
import Combine

@MainActor
public final class CompletionEngine: ObservableObject {
    public static let shared = CompletionEngine()

    @Published public var currentSuggestion: CompletionItem?
    @Published public var activeAutocorrect: AutocorrectSuggestion?
    @Published var paragraphSpellingSuggestion: SentenceSpellingCorrection?
    @Published public var activeEmojiCandidates: [EmojiCandidate] = []
    @Published public var activeWordAlternatives: [WordAlternativeItem] = []
    @Published public var activeSynonyms: [WordAlternativeItem] = []
    @Published public var activeSlashCommand: (trigger: String, expansion: String, replacementLength: Int)?
    @Published public var isGenerating: Bool = false
    @Published public var lastLatencyMs: Int = 0
    @Published public var lastError: String?

    private var activeTask: Task<Void, Never>?
    private var lastRequestedText: String = ""
    private var lastAppName: String = "App"
    private var lastBundleId: String?
    private var lastDomain: String?
    private var lastWindowTitle: String?

    private let settings: AppSettings
    private let stats: StatsManager
    private let learning: LearningEngine
    private let providerOverride: (any ModelProvider)?
    private var requestID = UUID()
    private var lastFollowingText = ""
    private var lastSelectedText = ""
    private var settingsObserver: AnyCancellable?
    private var modelObserver: AnyCancellable?
    private var spellingWordsObserver: AnyCancellable?
    private var spellingResetObserver: AnyCancellable?

    private struct DismissedSuggestion {
        let text: String
        let selection: NSRange
        let bundleId: String?
        let domain: String?
        let windowTitle: String?
        let spellingRanges: [NSRange]
        let singleWord: Bool
    }
    // Session-only rejection context. Never save drafts as spelling preferences.
    private var dismissedSuggestions: [DismissedSuggestion] = []

    init(settings: AppSettings = .shared, stats: StatsManager = .shared,
         learning: LearningEngine = .shared, provider: (any ModelProvider)? = nil) {
        self.settings = settings
        self.stats = stats
        self.learning = learning
        self.providerOverride = provider
        settingsObserver = settings.objectWillChange
            .sink { [weak self] in
                self?.dismiss()
                CompletionLRUCache.shared.clear()
            }
        spellingWordsObserver = settings.$rememberedSpellings.dropFirst().sink { [weak self] _ in
            self?.dismissedSuggestions.removeAll()
        }
        spellingResetObserver = settings.$spellingFeedback.dropFirst().filter(\.isEmpty).sink { [weak self] _ in
            self?.dismissedSuggestions.removeAll()
        }
        modelObserver = LocalModelManager.shared.$selectedModel.dropFirst().sink { [weak self] _ in
            self?.dismiss()
        }
    }

    public func onTextSelectionChanged(selectedText: String) {
        guard settings.isEnabled && settings.enableContextualSynonyms else {
            activeSynonyms = []
            return
        }
        let syns = SmartWritingFeatures.lookupSynonyms(for: selectedText)
        self.activeSynonyms = syns
    }

    public func onTextContextChanged(
        precedingText: String,
        followingText: String = "",
        selectedText: String = "",
        appName: String = "App",
        bundleId: String? = nil,
        domain: String? = nil,
        windowTitle: String? = nil,
        caretMoved: Bool = false,
        force: Bool = false
    ) {
        guard settings.isEnabled else {
            dismiss()
            return
        }

        if settings.isAppExcluded(bundleIdentifier: bundleId) {
            dismiss()
            return
        }

        if !force, !caretMoved, selectedText == lastSelectedText, precedingText == lastRequestedText,
           followingText == lastFollowingText, bundleId == lastBundleId, windowTitle == lastWindowTitle,
           activeTask != nil || currentSuggestion != nil {
            return
        }

        let previousSuggestion = currentSuggestion
        let previousText = lastRequestedText
        let revisitingText = caretMoved || (
            precedingText + selectedText + followingText == lastRequestedText + lastSelectedText + lastFollowingText
            && (precedingText != lastRequestedText || selectedText != lastSelectedText)
        )
        let sameEnvironment = lastBundleId == bundleId && lastWindowTitle == windowTitle
            && lastFollowingText == followingText
        dismiss()
        lastLatencyMs = 0
        self.lastAppName = appName
        self.lastBundleId = bundleId
        self.lastDomain = domain
        self.lastWindowTitle = windowTitle
        self.lastFollowingText = followingText
        self.lastSelectedText = selectedText
        self.lastRequestedText = precedingText

        let fullText = precedingText + selectedText + followingText
        if force || fullText.isEmpty {
            dismissedSuggestions.removeAll(where: isCurrentEnvironment)
        } else if dismissedSuggestions.contains(where: {
            isCurrentEnvironment($0) && $0.text == fullText
                && $0.selection == NSRange(location: precedingText.utf16.count, length: selectedText.utf16.count)
        }) {
            return
        }

        let appDisablesAutocorrect = settings.rule(for: bundleId)?.disableAutocorrect ?? false
        if revisitingText || !selectedText.isEmpty || followingText.first?.isLetter == true {
            if settings.showSuggestedTypoFixes && !appDisablesAutocorrect {
                let snapshot = TextInputSnapshot(identity: 0, text: precedingText + selectedText + followingText,
                    selection: NSRange(location: precedingText.utf16.count, length: selectedText.utf16.count))
                if let edit = SentenceSpellingCorrector.wordCorrection(in: snapshot,
                    ignoredWords: settings.rememberedSpellings,
                    feedback: settings.activeSpellingFeedback,
                    ignoredRanges: dismissedSpellingRanges(in: fullText, singleWordOnly: true)) {
                    let word = (snapshot.text as NSString).substring(with: edit.range)
                    activeAutocorrect = AutocorrectSuggestion(misspelledWord: word, correctedWord: edit.insertion,
                        replacementLength: word.count, replacementRange: edit.range)
                    currentSuggestion = CompletionItem(fullText: edit.insertion, providerName: "Autocorrect",
                                                       replacementLength: word.count)
                    stats.recordShown(latencyMs: 0)
                    return
                }
            }
            if !selectedText.isEmpty { onTextSelectionChanged(selectedText: selectedText) }
            // Clicking in existing text must not extend or correct a fragment of a valid word.
            if !force || !selectedText.isEmpty || followingText.first?.isLetter == true { return }
        }

        // 0. Check Slash Commands & Dynamic Snippets (/date, /time, /clip1, /sig, /lgtm...)
        if settings.enableSlashCommands {
            let clips = DeepContextCollector.shared.clipboardHistory.map(\.text)
            if let slashMatch = SmartWritingFeatures.matchSlashCommand(
                in: precedingText,
                customCommands: settings.slashCommands,
                recentClips: clips
            ) {
                activeTask?.cancel()
                self.activeAutocorrect = nil
                self.activeEmojiCandidates = []
                self.activeSlashCommand = slashMatch
                self.currentSuggestion = CompletionItem(
                    fullText: slashMatch.expansion,
                    providerName: "Slash (\(slashMatch.trigger))",
                    latencyMs: 0,
                    replacementLength: slashMatch.replacementLength
                )
                self.lastRequestedText = precedingText
                stats.recordShown(latencyMs: 0)
                return
            } else {
                self.activeSlashCommand = nil
                if self.currentSuggestion?.providerName.hasPrefix("Slash") == true {
                    self.currentSuggestion = nil
                }
            }
        } else {
            self.activeSlashCommand = nil
        }

        // 1. Check Emoji Shortcodes & Emoticons
        let emojis = SmartWritingFeatures.matchEmoji(
            in: precedingText,
            enableShortcodes: settings.enableEmojiSuggestions,
            enableEmoticons: settings.suggestEmojiFromEmoticons,
            skinTone: settings.preferredEmojiSkinTone,
            includeNeutralSkinTone: settings.includeNeutralEmojiVariant
        )
        self.activeEmojiCandidates = emojis
        if let topEmoji = emojis.first {
            activeTask?.cancel()
            self.activeAutocorrect = nil
            self.currentSuggestion = CompletionItem(
                fullText: topEmoji.emoji,
                providerName: "Emoji (\(topEmoji.shortcode))",
                latencyMs: 1,
                replacementLength: topEmoji.replacementLength
            )
            self.lastRequestedText = precedingText
            stats.recordShown(latencyMs: 1)
            return
        } else if self.currentSuggestion?.providerName.hasPrefix("Emoji") == true {
            self.currentSuggestion = nil
        }

        if let abbreviation = SmartWritingFeatures.matchAbbreviation(in: precedingText, dictionary: settings.personalDictionary) {
            currentSuggestion = CompletionItem(fullText: abbreviation.expansion, providerName: "Abbreviation",
                                               replacementLength: abbreviation.replacementLength)
            stats.recordShown(latencyMs: 0)
            return
        }

        // Spelling is local and does not wait for the AI completion debounce.
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceEnded = trimmed.last.map { ".!?".contains($0) } ?? false
        let atWordBoundary = precedingText.last.map { $0.isWhitespace || ".!?,;:".contains($0) } ?? false
        let inlineCorrection = !appDisablesAutocorrect
            && (settings.hideCompletionsOnSuspectedTypo || settings.showSuggestedTypoFixes)
            ? SmartWritingFeatures.detectAutocorrect(in: precedingText, ignoredWords: settings.rememberedSpellings,
                feedback: settings.activeSpellingFeedback) : nil
        // Earlier mistakes must not monopolise every pause while the user writes
        // the rest of the sentence. Offer the batch at sentence end, or alongside
        // a correction to the word just typed.
        let paragraph = atWordBoundary && (sentenceEnded || inlineCorrection != nil)
            && settings.showSuggestedTypoFixes && !appDisablesAutocorrect
            ? paragraphCorrection(in: TextInputSnapshot(identity: 0,
                text: precedingText + followingText, selection: NSRange(location: precedingText.utf16.count, length: 0)))
            : nil
        if let paragraph, paragraph.count > 1 {
            offerParagraphSpelling(paragraph)
            return
        }

        // 2. Check Inline Autocorrect
        if !appDisablesAutocorrect && (settings.hideCompletionsOnSuspectedTypo || settings.showSuggestedTypoFixes) {
            if let typoFix = inlineCorrection,
               !isDismissedInlineCorrection(typoFix, precedingText: precedingText, fullText: fullText) {
                activeTask?.cancel()
                if settings.showSuggestedTypoFixes {
                    self.activeAutocorrect = typoFix
                    self.currentSuggestion = CompletionItem(
                        fullText: typoFix.correctedWord,
                        providerName: "Autocorrect",
                        latencyMs: 1,
                        replacementLength: typoFix.replacementLength
                    )
                    self.lastRequestedText = precedingText
                    stats.recordShown(latencyMs: 1)
                } else {
                    // Hold back completions when typo is suspected
                    dismiss()
                }
                return
            } else {
                self.activeAutocorrect = nil
                if self.currentSuggestion?.providerName == "Autocorrect" {
                    self.currentSuggestion = nil
                }
            }
        } else {
            self.activeAutocorrect = nil
            if self.currentSuggestion?.providerName == "Autocorrect" {
                self.currentSuggestion = nil
            }
        }

        if let paragraph {
            offerParagraphSpelling(paragraph)
            return
        }

        // Battery and mid-line settings control predictions, not spelling fixes.
        if SystemResourceMonitor.shared.isOnBatteryPower && settings.batteryOnlyOnDemand && !force {
            return
        }
        let hasSameLineFollowingText = !followingText.prefix(while: { !$0.isNewline })
            .trimmingCharacters(in: .whitespaces).isEmpty
        if hasSameLineFollowingText && !force,
           !settings.enableMidLineCompletions || settings.rule(for: bundleId)?.disableMidLineCompletions == true {
            return
        }

        if !force, sentenceEnded,
           precedingText.last?.isWhitespace != true || precedingText.last?.isNewline == true {
            let id = requestID
            let delay = max(0, settings.debounceMs)
            activeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, self.requestID == id else { return }
                learning.recordPassiveTyping(text: precedingText, appName: appName, bundleId: bundleId,
                                             domain: domain, windowTitle: windowTitle)
                activeTask = nil
            }
            return
        }
        if !force, trimmed.isEmpty || precedingText.count < settings.minTriggerCharacters {
            dismiss()
            return
        }

        // 3. Optimization: If current suggestion starts with what user just typed, advance it inline in 0ms
        if sameEnvironment, let current = previousSuggestion, current.replacementLength == 0, !force {
            if !previousText.isEmpty && precedingText.hasPrefix(previousText) {
                let typedSuffix = String(precedingText.dropFirst(previousText.count))
                if current.remainingText.hasPrefix(typedSuffix) {
                    let newRemaining = String(current.remainingText.dropFirst(typedSuffix.count))
                    if !newRemaining.isEmpty {
                        self.currentSuggestion = CompletionItem(
                            fullText: newRemaining,
                            providerName: current.providerName,
                            latencyMs: 0,
                            replacementLength: 0
                        )
                        self.lastRequestedText = precedingText
                        return
                    }
                    // The writer typed the whole suggestion themselves. Request
                    // its continuation instead of stopping until another key.
                }
            }
        }

        // Cancel existing pending query
        activeTask?.cancel()
        lastRequestedText = precedingText

        let debounceDelay = Self.predictionDelayMs(configured: settings.debounceMs,
                                                  atWordBoundary: atWordBoundary, force: force)
        let provider = providerOverride ?? ModelProviderFactory.provider(for: settings.activeProvider)
        let tone = settings.effectiveTone(for: bundleId)
        let customInstructions = settings.effectiveCustomInstructions(for: bundleId)

        let id = requestID
        activeTask = Task { [weak self] in
            guard let self = self else { return }

            if debounceDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceDelay) * 1_000_000)
            }

            guard !Task.isCancelled, self.requestID == id else { return }

            let ragSamples = learning.relevantWritingSamples(
                for: precedingText,
                appBundleId: bundleId,
                domain: domain,
                strength: settings.personalizationStrength
            )
            let isPlayground = bundleId == "com.freetypist.playground"
            let clipSnippet = PromptBuilder.readSafeClipboardSnippet(enabled: !isPlayground && settings.useClipboardContext)
            let deepSummary = isPlayground ? "" : DeepContextCollector.shared.buildSynthesizedContextSummary(
                currentAppName: appName,
                currentBundleId: bundleId,
                activeFieldText: precedingText
            )

            let context = PromptContext(
                precedingText: precedingText,
                followingText: followingText,
                appName: appName,
                bundleIdentifier: bundleId,
                domain: domain,
                windowTitle: settings.useWindowEnvironmentContext ? windowTitle : nil,
                clipboardSnippet: clipSnippet,
                deepContextSummary: deepSummary,
                personaDescription: customInstructions,
                toneInstruction: tone == .custom ? settings.customToneInstructions : tone.promptInstruction,
                dictionary: settings.personalDictionary,
                learnedSamples: ragSamples,
                maxWords: settings.completionLength.maxWords
            )

            learning.recordPassiveTyping(text: precedingText, appName: appName, bundleId: bundleId,
                                         domain: domain, windowTitle: windowTitle)

            self.isGenerating = true
            self.lastError = nil

            do {
                let (completionText, latency) = try await provider.complete(context: context, settings: self.settings) {
                    [weak self] partial, latency in
                    await self?.offerPrediction(partial, latency: latency, request: id)
                }

                guard !Task.isCancelled, self.requestID == id else { return }
                self.isGenerating = false
                offerPrediction(completionText, latency: latency, request: id)
                if settings.enableWordAlternatives, let currentSuggestion {
                    activeWordAlternatives = SmartWritingFeatures.generateWordAlternatives(
                        primarySuggestion: currentSuggestion.remainingText, precedingText: precedingText, tone: tone)
                } else {
                    activeWordAlternatives = []
                }
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.isGenerating = false
                self.lastError = error.localizedDescription
                self.currentSuggestion = nil
                self.activeWordAlternatives = []
            }
        }
    }

    static func predictionDelayMs(configured: Int, atWordBoundary: Bool, force: Bool) -> Int {
        if force { return 0 }
        // A completed word is a useful prediction point. Start promptly after
        // spaces, while retaining the longer pause during a partially typed word.
        return atWordBoundary ? min(max(0, configured), 80) : max(0, configured)
    }

    private func offerPrediction(_ text: String, latency: Int, request: UUID) {
        guard requestID == request, !Task.isCancelled else { return }
        let cleaned = text.trimmingCharacters(in: .newlines)
        guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else {
            currentSuggestion = nil
            return
        }
        let firstOffer = currentSuggestion == nil
        guard currentSuggestion?.remainingText != cleaned else { return }
        let source = settings.activeProvider == .localEmbedded && latency <= 3
            ? "Instant Predictor / Local Cache" : settings.activeProvider.rawValue
        if firstOffer {
            lastLatencyMs = latency
            stats.recordShown(latencyMs: latency, fromCache: latency <= 3)
        }
        currentSuggestion = CompletionItem(fullText: cleaned, providerName: source,
                                          latencyMs: lastLatencyMs, replacementLength: 0)
    }

    struct PreparedAcceptance {
        fileprivate let requestID: UUID
        let text: String
        let deleteCount: Int
        let checksParagraph: Bool
        let replacementRange: NSRange?
        fileprivate let nextWord: Bool
        fileprivate let originalContext: TextEditingContext

        func replacement(in snapshot: TextInputSnapshot) -> TextReplacement? {
            guard snapshot.isValid, snapshot.text == originalContext.text,
                  snapshot.selection == originalContext.selection else { return nil }
            if let replacementRange {
                return TextReplacement(original: snapshot, range: replacementRange, insertion: text)
            }
            return TextReplacement.trailing(text, count: deleteCount, in: snapshot)
        }
    }

    func matchesContext(_ context: TextEditingContext, bundleId: String?) -> Bool {
        canAccept && lastSelectedText == context.selectedText && lastBundleId == bundleId
            && lastRequestedText == context.precedingText && lastFollowingText == context.followingText
    }

    func prepareAcceptance(nextWord: Bool) -> PreparedAcceptance? {
        guard canAccept else { return nil }
        let value: (String, Int)
        var wordOnly = false
        if let paragraph = paragraphSpellingSuggestion { value = (paragraph.trailingInsertion, paragraph.trailingLength) }
        else if let slash = activeSlashCommand { value = (slash.expansion, slash.replacementLength) }
        else if let emoji = activeEmojiCandidates.first { value = (emoji.emoji, emoji.replacementLength) }
        else if let typo = activeAutocorrect { value = (typo.correctedWord, typo.replacementLength) }
        else if let current = currentSuggestion {
            if nextWord && current.replacementLength == 0 {
                guard let word = nextWordParts(current) else { return nil }
                value = (word.accepted, 0)
                wordOnly = true
            } else { value = (current.remainingText, current.replacementLength) }
        } else { return nil }
        guard !value.0.isEmpty else { return nil }
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
        // Invalidate any inference response already on its way back.
        requestID = UUID()
        return PreparedAcceptance(requestID: requestID, text: value.0, deleteCount: value.1,
                                  checksParagraph: paragraphSpellingSuggestion != nil,
                                  replacementRange: activeAutocorrect?.replacementRange, nextWord: wordOnly,
                                  originalContext: TextEditingContext(text: lastRequestedText + lastSelectedText + lastFollowingText,
                                      selection: NSRange(location: lastRequestedText.utf16.count, length: lastSelectedText.utf16.count)))
    }

    private func offerParagraphSpelling(_ correction: SentenceSpellingCorrection) {
        paragraphSpellingSuggestion = correction
        currentSuggestion = CompletionItem(fullText: "Fix \(correction.count) spelling \(correction.count == 1 ? "mistake" : "mistakes") · Tab",
            providerName: "Paragraph spelling", replacementLength: correction.trailingLength)
        isGenerating = false
        stats.recordShown(latencyMs: 0)
    }

    /// Statistics and learning are updated only after the target confirms the edit.
    func commitAcceptance(_ acceptance: PreparedAcceptance) {
        guard requestID == acceptance.requestID else { return }
        if acceptance.nextWord { _ = acceptNextWord() }
        else { _ = acceptFull() }
    }

    public func acceptFull() -> (textToInsert: String, deleteBackwardsCount: Int, replacementRange: NSRange?)? {
        guard canAccept else { dismiss(); return nil }
        if let paragraph = paragraphSpellingSuggestion {
            stats.recordAccepted(text: paragraph.wordEdits.map(\.insertion).joined(separator: " "),
                                 appName: lastAppName, source: "Paragraph spelling")
            settings.recordSpellingFeedback(paragraph.spellingPairs, accepted: true)
            dismiss()
            return (paragraph.trailingInsertion, paragraph.trailingLength, nil)
        }
        if let slash = activeSlashCommand {
            stats.recordAccepted(text: slash.expansion, appName: lastAppName, source: "Slash Snippets")
            dismiss()
            return (slash.expansion, slash.replacementLength, nil)
        }

        if let emoji = activeEmojiCandidates.first {
            stats.recordAccepted(text: emoji.emoji, appName: lastAppName, source: "Autocorrect & Emoji")
            dismiss()
            return (emoji.emoji, emoji.replacementLength, nil)
        }

        if let typo = activeAutocorrect {
            stats.recordAccepted(text: typo.correctedWord, appName: lastAppName, source: "Autocorrect & Emoji")
            settings.recordSpellingFeedback([(typo.misspelledWord, typo.correctedWord)], accepted: true)
            dismiss()
            return (typo.correctedWord, typo.replacementLength, typo.replacementRange)
        }

        guard let suggestion = currentSuggestion else { return nil }
        let textToInsert = suggestion.remainingText
        let deleteCount = suggestion.replacementLength
        stats.recordAccepted(text: textToInsert, appName: lastAppName, source: suggestion.providerName)
        if deleteCount == 0 {
            learning.recordAcceptedCompletion(
                precedingText: lastRequestedText,
                acceptedText: textToInsert,
                appName: lastAppName,
                bundleId: lastBundleId,
                domain: lastDomain,
                windowTitle: lastWindowTitle
            )
        }
        if settings.playSoundOnAccept {
            NSSound(named: "Tink")?.play()
        }
        dismiss()
        return (textToInsert, deleteCount, nil)
    }

    public func acceptNextWord() -> String? {
        guard canAccept, let current = currentSuggestion, current.replacementLength == 0 else { return nil }
        activeTask?.cancel()
        activeTask = nil
        requestID = UUID()
        isGenerating = false
        let suggestion = current
        guard let parts = nextWordParts(current) else {
            dismiss()
            return nil
        }
        let word = parts.accepted
        let remaining = parts.remaining
        stats.recordAccepted(text: word, appName: lastAppName, source: suggestion.providerName)
        learning.recordAcceptedCompletion(
            precedingText: lastRequestedText,
            acceptedText: word,
            appName: lastAppName,
            bundleId: lastBundleId,
            domain: lastDomain,
            windowTitle: lastWindowTitle
        )
        lastRequestedText += word

        activeWordAlternatives = []
        if remaining.isEmpty {
            dismiss()
        } else {
            self.currentSuggestion = CompletionItem(fullText: remaining, providerName: suggestion.providerName, latencyMs: suggestion.latencyMs)
        }

        return word
    }

    private func nextWordParts(_ current: CompletionItem) -> (accepted: String, remaining: String)? {
        var suggestion = current
        guard var word = suggestion.advanceOneWord() else { return nil }
        var remaining = suggestion.remainingText
        if !settings.includeTrailingPunctuationOnWordAccept,
           let last = word.last, [".", ",", ";", ":", "!", "?"].contains(last), word.count > 1 {
            word.removeLast()
            // Keep punctuation for a subsequent acceptance instead of losing it.
            remaining = String(last) + remaining
        } else if settings.includeTrailingSpaceOnWordAccept {
            let spacing = String(remaining.prefix(while: \.isWhitespace))
            word += spacing
            remaining = String(remaining.dropFirst(spacing.count))
        }
        return (word, remaining)
    }

    public func acceptAlternative(at index: Int) -> String? {
        guard canAccept, currentSuggestion?.replacementLength == 0 else { return nil }
        if let alt = activeWordAlternatives.first(where: { $0.index == index }) {
            stats.recordAccepted(text: alt.text, appName: lastAppName)
            learning.recordAcceptedCompletion(
                precedingText: lastRequestedText,
                acceptedText: alt.text,
                appName: lastAppName,
                bundleId: lastBundleId,
                domain: lastDomain
            )
            dismiss()
            return alt.text
        }
        return nil
    }

    private var canAccept: Bool {
        settings.isEnabled && !settings.isAppExcluded(bundleIdentifier: lastBundleId)
    }

    func paragraphCorrection(in snapshot: TextInputSnapshot) -> SentenceSpellingCorrection? {
        SentenceSpellingCorrector.correction(in: snapshot, ignoredWords: settings.rememberedSpellings,
            feedback: settings.activeSpellingFeedback,
            ignoredRanges: dismissedSpellingRanges(in: snapshot.text))
    }

    private func isCurrentEnvironment(_ rejection: DismissedSuggestion) -> Bool {
        rejection.bundleId == lastBundleId && rejection.domain == lastDomain && rejection.windowTitle == lastWindowTitle
    }

    private func dismissedSpellingRanges(in text: String, singleWordOnly: Bool = false) -> [NSRange] {
        dismissedSuggestions.filter { isCurrentEnvironment($0) && (!singleWordOnly || $0.singleWord) }
            .flatMap { rejection in
                rejection.spellingRanges.filter { range in
                    // An unchanged prefix anchors the same occurrence as the user
                    // continues typing. Editing that word makes it eligible again.
                    guard NSMaxRange(range) <= rejection.text.utf16.count else { return false }
                    let prefix = (rejection.text as NSString).substring(to: NSMaxRange(range))
                    guard text.hasPrefix(prefix) else { return false }
                    // "im" growing into "immediatly" is a new word to assess,
                    // not the rejected contraction appearing again.
                    return !(prefix.last?.isLetter == true && text.dropFirst(prefix.count).first?.isLetter == true)
                }
            }
    }

    private func isDismissedInlineCorrection(_ correction: AutocorrectSuggestion,
                                             precedingText: String, fullText: String) -> Bool {
        let length = String(precedingText.suffix(correction.replacementLength)).utf16.count
        let range = NSRange(location: precedingText.utf16.count - length, length: length)
        return dismissedSpellingRanges(in: fullText).contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// Called only for an explicit dismissal, never for typing, focus changes or cancellation.
    @discardableResult
    func rejectCurrentSuggestion() -> Bool {
        guard canAccept, currentSuggestion != nil || !activeSynonyms.isEmpty else { return false }
        let text = lastRequestedText + lastSelectedText + lastFollowingText
        let selection = NSRange(location: lastRequestedText.utf16.count, length: lastSelectedText.utf16.count)
        var ranges: [NSRange] = []
        var word: String?
        var correction: String?
        if let typo = activeAutocorrect {
            let removedLength = String(lastRequestedText.suffix(typo.replacementLength)).utf16.count
            ranges = [typo.replacementRange ?? NSRange(location: selection.location - removedLength,
                                                     length: removedLength)]
            word = typo.misspelledWord
            correction = typo.correctedWord
        } else if let paragraph = paragraphSpellingSuggestion {
            ranges = paragraph.wordEdits.map(\.range)
            if ranges.count == 1, let range = ranges.first {
                word = (text as NSString).substring(with: range)
                correction = paragraph.wordEdits.first?.insertion
            }
        }
        let rejection = DismissedSuggestion(text: text, selection: selection, bundleId: lastBundleId,
            domain: lastDomain, windowTitle: lastWindowTitle, spellingRanges: ranges, singleWord: word != nil)
        // Only a single, explicit choice is evidence about a spelling. A batch
        // dismissal can mean "not now" and must not train on all its words.
        if let word, let correction {
            settings.recordSpellingFeedback([(word, correction)], accepted: false)
        }
        dismiss()
        dismissedSuggestions.append(rejection)
        if dismissedSuggestions.count > 16 { dismissedSuggestions.removeFirst() }
        return true
    }

    @discardableResult
    func handleEscape() -> Bool {
        guard settings.escapeBehavior != .passToApp, rejectCurrentSuggestion() else { return false }
        switch settings.escapeBehavior {
        case .pauseBriefly: settings.pausedUntilDate = Date().addingTimeInterval(15)
        case .offUntilAppSwitch: settings.pausedAppBundleId = lastBundleId
        case .dismissThenPassToApp, .passToApp: break
        }
        return true
    }

    public func dismiss() {
        requestID = UUID()
        lastError = nil
        activeTask?.cancel()
        activeTask = nil
        currentSuggestion = nil
        activeAutocorrect = nil
        paragraphSpellingSuggestion = nil
        activeEmojiCandidates = []
        activeWordAlternatives = []
        activeSynonyms = []
        activeSlashCommand = nil
        isGenerating = false
    }
}
