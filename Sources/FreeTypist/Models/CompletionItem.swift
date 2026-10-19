import Foundation

public struct CompletionItem: Equatable, Sendable {
    public let fullText: String
    public let words: [String]
    public var acceptedWordIndex: Int
    public let timestamp: Date
    public let providerName: String
    public let latencyMs: Int

    public init(fullText: String, providerName: String = "AI", latencyMs: Int = 0) {
        self.fullText = fullText
        self.providerName = providerName
        self.latencyMs = latencyMs
        self.timestamp = Date()
        self.acceptedWordIndex = 0
        
        // Tokenize text into word chunks (leading whitespace + word/symbols)
        var parsedChunks: [String] = []
        if let regex = try? NSRegularExpression(pattern: "\\s*\\S+|\\s+$", options: []) {
            let nsString = fullText as NSString
            let matches = regex.matches(in: fullText, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let chunk = nsString.substring(with: match.range)
                parsedChunks.append(chunk)
            }
        }
        
        self.words = parsedChunks.isEmpty ? [fullText] : parsedChunks
    }

    public var remainingText: String {
        if acceptedWordIndex >= words.count {
            return ""
        }
        return words[acceptedWordIndex...].joined()
    }

    public var nextWord: String? {
        guard acceptedWordIndex < words.count else { return nil }
        return words[acceptedWordIndex]
    }

    public mutating func advanceOneWord() -> String? {
        guard acceptedWordIndex < words.count else { return nil }
        let word = words[acceptedWordIndex]
        acceptedWordIndex += 1
        return word
    }

    public var wordCount: Int {
        return fullText.split { $0.isWhitespace }.count
    }

    public var characterCount: Int {
        return fullText.count
    }
}
