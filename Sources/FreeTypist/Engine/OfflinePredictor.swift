import AppKit
import Foundation

/// High-speed local phrase & N-gram completer integrated with LearningEngine and macOS NSSpellChecker.
/// Used for instant <2ms predictions when a high-confidence match exists. Never returns generic filler.
public struct OfflinePredictor: Sendable {
    public init() {}

    public static func isLikelyPartialWordContinuation(stem: String, continuation: String) -> Bool {
        let lowerStem = stem.lowercased()
        let firstContWord = String(continuation.split(whereSeparator: \.isWhitespace).first ?? "").trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard !lowerStem.isEmpty && !firstContWord.isEmpty else { return false }
        let combined = lowerStem + firstContWord
        if lexiconSet.contains(combined) { return true }
        let checker = NSSpellChecker.shared
        // Do not merge two complete words because a proper-name dictionary happens
        // to accept their concatenation (for example "as" + "I" -> "asI").
        if checker.checkSpelling(of: lowerStem, startingAt: 0, language: "en_GB",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound { return false }
        let range = checker.checkSpelling(of: combined, startingAt: 0, language: "en_GB",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    public func complete(context: PromptContext, tone: TonePreset) -> String {
        let preceding = context.precedingText
        let trimmed = preceding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Do not autocomplete if the user is typing a shortcode (:...), slash command (/...), @mention, or URL
        if let lastToken = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last {
            let tok = String(lastToken)
            if tok.hasPrefix(":") || tok.hasPrefix("/") || tok.hasPrefix("@") || tok.hasPrefix("#") || tok.contains("://") {
                return ""
            }
        }

        // 2. Constant Learning Engine (Personalization Booster N-grams & Vocabulary from user's own history)
        if let learned = LearningEngine.shared.predictFromLearnedHistory(
            precedingText: preceding,
            strength: AppSettings.shared.personalizationStrength
        ) {
            return learned
        }

        // 3. Deep On-Device Context Match (Window Thread, Cross-App Trail & Clipboard Entities)
        if let contextual = deepContextMatch(preceding: preceding, trimmed: trimmed, context: context) {
            return contextual
        }

        // 4. High-Confidence Multi-Word Phrase Match
        if let phrase = longestPhraseMatch(in: trimmed, avoiding: preceding) {
            return spaced(phrase, after: preceding)
        }

        // 5. Partial Word Completion (lexicon + macOS NSSpellChecker for mid-word typing)
        if let partial = completePartialWord(preceding) {
            return partial
        }

        return ""
    }

    private func deepContextMatch(preceding: String, trimmed: String, context: PromptContext) -> String? {
        let combinedContext = [context.deepContextSummary, context.clipboardSnippet ?? "", context.windowTitle ?? ""].joined(separator: "\n")
        guard !combinedContext.isEmpty else { return nil }

        let lowerTrimmed = trimmed.lowercased()

        // A. Direct URL / Link completion from Clipboard or Active Window
        if lowerTrimmed.hasSuffix("here is the link") ||
           lowerTrimmed.hasSuffix("check out the link") ||
           lowerTrimmed.hasSuffix("see the pr at") ||
           lowerTrimmed.hasSuffix("the url is") {
            if let urlRange = combinedContext.range(of: "https?://[^\\s|\\]]+", options: .regularExpression) {
                let url = String(combinedContext[urlRange])
                if !preceding.contains(url) {
                    return spaced(": \(url)", after: preceding)
                }
            }
        }

        return nil
    }

    // MARK: - High-Confidence Natural Phrase Bank

    private let phrases: [(trigger: String, completion: String)] = [
        ("thank you for", "your help and feedback."),
        ("thanks for", "reaching out! Let me know if you need anything else."),
        ("thanks so much for", "taking the time to review this."),
        ("let me know if", "you have any questions or thoughts."),
        ("let me know what", "you think when you have a moment."),
        ("let me know when", "you are free for a quick sync."),
        ("please let me know if", "you would like me to adjust anything."),
        ("looking forward to", "hearing from you soon."),
        ("i hope you are", "having a great week."),
        ("hope you're having", "a great week so far."),
        ("please find attached", "the updated document."),
        ("as discussed", "earlier today,"),
        ("feel free to", "reach out if you need any additional context."),
        ("just wanted to follow", "up on our previous conversation."),
        ("just wanted to check", "in and see how things are progressing."),
        ("just following up on", "my previous message."),
        ("just following up on our call about", "the remaining action items."),
        ("sounds good to", "me, let's do that."),
        ("sounds like a", "great plan to me."),
        ("let's schedule a", "quick call to sync on this."),
        ("let's make sure", "everything is tested and ready to go."),
        ("let's focus on", "making the user experience clean and reliable."),
        ("focus on", "getting the core experience right."),
        ("making sure", "everything works smoothly end to end."),
        ("make sure", "we test all edge cases before shipping."),
        ("could you please", "take a look when you have a moment?"),
        ("could you please review the", "latest changes when you get a chance?"),
        ("can you please", "send over the latest update when ready?"),
        ("can we", "sync briefly on this tomorrow?"),
        ("in order to", "keep everything on track,"),
        ("in order to achieve the best results,", "we should keep the scope focused and iterate quickly."),
        ("don't hesitate to", "reach out if anything is unclear."),
        ("best regards,", "\nThanks"),
        ("have a great", "rest of your day!"),
        ("how are", "things looking on your end?"),
        ("i am writing to update you regarding", "the current status and next steps."),
        ("i think we should", "prioritize simplicity and reliability first."),
        ("i think", "that makes a lot of sense."),
        ("we should", "be able to wrap this up today."),
        ("we need to", "make sure the implementation is clean and fast."),
        ("i'm working on", "finishing up the remaining changes now."),
        ("working on", "the latest improvements right now."),
        ("i'll send", "over the updated version shortly."),
        ("sorry for the", "delay in getting back to you."),
        ("apologies for the", "late reply on this."),
        ("the issue is", "resolved in the latest build."),
        ("this looks", "great to me, ready to ship."),
        ("happy to", "help with any questions you might have.")
    ]

    private func longestPhraseMatch(in trimmed: String, avoiding text: String) -> String? {
        let lower = trimmed.lowercased()
        let matches = phrases
            .filter { lower.hasSuffix($0.trigger) }
            .sorted { $0.trigger.count > $1.trigger.count }

        for match in matches where !alreadyUsed(match.completion, in: text) {
            return match.completion
        }
        return nil
    }

    // MARK: - Partial words (Curated Lexicon + macOS NSSpellChecker)

    private static let lexicon: [String] = [
        "about", "actually", "additional", "application", "architecture", "automatically", "autocomplete", "available",
        "because", "before", "between", "building", "complete", "completion", "configuration", "context", "conversation",
        "continue", "could", "customer", "definitely", "deployment", "development", "different", "discussion", "documentation",
        "environment", "everything", "experience", "feedback", "features", "following", "forward", "function",
        "general", "generation", "however", "immediately", "implementation", "important", "information", "including", "instead", "integration",
        "language", "learning", "looking", "management", "message", "necessary", "notification",
        "opportunity", "optimization", "organization", "particular", "performance", "personalization", "possible", "prediction", "previously", "probably", "problem", "process", "production", "project",
        "question", "quickly", "recently", "recommendation", "regarding", "release", "repository", "request", "required", "resolution", "resource", "response", "results", "review",
        "schedule", "security", "separate", "settings", "significant", "solution", "something", "specific", "standard", "structure", "successful", "suggestions", "summary", "support", "system",
        "technical", "technology", "temperature", "template", "therefore", "through", "together", "tomorrow", "training",
        "understand", "unfortunately", "updated", "validation", "version", "whether", "without", "working", "yesterday"
    ]

    private static let lexiconSet: Set<String> = Set(lexicon.map { $0.lowercased() })

    private func completePartialWord(_ preceding: String) -> String? {
        guard let lastScalar = preceding.last, lastScalar.isLetter else { return nil }
        guard let lastTokenSub = preceding.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last else { return nil }
        let lastToken = String(lastTokenSub)
        // Only complete pure alphabetical words (never :shortcode, /command, or punctuated tokens)
        guard lastToken.allSatisfy(\.isLetter), lastToken.count >= 3 else { return nil }

        let lower = lastToken.lowercased()
        // 1. Check high-frequency curated lexicon first (<0.1ms)
        if let word = Self.lexicon.first(where: { $0.lowercased().hasPrefix(lower) && $0.count > lower.count + 2 }) {
            let suffix = String(word.dropFirst(lower.count))
            return suffix
        }

        // 2. Fall back to macOS native NSSpellChecker completions for 4+ char stems
        if lastToken.count >= 4 {
            let checker = NSSpellChecker.shared
            // Only suggest a partial completion if the stem is NOT already a misspelled word that needs correction
            let nsStem = lastToken as NSString
            let range = NSRange(location: 0, length: nsStem.length)
            if let completions = checker.completions(forPartialWordRange: range, in: lastToken, language: "en", inSpellDocumentWithTag: 0),
               let best = completions.first(where: { $0.lowercased().hasPrefix(lower) && $0.count >= lastToken.count + 2 && $0.count <= lastToken.count + 10 && !$0.contains(" ") && !$0.contains("-") }) {
                return String(best.dropFirst(lastToken.count))
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func alreadyUsed(_ completion: String, in text: String) -> Bool {
        let needle = completion.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 10 else { return false }
        return text.lowercased().contains(needle)
    }

    private func spaced(_ completion: String, after preceding: String) -> String {
        guard !completion.isEmpty else { return "" }
        var text = completion
        if preceding.last?.isWhitespace == true {
            return String(text.drop(while: { $0 == " " || $0 == "\t" }))
        }

        let isPartialWord = preceding.last?.isLetter == true
            && text.first?.isLetter == true
            && !text.contains(where: { $0.isWhitespace })
        if isPartialWord {
            return text
        }

        if !text.hasPrefix(" ") && !text.hasPrefix("\n") {
            text = " " + text
        }
        return text
    }
}
