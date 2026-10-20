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

    public static func buildSystemPrompt(context: PromptContext) -> String {
        var instructions: [String] = []

        instructions.append("""
        You are FreeTypist, an on-device inline autocomplete engine for macOS.
        Complete the unfinished sentence in its existing language and style. Output only the missing words, at most \(context.maxWords). Finish a partial word first if needed. Do not reply to the writer. Do not repeat the input, explain, add quotes, or output reasoning.
        """)

        if !context.appName.isEmpty {
            var envDesc = "Active application: '\(context.appName)'"
            if let dom = context.domain, !dom.isEmpty {
                envDesc += " (domain: \(dom))"
            }
            if let win = context.windowTitle, !win.isEmpty {
                envDesc += " — Window: '\(win.prefix(80))'"
            }
            instructions.append(envDesc)
        }

        if !context.toneInstruction.isEmpty {
            instructions.append("Tone & Style: \(context.toneInstruction.prefix(300))")
        }

        if !context.personaDescription.isEmpty {
            instructions.append("Custom AI Instructions: \(context.personaDescription.prefix(600))")
        }

        instructions.append("Continue the draft directly from its final character. Use background only when relevant; never copy a writing example or a previous sentence. Stop at the end of the sentence.")
        return instructions.joined(separator: "\n\n")
    }

    public static func buildUserPrompt(context: PromptContext, includeDraft: Bool = true) -> String {
        let shouldSanitize = AppSettings.shared.sanitizeSecretsLocally
        let beforeSlice = String(context.precedingText.suffix(700))
        let sanitizedBefore = shouldSanitize ? SecretSanitizer.sanitize(beforeSlice).sanitized : beforeSlice

        // Background belongs in the data message. Keeping the system instruction
        // stable also lets the local server reuse its prompt cache while typing.
        var parts: [String] = []
        if context.bundleIdentifier != "com.freetypist.playground" {
            let background = [context.deepContextSummary, context.clipboardSnippet ?? ""]
                .filter { isRelevantBackground($0, to: context.precedingText) }.joined(separator: "\n")
            if !background.isEmpty {
                parts.append("<background>\n\(background.prefix(600))\n</background>")
            }
        }
        if !context.learnedSamples.isEmpty {
            let samples = context.learnedSamples.prefix(2).map { String($0.suffix(120)) }.joined(separator: "\n")
            parts.append("<writing_style_examples>\n\(samples)\n</writing_style_examples>")
        }
        if includeDraft { parts.append("Sentence: \(sanitizedBefore)") }
        if !context.followingText.isEmpty {
            let after = String(context.followingText.prefix(160))
            parts.append("<after>\(shouldSanitize ? SecretSanitizer.sanitize(after).sanitized : after)</after>")
        }
        parts.append(includeDraft ? "Missing continuation:" : "Continue the draft already started below.")
        return parts.joined(separator: "\n")
    }

    /// llama.cpp b11669 continues a final assistant message rather than opening
    /// a new reply. This anchors small instruct models to the actual draft.
    static func completionMessages(context: PromptContext) -> [[String: String]] {
        let prefix = String(context.precedingText.suffix(700))
        let draft = AppSettings.shared.sanitizeSecretsLocally ? SecretSanitizer.sanitize(prefix).sanitized : prefix
        return [
            ["role": "system", "content": buildSystemPrompt(context: context)],
            ["role": "user", "content": buildUserPrompt(context: context, includeDraft: false)],
            ["role": "assistant", "content": draft]
        ]
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

    public static func cleanCompletionText(_ raw: String, precedingText: String, maxWords: Int = 12, truncated: Bool = false) -> String {
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
        if truncated, chunks.count <= maxWords, text.last?.isLetter == true {
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
        } else if !wasCodeBlock && !text.isEmpty && text.first?.isLetter == true && !precedingText.isEmpty {
            // Add leading space if starting a new word after a completed word
            let lastPrecedingWord = String(precedingText.split(whereSeparator: \.isWhitespace).last ?? "")
            if precedingText.last?.isLetter != true ||
                !OfflinePredictor.isLikelyPartialWordContinuation(stem: lastPrecedingWord, continuation: text) {
                text = " " + text
            }
        }

        return text
    }
}
