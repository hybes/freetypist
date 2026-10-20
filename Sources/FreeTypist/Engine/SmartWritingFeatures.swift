import Cocoa
import Foundation

// MARK: - Emoji Preferences
public enum EmojiSkinTone: String, CaseIterable, Identifiable, Codable, Sendable {
    case neutral = "Neutral (Default)"
    case light = "Light"
    case mediumLight = "Medium-Light"
    case medium = "Medium"
    case mediumDark = "Medium-Dark"
    case dark = "Dark"

    public var id: String { rawValue }

    public var modifierScalar: String {
        switch self {
        case .neutral: return ""
        case .light: return "\u{1F3FB}"
        case .mediumLight: return "\u{1F3FC}"
        case .medium: return "\u{1F3FD}"
        case .mediumDark: return "\u{1F3FE}"
        case .dark: return "\u{1F3FF}"
        }
    }
}

public enum EmojiGenderPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case neutral = "Person (Neutral)"
    case female = "Woman (Female)"
    case male = "Man (Male)"

    public var id: String { rawValue }
}

public struct EmojiCandidate: Identifiable, Equatable, Sendable {
    public var id: String { shortcode + emoji }
    public let shortcode: String
    public let emoji: String
    public let description: String
    public let replacementLength: Int
}

public struct AutocorrectSuggestion: Equatable, Sendable {
    public let misspelledWord: String
    public let correctedWord: String
    public let replacementLength: Int
    /// Used when revisiting a word: the word may extend on both sides of the cursor.
    public var replacementRange: NSRange? = nil
}

public struct WordAlternativeItem: Identifiable, Equatable, Sendable {
    public let index: Int
    public let text: String
    public let label: String
    public var id: Int { index }
}

/// High-precision Inline Autocorrect, Grammar/Contraction Fixer, Synonym Lookup, and Shortcode Expander.
public struct SmartWritingFeatures: Sendable {
    // MARK: - 1. Clean Emoji Shortcode Engine
    private static let emojiCatalog: [(shortcode: String, base: String, skinModifiable: Bool, keywords: String)] = [
        (":joy:", "😂", false, "crylaugh laugh tears funny lol lmao"),
        (":crylaugh:", "😂", false, "joy laugh tears funny lol"),
        (":rofl:", "🤣", false, "laugh rolling floor hilarious"),
        (":smile:", "😄", false, "happy grin"),
        (":blush:", "😊", false, "happy warm smile"),
        (":wink:", "😉", false, "wink"),
        (":heart_eyes:", "😍", false, "love adore"),
        (":sob:", "😭", false, "cry tears sad"),
        (":cry:", "😢", false, "sad tear"),
        (":skull:", "💀", false, "dead funny rip"),
        (":salute:", "🫡", false, "respect yes sir"),
        (":thinking:", "🤔", false, "think hmm question"),
        (":sparkles:", "✨", false, "magic stars shine new"),
        (":fire:", "🔥", false, "hot lit awesome"),
        (":rocket:", "🚀", false, "launch ship fast deploy"),
        (":tada:", "🎉", false, "party celebrate congrats"),
        (":check:", "✅", false, "done complete yes"),
        (":x:", "❌", false, "no cancel error"),
        (":warning:", "⚠️", false, "alert caution"),
        (":bulb:", "💡", false, "idea light tip"),
        (":zap:", "⚡️", false, "fast lightning bolt"),
        (":star:", "⭐️", false, "favorite best"),
        (":heart:", "❤️", false, "love red like"),
        (":100:", "💯", false, "perfect score full"),
        (":eyes:", "👀", false, "look see review"),
        (":thumbsup:", "👍", true, "yes approve good like +1"),
        (":thumbsdown:", "👎", true, "no disapprove -1"),
        (":wave:", "👋", true, "hello hi bye"),
        (":clap:", "👏", true, "applause congrats"),
        (":pray:", "🙏", true, "thanks please thank you"),
        (":raised_hands:", "🙌", true, "hooray celebrate"),
        (":muscle:", "💪", true, "strong power"),
        (":ok_hand:", "👌", true, "okay perfect"),
        (":coffee:", "☕️", false, "morning drink"),
        (":bug:", "🐛", false, "issue fix debug"),
        (":lock:", "🔒", false, "secure private"),
        (":calendar:", "📅", false, "date schedule meeting")
    ]

    private static let emoticonMap: [(emoticon: String, emoji: String, name: String)] = [
        (":-)", "🙂", "smile"),
        (":-D", "😃", "grin"),
        (";-)", "😉", "wink"),
        (":-(", "🙁", "frown"),
        ("<3", "❤️", "heart")
    ]

    public static func matchEmoji(
        in precedingText: String,
        enableShortcodes: Bool,
        enableEmoticons: Bool,
        skinTone: EmojiSkinTone,
        includeNeutralSkinTone: Bool
    ) -> [EmojiCandidate] {
        guard !precedingText.isEmpty else { return [] }

        if enableEmoticons {
            for item in emoticonMap {
                if precedingText.hasSuffix(item.emoticon) {
                    let prefixBefore = precedingText.dropLast(item.emoticon.count)
                    if prefixBefore.isEmpty || prefixBefore.last?.isWhitespace == true {
                        return [
                            EmojiCandidate(
                                shortcode: item.emoticon,
                                emoji: item.emoji,
                                description: item.name,
                                replacementLength: item.emoticon.count
                            )
                        ]
                    }
                }
            }
        }

        guard enableShortcodes else { return [] }
        let lastToken = String(precedingText.suffix(24))
        let searchToken = lastToken.hasSuffix(":") ? String(lastToken.dropLast()) : lastToken
        guard let colonIdx = searchToken.lastIndex(of: ":") else { return [] }

        let offset = searchToken.distance(from: searchToken.startIndex, to: colonIdx)
        let openingColon = lastToken.index(lastToken.startIndex, offsetBy: offset)
        let afterColon = String(lastToken[openingColon...])
        if openingColon > lastToken.startIndex {
            let beforeColonIdx = lastToken.index(before: openingColon)
            let charBefore = lastToken[beforeColonIdx]
            if !charBefore.isWhitespace && charBefore != "(" && charBefore != "[" {
                return []
            }
        }

        // Require at least 3 chars after ':' (or closing ':') so normal colons never trigger
        guard afterColon.count >= 2, !afterColon.contains(where: \.isWhitespace) else { return [] }
        let query = afterColon.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        guard (afterColon.hasSuffix(":") ? !query.isEmpty : query.count >= 3), query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" }) else {
            return []
        }

        var results: [EmojiCandidate] = []
        var seenEmojis = Set<String>()
        for entry in emojiCatalog {
            let cleanCode = entry.shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
            if cleanCode.hasPrefix(query) || cleanCode == query || entry.keywords.split(separator: " ").contains(where: { $0.hasPrefix(query) || query.contains($0) }) {
                let tonedEmoji = (entry.skinModifiable && skinTone != .neutral)
                    ? (entry.base + skinTone.modifierScalar)
                    : entry.base
                guard !seenEmojis.contains(tonedEmoji) else { continue }
                seenEmojis.insert(tonedEmoji)

                results.append(
                    EmojiCandidate(
                        shortcode: entry.shortcode,
                        emoji: tonedEmoji,
                        description: cleanCode,
                        replacementLength: afterColon.count
                    )
                )
            }
        }

        return Array(results.prefix(4))
    }

    // MARK: - 2. High-Precision Inline Autocorrect & Grammar Engine
    private static let fastCommonTypos: [String: String] = [
        // Missing apostrophes & contractions
        "im": "I'm",
        "ive": "I've",
        "dont": "don't",
        "doesnt": "doesn't",
        "didnt": "didn't",
        "cant": "can't",
        "cannot": "cannot",
        "couldn't": "couldn't",
        "couldnt": "couldn't",
        "wouldnt": "wouldn't",
        "shouldnt": "shouldn't",
        "wont": "won't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "hadnt": "hadn't",
        "thats": "that's",
        "whats": "what's",
        "wheres": "where's",
        "heres": "here's",
        "theres": "there's",
        "youre": "you're",
        "theyre": "they're",
        "weve": "we've",
        "youve": "you've",
        "theyve": "they've",
        "lets": "let's",

        // Common multi-word fusions
        "alot": "a lot",
        "aswell": "as well",
        "infact": "in fact",
        "incase": "in case",
        "atleast": "at least",
        "noone": "no one",

        // High-frequency English & typing errors
        "focuso": "focus",
        "expeexperience": "experience",
        "expereince": "experience",
        "experiance": "experience",
        "teh": "the",
        "hte": "the",
        "taht": "that",
        "adn": "and",
        "nad": "and",
        "jsut": "just",
        "wiht": "with",
        "whihc": "which",
        "wich": "which",
        "waht": "what",
        "woudl": "would",
        "shoudl": "should",
        "coudl": "could",
        "abotu": "about",
        "baout": "about",
        "fro": "for",
        "fomr": "from",
        "recieve": "receive",
        "recieved": "received",
        "definately": "definitely",
        "definitly": "definitely",
        "definatly": "definitely",
        "seperate": "separate",
        "seperated": "separated",
        "occured": "occurred",
        "occuring": "occurring",
        "untill": "until",
        "wierd": "weird",
        "accomodate": "accommodate",
        "becuase": "because",
        "beacuse": "because",
        "becasue": "because",
        "thier": "their",
        "freind": "friend",
        "freinds": "friends",
        "enviroment": "environment",
        "goverment": "government",
        "immediatly": "immediately",
        "neccessary": "necessary",
        "necesary": "necessary",
        "tommorow": "tomorrow",
        "tomorow": "tomorrow",
        "tounge": "tongue",
        "truely": "truly",
        "acheive": "achieve",
        "adress": "address",
        "appearence": "appearance",
        "begining": "beginning",
        "beleive": "believe",
        "buisness": "business",
        "calender": "calendar",
        "collegue": "colleague",
        "concious": "conscious",
        "curiousity": "curiosity",
        "disapoint": "disappoint",
        "embarass": "embarrass",
        "existance": "existence",
        "foriegn": "foreign",
        "fourty": "forty",
        "garantee": "guarantee",
        "harrass": "harass",
        "independant": "independent",
        "knowlege": "knowledge",
        "liason": "liaison",
        "maintainance": "maintenance",
        "millenium": "millennium",
        "noticable": "noticeable",
        "occassion": "occasion",
        "perseverence": "perseverance",
        "posession": "possession",
        "prefered": "preferred",
        "priviledge": "privilege",
        "recomend": "recommend",
        "reccomend": "recommend",
        "refered": "referred",
        "religous": "religious",
        "remeber": "remember",
        "rember": "remember",
        "succesful": "successful",
        "successfull": "successful",
        "suprise": "surprise",
        "therefor": "therefore",
        "threshhold": "threshold",
        "unforseen": "unforeseen",
        "unfortunatly": "unfortunately",
        "availble": "available",
        "avaliable": "available",
        "diffrent": "different",
        "probaly": "probably",
        "basicly": "basically",
        "actully": "actually",
        "actualy": "actually",
        "usuall": "usual",
        "usally": "usually",
        "similiar": "similar",
        "responce": "response",
        "messaeg": "message",
        "mesage": "message",
        "pls": "please",
        "plz": "please",
        "thx": "thanks",
        "ty": "thank you"
    ]

    @MainActor
    public static func detectAutocorrect(in precedingText: String) -> AutocorrectSuggestion? {
        guard !precedingText.isEmpty else { return nil }

        // Keep punctuation and spacing when accepting a correction after finishing a word.
        let suffixSpace = String(precedingText.reversed().prefix { " .,!?;:)]}".contains($0) }.reversed())
        guard suffixSpace.count <= 4, !suffixSpace.hasSuffix("  ") else { return nil }
        let trimmed = String(precedingText.dropLast(suffixSpace.count))
        let hasTrailingSingleSpace = !suffixSpace.isEmpty

        guard trimmed.last?.isWhitespace != true else { return nil }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard let lastWordSub = tokens.last else { return nil }
        let word = String(lastWordSub)

        // Ignore slash commands, shortcodes, URLs, or non-letter words
        guard word.count >= 2, word.allSatisfy(\.isLetter) else { return nil }
        let lower = word.lowercased()
        let repLen = word.count + suffixSpace.count

        // 0. Check accidental repeated consecutive word (e.g. "the the ", "to to ", "is is ")
        if tokens.count >= 2 {
            let prevWord = String(tokens[tokens.count - 2]).lowercased()
            if prevWord == lower && ["the", "to", "a", "an", "is", "in", "on", "of", "for", "and", "we", "it", "be", "can", "will", "just"].contains(lower) {
                let bothLen = trimmed.distance(from: tokens[tokens.count - 2].startIndex, to: trimmed.endIndex) + suffixSpace.count
                return AutocorrectSuggestion(
                    misspelledWord: "\(tokens[tokens.count - 2]) \(word)",
                    correctedWord: String(tokens[tokens.count - 2]) + suffixSpace,
                    replacementLength: bothLen
                )
            }
        }

        // For 2-letter words like "im", only trigger after space or if it's an exact contraction
        if word.count < 3 && !hasTrailingSingleSpace && lower != "im" {
            return nil
        }
        if lower == "ty" && !hasTrailingSingleSpace {
            return nil
        }

        // 1. Instant curated typo & contraction lookup
        if let fixed = fastCommonTypos[lower] {
            let casedFixed = fixed.contains("I'") ? fixed : preserveCase(original: word, replacement: fixed)
            guard casedFixed != word else { return nil }
            return AutocorrectSuggestion(
                misspelledWord: word,
                correctedWord: casedFixed + suffixSpace,
                replacementLength: repLen
            )
        }

        guard word.count >= 4 else { return nil }
        let checker = NSSpellChecker.shared
        let spellRange = checker.checkSpelling(of: word, startingAt: 0, language: "en_GB",
                                              wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard spellRange.location != NSNotFound else {
            return nil // Word is spelled correctly
        }

        // Prefer repairing a repeated keystroke to a guess that changes the word.
        if let fixed = repeatedKeystrokeCorrection(word) {
            return AutocorrectSuggestion(misspelledWord: word, correctedWord: fixed + suffixSpace,
                                         replacementLength: word.count + suffixSpace.count)
        }
        let fullRange = NSRange(location: 0, length: word.utf16.count)
        if !hasTrailingSingleSpace,
           !(checker.completions(forPartialWordRange: fullRange, in: word,
                                 language: "en_GB", inSpellDocumentWithTag: 0) ?? []).isEmpty {
            return nil
        }

        // 2. Stutter / Doubled-Prefix Detector (e.g., "expeexperience" -> "experience", "recreceive" -> "receive")
        if word.count >= 6 {
            for prefixLen in 2...min(5, word.count / 2) {
                let firstPart = lower.prefix(prefixLen)
                let remainder = String(lower.dropFirst(prefixLen))
                if remainder.hasPrefix(firstPart) && remainder.count >= 4 {
                    let checkRem = checker.checkSpelling(of: remainder, startingAt: 0)
                    if checkRem.location == NSNotFound {
                        let cased = preserveCase(original: word, replacement: remainder)
                        return AutocorrectSuggestion(
                            misspelledWord: word,
                            correctedWord: cased + suffixSpace,
                            replacementLength: repLen
                        )
                    }
                }
            }
        }

        // 3. Accidental trailing extra letter on a valid word (e.g. "focuso" -> "focus", "workk" -> "work")
        if word.count >= 5 {
            let droppedLast = String(word.dropLast())
            let checkDropped = checker.checkSpelling(of: droppedLast, startingAt: 0)
            // Only suggest dropping the last letter if the user finished the word (pressed space) OR the current stem cannot be completed into any valid English word
            if checkDropped.location == NSNotFound {
                let nsWord = word as NSString
                let completions = checker.completions(forPartialWordRange: NSRange(location: 0, length: nsWord.length), in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
                if hasTrailingSingleSpace || completions.isEmpty {
                    return AutocorrectSuggestion(
                        misspelledWord: word,
                        correctedWord: droppedLast + suffixSpace,
                        replacementLength: repLen
                    )
                }
            }
        }

        // A lack of dictionary completions does not make an unfinished name or
        // host query a spelling mistake. Wait for a word boundary before guessing.
        guard hasTrailingSingleSpace || (tokens.count >= 2 && word.count >= 6 && word.first?.isUppercase != true) else { return nil }

        // 4. macOS NSSpellChecker direct correction
        if let correction = checker.correction(
            forWordRange: fullRange,
            in: word,
            language: "en_GB",
            inSpellDocumentWithTag: 0
        ), correction.lowercased() != lower {
            return AutocorrectSuggestion(
                misspelledWord: word,
                correctedWord: preserveCase(original: word, replacement: correction) + suffixSpace,
                replacementLength: repLen
            )
        }

        // 5. macOS NSSpellChecker guesses ranked by edit distance (catches transpositions & 1-2 char typos)
        if let guesses = checker.guesses(forWordRange: fullRange, in: word, language: "en_GB", inSpellDocumentWithTag: 0),
           !guesses.isEmpty {
            // Only trigger mid-word if no valid word starts with `word`
            let possibleCompletions = checker.completions(forPartialWordRange: fullRange, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
            if hasTrailingSingleSpace || possibleCompletions.isEmpty {
                for guess in guesses.prefix(5) {
                    let gLower = guess.lowercased()
                    guard !gLower.contains(" ") && !gLower.contains("-") else { continue }
                    let dist = editDistance(lower, gLower)
                    if dist <= 2 && gLower.first == lower.first {
                        return AutocorrectSuggestion(
                            misspelledWord: word,
                            correctedWord: preserveCase(original: word, replacement: guess) + suffixSpace,
                            replacementLength: repLen
                        )
                    }
                }
            }
        }

        return nil
    }

    /// More conservative than an explicitly accepted inline suggestion.
    /// Real words, names, abbreviations and code identifiers are left alone.
    @MainActor
    private static var completedWordCache: [String: (correction: String?, checkedAt: Date)] = [:]

    @MainActor
    static func warmSpellingChecker() {
        _ = completedWordCorrection("spelling")
        _ = completedWordCorrection("speelling")
    }

    @MainActor
    static func completedWordCorrection(_ word: String) -> String? {
        let now = Date()
        if let cached = completedWordCache[word], now.timeIntervalSince(cached.checkedAt) < 60 {
            return cached.correction
        }
        let correction = uncachedCompletedWordCorrection(word)
        // Keep only a small, short-lived in-memory vocabulary. Nothing is persisted.
        if completedWordCache.count >= 512 { completedWordCache.removeAll(keepingCapacity: true) }
        completedWordCache[word] = (correction, now)
        return correction
    }

    @MainActor
    private static func uncachedCompletedWordCorrection(_ word: String) -> String? {
        guard (2...48).contains(word.count),
              word.allSatisfy({ $0.isLetter }),
              word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return nil }
        let lower = word.lowercased()
        let checker = NSSpellChecker.shared
        func isWord(_ candidate: String) -> Bool {
            checker.checkSpelling(of: candidate, startingAt: 0, language: "en_GB",
                                  wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        // These valid words and informal abbreviations must not be rewritten automatically.
        let ambiguous = ["ill", "id", "form", "fro", "lets", "wont", "were", "well", "its",
                         "cant", "thats", "therefor", "pls", "plz", "thx", "ty"]
        guard !ambiguous.contains(lower) else { return nil }
        if let fixed = fastCommonTypos[lower], fixed != lower {
            return fixed.contains("I'") ? fixed : preserveCase(original: word, replacement: fixed)
        }
        guard word.count >= 4, !isWord(word) else { return nil }

        if let fixed = repeatedKeystrokeCorrection(word) { return fixed }
        // Do not guess at unfamiliar capitalised names.
        guard word.first?.isUppercase != true,
              let fixed = checker.correction(forWordRange: NSRange(location: 0, length: word.utf16.count),
                  in: word, language: "en_GB", inSpellDocumentWithTag: 0),
              fixed.allSatisfy(\.isLetter), fixed.lowercased() != lower,
              fixed.first == word.first, editDistance(lower, fixed.lowercased()) <= 2 else { return nil }
        return fixed
    }

    @MainActor
    private static func repeatedKeystrokeCorrection(_ word: String) -> String? {
        let lower = word.lowercased()
        func isWord(_ candidate: String) -> Bool {
            NSSpellChecker.shared.checkSpelling(of: candidate, startingAt: 0, language: "en_GB",
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        // Repeated letters and repeated endings: outsiide, sentencee, playgroundnd.
        let letters = Array(lower)
        var candidates = Set<String>()
        guard letters.count >= 4 else { return nil }
        for index in 1..<letters.count where letters[index] == letters[index - 1] {
            var shortened = letters
            shortened.remove(at: index)
            let candidate = String(shortened)
            if isWord(candidate) { candidates.insert(candidate) }
        }
        if letters.count >= 6 {
            for length in 2...min(3, letters.count / 2) {
                let ending = String(lower.suffix(length))
                let shortened = String(lower.dropLast(length))
                if shortened.hasSuffix(ending), isWord(shortened) { candidates.insert(shortened) }
            }
        }
        if candidates.count == 1, let fixed = candidates.first {
            return preserveCase(original: word, replacement: fixed)
        }
        return nil
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        let m = s.count
        let n = t.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = (s[i - 1] == t[j - 1]) ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1,
                    dp[i - 1][j - 1] + cost
                )
                if i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
                }
            }
        }
        return dp[m][n]
    }

    private static func preserveCase(original: String, replacement: String) -> String {
        if original == original.uppercased() && original.count > 1 {
            return replacement.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - 3. Contextual Synonyms / Thesaurus
    private static let builtInThesaurus: [String: [String]] = [
        "good": ["excellent", "solid", "effective", "strong", "great"],
        "bad": ["suboptimal", "poor", "problematic", "unfavorable", "weak"],
        "fast": ["rapid", "swift", "responsive", "low-latency", "instant"],
        "slow": ["sluggish", "gradual", "delayed", "unresponsive", "laggy"],
        "important": ["critical", "essential", "vital", "key", "significant"],
        "help": ["assist", "support", "guide", "facilitate", "enable"],
        "change": ["modify", "adjust", "update", "refine", "revise"],
        "make": ["create", "build", "generate", "produce", "craft"],
        "use": ["utilize", "leverage", "apply", "employ", "adopt"],
        "show": ["display", "present", "demonstrate", "reveal", "surface"],
        "think": ["believe", "consider", "suspect", "anticipate", "expect"],
        "need": ["require", "depend on", "call for", "warrant", "necessitate"],
        "check": ["verify", "inspect", "review", "confirm", "validate"],
        "fix": ["resolve", "address", "remedy", "correct", "patch"],
        "problem": ["issue", "challenge", "bottleneck", "obstacle", "defect"],
        "start": ["initiate", "launch", "begin", "kick off", "commence"],
        "finish": ["complete", "conclude", "wrap up", "finalize", "accomplish"],
        "happy": ["pleased", "delighted", "glad", "thrilled", "satisfied"],
        "easy": ["straightforward", "simple", "effortless", "intuitive", "seamless"],
        "hard": ["challenging", "complex", "demanding", "intricate", "difficult"],
        "improve": ["enhance", "optimize", "strengthen", "elevate", "boost"],
        "reduce": ["minimize", "decrease", "lower", "curb", "cut"],
        "clear": ["concise", "transparent", "lucid", "unambiguous", "distinct"]
    ]

    public static func lookupSynonyms(for selectedText: String) -> [WordAlternativeItem] {
        let cleaned = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 32 else { return [] }
        let lower = cleaned.lowercased()

        if let matches = builtInThesaurus[lower] {
            return matches.enumerated().map { idx, syn in
                let cased = preserveCase(original: cleaned, replacement: syn)
                return WordAlternativeItem(index: idx + 1, text: cased, label: "Synonym")
            }
        }
        return []
    }

    // MARK: - 4. Word Alternatives for Active Completion
    public static func generateWordAlternatives(
        primarySuggestion: String,
        precedingText: String,
        tone: TonePreset
    ) -> [WordAlternativeItem] {
        let cleanPrimary = primarySuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrimary.isEmpty else { return [] }

        let leadingSpace = primarySuggestion.hasPrefix(" ") ? " " : ""
        var candidates: [String] = []

        if let learned = LearningEngine.shared.predictFromLearnedHistory(precedingText: precedingText, strength: .strong) {
            let trimmedLearned = learned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLearned.lowercased() != cleanPrimary.lowercased() {
                candidates.append(leadingSpace + trimmedLearned)
            }
        }

        let primaryWords = cleanPrimary.split(whereSeparator: \.isWhitespace).map(String.init)
        for (wordIdx, rawWord) in primaryWords.enumerated() {
            let cleanWord = rawWord.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if let syns = builtInThesaurus[cleanWord] {
                for syn in syns.prefix(2) {
                    var mutated = primaryWords
                    mutated[wordIdx] = preserveCase(original: rawWord, replacement: syn)
                    let built = leadingSpace + mutated.joined(separator: " ")
                    if !candidates.contains(built) && built.trimmingCharacters(in: .whitespaces).lowercased() != cleanPrimary.lowercased() {
                        candidates.append(built)
                    }
                }
            }
        }

        if primaryWords.count >= 4 {
            let shorter = leadingSpace + primaryWords.prefix(3).joined(separator: " ") + "."
            if !candidates.contains(shorter) {
                candidates.append(shorter)
            }
        }
        return candidates.prefix(3).enumerated().map { idx, text in
            WordAlternativeItem(index: idx + 1, text: text, label: "Alt \(idx + 1)")
        }
    }

    public static func matchAbbreviation(in text: String, dictionary: [String: String])
        -> (expansion: String, replacementLength: Int)? {
        let trailingSpace = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let trimmed = text.dropLast(trailingSpace.count)
        guard let token = trimmed.split(whereSeparator: \.isWhitespace).last,
              let match = dictionary.sorted(by: { $0.key < $1.key }).first(where: {
                  $0.key.caseInsensitiveCompare(String(token)) == .orderedSame
              }), !match.value.isEmpty else { return nil }
        return (match.value + trailingSpace, token.count + trailingSpace.count)
    }

    // MARK: - 5. Slash Commands & Snippets (/date, /time, /sig, /lgtm...)
    public static func matchSlashCommand(
        in precedingText: String,
        customCommands: [String: String],
        recentClips: [String] = []
    ) -> (trigger: String, expansion: String, replacementLength: Int)? {
        guard !precedingText.isEmpty else { return nil }
        let tail = String(precedingText.suffix(24))
        guard let slashIdx = tail.lastIndex(of: "/") else { return nil }

        if slashIdx > tail.startIndex {
            let beforeIdx = tail.index(before: slashIdx)
            if !tail[beforeIdx].isWhitespace && !tail[beforeIdx].isNewline {
                return nil
            }
        }

        let token = String(tail[slashIdx...]).lowercased()
        guard token.count >= 2, !token.dropFirst().contains("/") else { return nil }

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"

        var allCommands: [String: String] = [
            "/date": dateFormatter.string(from: now),
            "/time": timeFormatter.string(from: now),
            "/iso": isoFormatter.string(from: now)
        ]

        if let c1 = recentClips.first {
            allCommands["/clip"] = c1
        }

        for (k, v) in customCommands {
            let normalizedKey = k.hasPrefix("/") ? k.lowercased() : "/" + k.lowercased()
            allCommands[normalizedKey] = v
        }

        if let exact = allCommands[token] {
            return (token, exact, token.count)
        }

        if let bestMatch = allCommands.keys.sorted().first(where: { $0.hasPrefix(token) }),
           let expansion = allCommands[bestMatch] {
            return (bestMatch, expansion, token.count)
        }

        return nil
    }
}
