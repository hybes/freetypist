import Cocoa
import Foundation

public struct PromptContext: Sendable {
    public let precedingText: String
    public let followingText: String
    public let appName: String
    public let bundleIdentifier: String?
    public let domain: String?
    public let windowTitle: String?
    public let clipboardSnippet: String?
    public let deepContextSummary: String
    public let personaDescription: String
    public let toneInstruction: String
    public let dictionary: [String: String]
    public let learnedSamples: [String]
    public let maxWords: Int

    public init(
        precedingText: String,
        followingText: String = "",
        appName: String = "App",
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        windowTitle: String? = nil,
        clipboardSnippet: String? = nil,
        deepContextSummary: String = "",
        personaDescription: String = "",
        toneInstruction: String = "",
        dictionary: [String: String] = [:],
        learnedSamples: [String] = [],
        maxWords: Int = 8
    ) {
        self.precedingText = precedingText
        self.followingText = followingText
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.windowTitle = windowTitle
        self.clipboardSnippet = clipboardSnippet
        self.deepContextSummary = deepContextSummary
        self.personaDescription = personaDescription
        self.toneInstruction = toneInstruction
        self.dictionary = dictionary
        self.learnedSamples = learnedSamples
        self.maxWords = maxWords
    }
}

struct CompletionPrompt {
    let messages: [[String: String]]
    let regeneratedPrefix: String
    let grammar: String?

    var prefill: String? {
        guard messages.last?["role"] == "assistant" else { return nil }
        return messages.last?["content"]
    }
}

public struct PromptBuilder {
    public static func readSafeClipboardSnippet(enabled: Bool) -> String? {
        guard enabled else { return nil }
        let pb = NSPasteboard.general
        if let types = pb.types {
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            if types.contains(concealed) || types.contains(transient) {
                return nil
            }
        }
        guard let raw = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let clipped = String(raw.prefix(400))
        if AppSettings.shared.sanitizeSecretsLocally {
            return SecretSanitizer.sanitize(clipped).sanitized
        }
        return clipped
    }

    public static func buildSystemPrompt(context: PromptContext, includesDraft: Bool = false) -> String {
        var instructions: [String] = []
        // Keep the system prefix stable across sentence boundaries so the
        // server can reuse it instead of processing the whole prompt again.
        let task = "Complete the unfinished draft with a brief, relevant continuation."
        let output = includesDraft
            ? "Return the draft with a few words added; no explanation."
            : "Return only the words to append; no explanation."
        instructions.append("\(task) Keep the writer's point of view, language and style. \(output)")

        if !context.toneInstruction.isEmpty {
            instructions.append("Tone & Style: \(context.toneInstruction.prefix(300))")
        }

        if !context.personaDescription.isEmpty {
            instructions.append("Custom AI Instructions: \(context.personaDescription.prefix(600))")
        }

        return instructions.joined(separator: "\n\n")
    }

    public static func buildUserPrompt(context: PromptContext, continuationOnly: Bool = true) -> String {
        let shouldSanitize = AppSettings.shared.sanitizeSecretsLocally
        let beforeSlice = String(context.precedingText.suffix(700))
        let sanitizedBefore = shouldSanitize ? SecretSanitizer.sanitize(beforeSlice).sanitized : beforeSlice

        // Background belongs in the data message. Keeping the system instruction
        // stable also lets the local server reuse its prompt cache while typing.
        var parts: [String] = []
        if context.bundleIdentifier != "com.freetypist.playground" {
            let background = [context.deepContextSummary, context.clipboardSnippet ?? "", context.windowTitle ?? ""]
                .filter { isRelevantBackground($0, to: context.precedingText) }.joined(separator: "\n")
            if !background.isEmpty {
                parts.append("<background>\n\(background.prefix(600))\n</background>")
            }
        }
        if !context.learnedSamples.isEmpty {
            let samples = context.learnedSamples.prefix(2).map { String($0.suffix(120)) }.joined(separator: "\n")
            parts.append("<writing_style_examples>\n\(samples)\n</writing_style_examples>")
        }
        parts.append("Draft: \(sanitizedBefore)")
        if !context.followingText.isEmpty {
            let after = String(context.followingText.prefix(160))
            parts.append("<after>\(shouldSanitize ? SecretSanitizer.sanitize(after).sanitized : after)</after>")
        }
        if continuationOnly { parts.append("Missing continuation:") }
        return parts.joined(separator: "\n")
    }

    /// Regenerate the final word under an exact prefix constraint. Starting
    /// generation halfway through a model token otherwise produces misspellings
    /// such as "perform" + "ace", even with a larger model. Only the new suffix
    /// reaches the editor; the writer's existing text is never replaced.
    static func completionPrompt(context: PromptContext) -> CompletionPrompt {
        let prefix = String(context.precedingText.suffix(700))
        // Space-prefixed word tokens must remain available to the model. A
        // literal trailing space in the prefill splits that token boundary and
        // biases the next token towards numbers/symbols. Output normalisation
        // still uses the exact cursor text, so no user whitespace is removed.
        let trimmed = String(prefix.reversed().drop(while: \.isWhitespace).reversed())
        var draft = AppSettings.shared.sanitizeSecretsLocally ? SecretSanitizer.sanitize(trimmed).sanitized : trimmed
        var regenerated = ""
        var grammar: String?
        if context.precedingText.last?.isWhitespace != true,
           let wordRange = draft.range(of: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]*)?$"#, options: .regularExpression) {
            let word = String(draft[wordRange])
            // Keep paragraph breaks in the prefill. Regenerating a newline
            // would be removed by stream cleanup (or hit the double-newline
            // stop sequence), hiding completions for the first word of a line.
            let before = String(draft[..<wordRange.lowerBound].reversed()
                .drop(while: { $0 == " " || $0 == "\t" }).reversed())
            regenerated = String(draft.dropFirst(before.count))
            draft = before
            // Short function words and pronouns must stay whole: "on" must not
            // become "once", nor "I" become "I'm" just because space was omitted.
            let wholeWords: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "that", "there", "who",
                "to", "on", "in", "and", "or", "the", "a", "an", "if", "of", "for", "is", "as", "at", "be", "but", "so"]
            let literal = String(data: try! JSONEncoder().encode(regenerated), encoding: .utf8)!
            let tail = wholeWords.contains(word.lowercased())
                ? #"([ \t.!?,;:] [^\n\r]*)?"#
                : #"[^\n\r]*"#
            grammar = "root ::= \(literal) \(tail)"
        } else if context.precedingText.last?.isWhitespace == true {
            // An append-only suggestion cannot move an existing space to put
            // punctuation before it. Ask for a word instead of "works , and".
            grammar = #"root ::= " "? [^\n\r \t,.;:!?'’] [^\n\r]*"#
        }
        let messages = [
            ["role": "system", "content": buildSystemPrompt(context: context, includesDraft: true)],
            ["role": "user", "content": "Draft: Could you please"],
            ["role": "assistant", "content": "Could you please review the changes?"],
            ["role": "user", "content": "Draft: The mobile menu should"],
            ["role": "assistant", "content": "The mobile menu should collapse into a hamburger button."],
            ["role": "user", "content": buildUserPrompt(context: context, continuationOnly: false)],
            ["role": "assistant", "content": draft]
        ]
        return CompletionPrompt(messages: messages, regeneratedPrefix: regenerated, grammar: grammar)
    }

    static func completionMessages(context: PromptContext) -> [[String: String]] {
        completionPrompt(context: context).messages
    }

    static func isRelevantBackground(_ background: String, to prefix: String) -> Bool {
        let common: Set<String> = ["thank", "thanks", "please", "should", "could", "would", "there", "their",
                                   "about", "this", "that", "with", "have", "been", "will", "your", "just"]
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count >= 4 }.map(String.init)).subtracting(common)
        }
        return words(prefix).intersection(words(background)).count >= 2
            || (prefix.lowercased().hasSuffix("the link") && background.contains("https://"))
    }

    static func stripModelControlText(_ raw: String) -> String {
        var text = raw

        // 1. Remove closed or unclosed thinking tags (<think>...</think>, <|thought|>...<turn|>, <|thought|>...<|thought|>)
        let thinkPatterns = [
            "<think>[\\s\\S]*?</think>",
            "<\\|thought\\|>[\\s\\S]*?<turn\\|>",
            "<\\|thought\\|>[\\s\\S]*?</\\|thought\\|>",
            "<\\|thought\\|>[\\s\\S]*?<\\|thought\\|>",
            "^<think>[\\s\\S]*$",
            "^<\\|thought\\|>[\\s\\S]*$"
        ]
        for pattern in thinkPatterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text.removeSubrange(range)
            }
        }

        // Strip special chat template tokens if leaked
        for token in ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<turn|>", "<|end|>"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        return text.trimmingCharacters(in: .newlines)
    }

    public static func cleanCompletionText(_ raw: String, precedingText: String, maxWords: Int = 12,
                                          truncated: Bool = false, preservesWordBoundary: Bool = false) -> String {
        var text = stripModelControlText(raw)

        text = text.trimmingCharacters(in: .newlines)

        // 2. Strip markdown code fences if wrapped
        var wasCodeBlock = false
        if text.hasPrefix("```") {
            wasCodeBlock = true
            let lines = text.components(separatedBy: "\n")
            if lines.count >= 3 && lines.last?.hasPrefix("```") == true {
                text = lines.dropFirst().dropLast().joined(separator: "\n")
            } else if lines.count >= 2 {
                text = lines.dropFirst().joined(separator: "\n")
            }
        }

        // 3. Strip leading/trailing quotes if the model wrapped the response in quotes
        if (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 1) ||
           (text.hasPrefix("'") && text.hasSuffix("'") && text.count > 1) {
            text = String(text.dropFirst().dropLast())
        }

        // 4. Remove common conversational prefixes
        let commonPrefixes = [
            "Sure, here is the continuation: ",
            "Here's the completion: ",
            "Immediate continuation: ",
            "Continuation: ",
            "Next words: "
        ]
        for prefix in commonPrefixes {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count))
            }
        }

        // A prediction may append words, but must not turn a complete pronoun
        // into a different word ("I" + "'m"). An apostrophe the user already
        // typed is different: "I'" + "m ready" remains a valid completion.
        let lastWord = String(precedingText.split(whereSeparator: \.isWhitespace).last ?? "")
        let pronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "that", "there", "who"]
        if pronouns.contains(lastWord.lowercased()) {
            let contraction = #"['’](?:m|s|d|re|ve|ll)\b"#
            let repeatedPronoun = NSRegularExpression.escapedPattern(for: lastWord)
            if text.range(of: #"^\s*(?:"# + repeatedPronoun + ")?" + contraction,
                          options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        }

        // 5. Strip the longest repeated suffix at a word boundary. Small local models
        // sometimes echo several words of the prompt before their continuation.
        let trimmedPreceding = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreceding.isEmpty {
            let words = trimmedPreceding.split(whereSeparator: \.isWhitespace).suffix(40).map(String.init)
            for start in words.indices {
                let repeated = words[start...].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
                if let range = text.range(of: "^\\s*" + repeated + "(?=\\s|$)", options: [.regularExpression, .caseInsensitive]) {
                    text = String(text[range.upperBound...])
                    break
                }
            }
        }

        // 6. Take first line only for inline flow
        if let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            text = firstLine
        }
        if let sentenceEnd = text.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) {
            text = String(text[...sentenceEnd.lowerBound])
        }

        // 7. Enforce word count cap from Cotypist completionLength setting
        var chunks = text.split(whereSeparator: \.isWhitespace)
        if truncated, chunks.count <= maxWords, text.last.map({ $0.isLetter || $0.isNumber }) == true {
            // A token budget can cut through a word. Keep only completed words.
            guard chunks.count > 1, let last = chunks.last else { return "" }
            text = String(text[..<last.startIndex]).trimmingCharacters(in: .newlines)
            chunks = text.split(whereSeparator: \.isWhitespace)
        }
        if chunks.count > maxWords && maxWords > 0 {
            let leadingSpace = text.first?.isWhitespace == true ? " " : ""
            text = leadingSpace + chunks.prefix(maxWords).joined(separator: " ")
        }

        // Reject loops instead of presenting an old sentence as a new completion.
        func words(_ value: String) -> [String] {
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let beforeWords = words(precedingText)
        let proposedWords = words(text)
        if proposedWords.count >= 3 {
            let opening = Array(proposedWords.prefix(3))
            if beforeWords.count >= 3,
               (0...(beforeWords.count - 3)).contains(where: { Array(beforeWords[$0..<($0 + 3)]) == opening }) {
                return ""
            }
            var seen = Set<String>()
            for index in 0...(proposedWords.count - 3) {
                let phrase = proposedWords[index..<(index + 3)].joined(separator: " ")
                guard seen.insert(phrase).inserted else { return "" }
            }
        }

        // 8. Normalize leading space
        if precedingText.last?.isWhitespace == true {
            text = String(text.drop(while: { $0 == " " || $0 == "\t" }))
        } else if !preservesWordBoundary && !wasCodeBlock && !text.isEmpty && text.first?.isLetter == true && !precedingText.isEmpty {
            // Add leading space if starting a new word after a completed word
            let lastPrecedingWord = String(precedingText.split(whereSeparator: \.isWhitespace).last ?? "")
            let completesTypedApostrophe = precedingText.last.map { "'’".contains($0) } == true
                && text.range(of: #"^(?:m|s|d|re|ve|ll|t)\b"#, options: .regularExpression) != nil
            if !completesTypedApostrophe && (precedingText.last?.isLetter != true ||
                !OfflinePredictor.isLikelyPartialWordContinuation(stem: lastPrecedingWord, continuation: text)) {
                text = " " + text
            }
        }

        return text
    }
}
