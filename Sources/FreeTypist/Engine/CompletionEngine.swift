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

    private let settings = AppSettings.shared
    private let stats = StatsManager.shared
    private let learning = LearningEngine.shared

    private init() {}

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
        if hasSameLineFollowingText && !force {
            let appDisablesMidLine = settings.rule(for: bundleId)?.disableMidLineCompletions ?? false
            if !settings.enableMidLineCompletions || appDisablesMidLine {
                dismiss()
                return
            }
        }

        self.lastAppName = appName
        self.lastBundleId = bundleId
        self.lastDomain = domain
        self.lastWindowTitle = windowTitle

        // If user selected a word/phrase, check contextual synonyms
        if !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onTextSelectionChanged(selectedText: selectedText)
        } else {
            activeSynonyms = []
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
                    latencyMs: 0
                )
                self.lastRequestedText = precedingText
                return
            } else {
                self.activeSlashCommand = nil
            }
        } else {
            self.activeSlashCommand = nil
        }

        // 1. Check Emoji Shortcodes & Emoticons (Cotypist EmojiCompletionSupport)
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
                latencyMs: 1
            )
            self.lastRequestedText = precedingText
            return
        }

        // 2. Check Inline Autocorrect (Cotypist ServedAutocorrectResolution)
        let appDisablesAutocorrect = settings.rule(for: bundleId)?.disableAutocorrect ?? false
        if !appDisablesAutocorrect && (settings.hideCompletionsOnSuspectedTypo || settings.showSuggestedTypoFixes) {
            if let typoFix = SmartWritingFeatures.detectAutocorrect(in: precedingText) {
                activeTask?.cancel()
                if settings.showSuggestedTypoFixes {
                    self.activeAutocorrect = typoFix
                    self.currentSuggestion = CompletionItem(
                        fullText: typoFix.correctedWord,
                        providerName: "Autocorrect",
                        latencyMs: 1
                    )
                } else {
                    // Hold back completions when typo is suspected
                    dismiss()
                }
                return
            } else {
                self.activeAutocorrect = nil
            }
        } else {
            self.activeAutocorrect = nil
        }

        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < settings.minTriggerCharacters && !force {
            dismiss()
            return
        }

        // 3. Optimization: If current suggestion starts with what user just typed, advance it inline in 0ms
        if let current = currentSuggestion, !force {
            if !lastRequestedText.isEmpty && precedingText.hasPrefix(lastRequestedText) {
                let typedSuffix = String(precedingText.dropFirst(lastRequestedText.count))
                if current.remainingText.hasPrefix(typedSuffix) {
                    let newRemaining = String(current.remainingText.dropFirst(typedSuffix.count))
                    if newRemaining.isEmpty {
                        dismiss()
                    } else {
                        self.currentSuggestion = CompletionItem(
                            fullText: newRemaining,
                            providerName: current.providerName,
                            latencyMs: 0
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

        let debounceDelay = force ? 0 : settings.debounceMs
        let provider = ModelProviderFactory.provider(for: settings.activeProvider)
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

        activeTask = Task { [weak self] in
            guard let self = self else { return }

            if debounceDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceDelay) * 1_000_000)
            }

            guard !Task.isCancelled else { return }

            self.isGenerating = true
            self.lastError = nil

            do {
                let (completionText, latency) = try await provider.complete(context: context, settings: self.settings)

                guard !Task.isCancelled else { return }
                self.isGenerating = false
                self.lastLatencyMs = latency

                let cleaned = completionText.trimmingCharacters(in: .newlines)
                if !cleaned.isEmpty {
                    self.currentSuggestion = CompletionItem(
                        fullText: cleaned,
                        providerName: self.settings.activeProvider.rawValue,
                        latencyMs: latency
                    )
                    self.stats.recordShown(latencyMs: latency, fromCache: latency <= 3)

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
                guard !Task.isCancelled else { return }
                self.isGenerating = false
                self.lastError = error.localizedDescription
                self.currentSuggestion = nil
                self.activeWordAlternatives = []
            }
        }
    }

    public func acceptFull() -> (textToInsert: String, deleteBackwardsCount: Int)? {
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
        stats.recordAccepted(text: textToInsert, appName: lastAppName, source: suggestion.providerName)
        learning.recordAcceptedCompletion(
            precedingText: lastRequestedText,
            acceptedText: textToInsert,
            appName: lastAppName,
            bundleId: lastBundleId,
            domain: lastDomain,
            windowTitle: lastWindowTitle
        )
        if settings.playSoundOnAccept {
            NSSound(named: "Tink")?.play()
        }
        dismiss()
        return (textToInsert, 0)
    }

    public func acceptNextWord() -> String? {
        guard var suggestion = currentSuggestion else { return nil }
        guard var word = suggestion.advanceOneWord() else {
            dismiss()
            return nil
        }

        if !settings.includeTrailingPunctuationOnWordAccept,
           let lastChar = word.last,
           [".", ",", ";", ":", "!", "?"].contains(lastChar),
           word.count > 1 {
            word.removeLast()
        }

        stats.recordAccepted(text: word, appName: lastAppName)
        learning.recordAcceptedCompletion(
            precedingText: lastRequestedText,
            acceptedText: word,
            appName: lastAppName,
            bundleId: lastBundleId,
            domain: lastDomain,
            windowTitle: lastWindowTitle
        )
        lastRequestedText += word

        if suggestion.remainingText.isEmpty {
            dismiss()
        } else {
            self.currentSuggestion = suggestion
        }

        return word
    }

    public func acceptAlternative(at index: Int) -> String? {
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

    public func dismiss() {
        activeTask?.cancel()
        activeTask = nil
        currentSuggestion = nil
        activeAutocorrect = nil
        activeEmojiCandidates = []
        activeWordAlternatives = []
        activeSlashCommand = nil
        isGenerating = false
    }
}
