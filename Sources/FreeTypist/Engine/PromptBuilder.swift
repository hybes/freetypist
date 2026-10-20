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

        if !context.deepContextSummary.isEmpty {
            instructions.append("DEEP ON-DEVICE MULTI-WINDOW & CLIPBOARD CONTEXT:\n\(context.deepContextSummary.prefix(1500))")
        }

        if !context.toneInstruction.isEmpty {
            instructions.append("Tone & Style: \(context.toneInstruction.prefix(300))")
        }

        if !context.personaDescription.isEmpty {
            instructions.append("Custom AI Instructions: \(context.personaDescription.prefix(600))")
        }

        if !context.dictionary.isEmpty {
            let dictPairs = context.dictionary.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value)" }.joined(separator: ", ").prefix(600)
            instructions.append("Preferred vocabulary and expansions: \(dictPairs)")
        }

        if !context.learnedSamples.isEmpty {
            let formatted = context.learnedSamples.prefix(3).map { "- \"\($0.suffix(180))\"" }.joined(separator: "\n")
            instructions.append("Recent examples of the user's personal writing style:\n\(formatted)")
        }

        if let clip = context.clipboardSnippet, !clip.isEmpty {
            instructions.append("Current clipboard context (for reference if relevant):\n\"\(clip)\"")
        }

        instructions.append("Complete the given sentence. Respond with ONLY the missing words, never the original sentence or an explanation.")
        return instructions.joined(separator: "\n\n")
    }

    public static func buildUserPrompt(context: PromptContext) -> String {
        let shouldSanitize = AppSettings.shared.sanitizeSecretsLocally
        let beforeSlice = String(context.precedingText.suffix(700))
        let sanitizedBefore = shouldSanitize ? SecretSanitizer.sanitize(beforeSlice).sanitized : beforeSlice

        if context.followingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Sentence: \(sanitizedBefore)"
        } else {
            let afterSlice = String(context.followingText.prefix(240))
            let sanitizedAfter = shouldSanitize ? SecretSanitizer.sanitize(afterSlice).sanitized : afterSlice
            return "<TEXT_BEFORE_CURSOR>\n\(sanitizedBefore)\n</TEXT_BEFORE_CURSOR>\n<TEXT_AFTER_CURSOR>\n\(sanitizedAfter)\n</TEXT_AFTER_CURSOR>\n\nImmediate middle continuation (\(context.maxWords) words max):"
        }
    }

    public static func cleanCompletionText(_ raw: String, precedingText: String, maxWords: Int = 12) -> String {
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

        // 7. Enforce word count cap from Cotypist completionLength setting
        let chunks = text.split(whereSeparator: \.isWhitespace)
        if chunks.count > maxWords && maxWords > 0 {
            let leadingSpace = text.first?.isWhitespace == true ? " " : ""
            text = leadingSpace + chunks.prefix(maxWords).joined(separator: " ")
        }

        // 8. Normalize leading space
        if precedingText.last?.isWhitespace == true {
            text = String(text.drop(while: { $0 == " " || $0 == "\t" }))
        } else if !wasCodeBlock && !text.isEmpty && precedingText.last?.isLetter == true && text.first?.isLetter == true {
            // Add leading space if starting a new word after a completed word
            let lastPrecedingWord = String(precedingText.split(whereSeparator: \.isWhitespace).last ?? "")
            if lastPrecedingWord.count >= 2 && !OfflinePredictor.isLikelyPartialWordContinuation(stem: lastPrecedingWord, continuation: text) {
                text = " " + text
            }
        }

        return text
    }
}
