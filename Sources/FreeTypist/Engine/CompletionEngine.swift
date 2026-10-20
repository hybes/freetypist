import Cocoa
import Foundation
import Combine

@MainActor
public final class CompletionEngine: ObservableObject {
    public static let shared = CompletionEngine()

    @Published public var currentSuggestion: CompletionItem?
    @Published public var activeAutocorrect: AutocorrectSuggestion?
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
    private var settingsObserver: AnyCancellable?
    private var modelObserver: AnyCancellable?

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

        // Check Battery "Only on demand" rule
        if SystemResourceMonitor.shared.isOnBatteryPower && settings.batteryOnlyOnDemand && !force {
            dismiss()
            return
        }

        // Check Mid-line completion setting
        let hasSameLineFollowingText: Bool = {
            guard !followingText.isEmpty else { return false }
            let firstLineAfter = followingText.prefix(while: { $0 != "\n" && $0 != "\r" })
            return !firstLineAfter.trimmingCharacters(in: .whitespaces).isEmpty
        }()
        if hasSameLineFollowingText && selectedText.isEmpty && !force {
            let appDisablesMidLine = settings.rule(for: bundleId)?.disableMidLineCompletions ?? false
            if !settings.enableMidLineCompletions || appDisablesMidLine {
                dismiss()
                return
            }
        }

        if !force, selectedText.isEmpty, precedingText == lastRequestedText,
           followingText == lastFollowingText, bundleId == lastBundleId, windowTitle == lastWindowTitle,
           activeTask != nil || currentSuggestion != nil {
            return
        }

        let previousSuggestion = currentSuggestion
        let previousText = lastRequestedText
        let sameEnvironment = lastBundleId == bundleId && lastWindowTitle == windowTitle
            && lastFollowingText == followingText
        dismiss()
        lastLatencyMs = 0
        self.lastAppName = appName
        self.lastBundleId = bundleId
        self.lastDomain = domain
        self.lastWindowTitle = windowTitle
        self.lastFollowingText = followingText
        self.lastRequestedText = precedingText

        if !selectedText.isEmpty {
            onTextSelectionChanged(selectedText: selectedText)
            return
        }

        // Record passive sentence completion for Constant Learning
        learning.recordPassiveTyping(
            text: precedingText,
            appName: appName,
            bundleId: bundleId,
            domain: domain,
            windowTitle: windowTitle
        )

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

        // 2. Check Inline Autocorrect
        let appDisablesAutocorrect = settings.rule(for: bundleId)?.disableAutocorrect ?? false
        if !appDisablesAutocorrect && (settings.hideCompletionsOnSuspectedTypo || settings.showSuggestedTypoFixes) {
            if let typoFix = SmartWritingFeatures.detectAutocorrect(in: precedingText) {
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

        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < settings.minTriggerCharacters && !force {
            dismiss()
            return
        }

        // 3. Optimization: If current suggestion starts with what user just typed, advance it inline in 0ms
        if sameEnvironment, let current = previousSuggestion, current.replacementLength == 0, !force {
            if !previousText.isEmpty && precedingText.hasPrefix(previousText) {
                let typedSuffix = String(precedingText.dropFirst(previousText.count))
                if current.remainingText.hasPrefix(typedSuffix) {
                    let newRemaining = String(current.remainingText.dropFirst(typedSuffix.count))
                    if newRemaining.isEmpty {
                        dismiss()
                    } else {
                        self.currentSuggestion = CompletionItem(
                            fullText: newRemaining,
                            providerName: current.providerName,
                            latencyMs: 0,
                            replacementLength: 0
                        )
                        self.lastRequestedText = precedingText
                    }
                    return
                }
            }
        }

        // Cancel existing pending query
        activeTask?.cancel()
        lastRequestedText = precedingText

        let debounceDelay = force ? 0 : max(0, settings.debounceMs)
        let provider = providerOverride ?? ModelProviderFactory.provider(for: settings.activeProvider)
        let tone = settings.effectiveTone(for: bundleId)
        let customInstructions = settings.effectiveCustomInstructions(for: bundleId)

        let ragSamples = learning.relevantWritingSamples(
            for: precedingText,
            appBundleId: bundleId,
            domain: domain,
            strength: settings.personalizationStrength
        )
        let clipSnippet = PromptBuilder.readSafeClipboardSnippet(enabled: settings.useClipboardContext)
        let deepSummary = DeepContextCollector.shared.buildSynthesizedContextSummary(
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

        if providerOverride == nil, settings.activeProvider == .localEmbedded {
            let started = DispatchTime.now().uptimeNanoseconds
            let instant = PromptBuilder.cleanCompletionText(
                OfflinePredictor().complete(context: context, tone: tone),
                precedingText: precedingText, maxWords: context.maxWords
            )
            if !instant.isEmpty {
                let latency = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                lastLatencyMs = latency
                currentSuggestion = CompletionItem(fullText: instant, providerName: AIProviderType.mock.rawValue, latencyMs: latency)
                stats.recordShown(latencyMs: latency)
            }
        }

        let id = requestID
        activeTask = Task { [weak self] in
            guard let self = self else { return }

            if debounceDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceDelay) * 1_000_000)
            }

            guard !Task.isCancelled, self.requestID == id else { return }

            self.isGenerating = true
            self.lastError = nil

            do {
                let (completionText, latency) = try await provider.complete(context: context, settings: self.settings)

                guard !Task.isCancelled, self.requestID == id else { return }
                self.isGenerating = false
                self.lastLatencyMs = latency

                let cleaned = completionText.trimmingCharacters(in: .newlines)
                if !cleaned.isEmpty {
                    let alreadyShown = self.currentSuggestion?.remainingText == cleaned
                    let source = self.settings.activeProvider == .localEmbedded && latency <= 3
                        ? "Instant Predictor / Local Cache" : self.settings.activeProvider.rawValue
                    self.currentSuggestion = CompletionItem(
                        fullText: cleaned,
                        providerName: source,
                        latencyMs: latency,
                        replacementLength: 0
                    )
                    if !alreadyShown { self.stats.recordShown(latencyMs: latency, fromCache: latency <= 3) }

                    if self.settings.enableWordAlternatives {
                        self.activeWordAlternatives = SmartWritingFeatures.generateWordAlternatives(
                            primarySuggestion: cleaned,
                            precedingText: precedingText,
                            tone: tone
                        )
                    } else {
                        self.activeWordAlternatives = []
                    }
                } else {
                    self.currentSuggestion = nil
                    self.activeWordAlternatives = []
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

    struct PreparedAcceptance {
        fileprivate let requestID: UUID
        let text: String
        let deleteCount: Int
        fileprivate let nextWord: Bool
    }

    func matchesContext(_ context: TextEditingContext, bundleId: String?) -> Bool {
        canAccept && context.selectedText.isEmpty && lastBundleId == bundleId
            && lastRequestedText == context.precedingText && lastFollowingText == context.followingText
    }

    func prepareAcceptance(nextWord: Bool) -> PreparedAcceptance? {
        guard canAccept else { return nil }
        let value: (String, Int)
        var wordOnly = false
        if let slash = activeSlashCommand { value = (slash.expansion, slash.replacementLength) }
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
        return PreparedAcceptance(requestID: requestID, text: value.0, deleteCount: value.1, nextWord: wordOnly)
    }

    /// Statistics and learning are updated only after the target confirms the edit.
    func commitAcceptance(_ acceptance: PreparedAcceptance) {
        guard requestID == acceptance.requestID else { return }
        if acceptance.nextWord { _ = acceptNextWord() }
        else { _ = acceptFull() }
    }

    public func acceptFull() -> (textToInsert: String, deleteBackwardsCount: Int)? {
        guard canAccept else { dismiss(); return nil }
        if let slash = activeSlashCommand {
            stats.recordAccepted(text: slash.expansion, appName: lastAppName, source: "Slash Snippets")
            dismiss()
            return (slash.expansion, slash.replacementLength)
        }

        if let emoji = activeEmojiCandidates.first {
            stats.recordAccepted(text: emoji.emoji, appName: lastAppName, source: "Autocorrect & Emoji")
            dismiss()
            return (emoji.emoji, emoji.replacementLength)
        }

        if let typo = activeAutocorrect {
            stats.recordAccepted(text: typo.correctedWord, appName: lastAppName, source: "Autocorrect & Emoji")
            dismiss()
            return (typo.correctedWord, typo.replacementLength)
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
        return (textToInsert, deleteCount)
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

    public func dismiss() {
        requestID = UUID()
        lastError = nil
        activeTask?.cancel()
        activeTask = nil
        currentSuggestion = nil
        activeAutocorrect = nil
        activeEmojiCandidates = []
        activeWordAlternatives = []
        activeSynonyms = []
        activeSlashCommand = nil
        isGenerating = false
    }
}
