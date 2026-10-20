import Foundation
import NaturalLanguage
import Combine

public enum PersonalizationStrength: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "Off"
    case gentle = "Gentle"
    case balanced = "Balanced"
    case strong = "Strong"

    public var id: String { rawValue }

    public var subtitle: String {
        switch self {
        case .off:
            return "Do not adapt suggestions to typing history."
        case .gentle:
            return "A subtle nudge toward how you write."
        case .balanced:
            return "Suggestions lean more clearly toward your style."
        case .strong:
            return "The fullest match to your voice and preferred phrases."
        }
    }

    public var maxFewShotExamples: Int {
        switch self {
        case .off: return 0
        case .gentle: return 2
        case .balanced: return 4
        case .strong: return 6
        }
    }
}

public struct WritingHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var appBundleIdentifier: String
    public var appName: String
    public var domain: String?
    public var windowTitle: String?
    public var textUpToCursor: String
    public var acceptedCompletion: String?
    public var textLanguage: String
    public var wordCount: Int
    public var wasAcceptedCompletion: Bool
    public var redactedSecretsCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        appBundleIdentifier: String,
        appName: String,
        domain: String? = nil,
        windowTitle: String? = nil,
        textUpToCursor: String,
        acceptedCompletion: String? = nil,
        textLanguage: String = "en",
        wordCount: Int = 0,
        wasAcceptedCompletion: Bool = false,
        redactedSecretsCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.domain = domain
        self.windowTitle = windowTitle
        self.textUpToCursor = textUpToCursor
        self.acceptedCompletion = acceptedCompletion
        self.textLanguage = textLanguage
        self.wordCount = wordCount > 0 ? wordCount : textUpToCursor.split(whereSeparator: \.isWhitespace).count
        self.wasAcceptedCompletion = wasAcceptedCompletion
        self.redactedSecretsCount = redactedSecretsCount
    }
}

public struct LearnedPhraseStat: Identifiable, Codable, Equatable, Sendable {
    public var id: String { prefix + " → " + continuation }
    public let prefix: String
    public let continuation: String
    public var frequency: Int
    public var lastUsed: Date
    public var appName: String
}

/// Constant Learning Engine & Typing History Repository (replicates Cotypist's TrainingDataCollector + Booster)
public final class LearningEngine: ObservableObject, @unchecked Sendable {
    public static let shared = LearningEngine()

    @Published public private(set) var historyRecords: [WritingHistoryRecord] = []
    @Published public private(set) var learnedPhrases: [LearnedPhraseStat] = []
    @Published public private(set) var vocabularyCounts: [String: Int] = [:]
    @Published public private(set) var totalLearnedTokens: Int = 0

    // Fast in-memory N-gram map: lowercased 2..4 word prefix -> [continuation: score]
    private var ngramMap: [String: [String: Int]] = [:]
    // Word completion prefix tree / sorted vocabulary
    private var sortedVocabulary: [(word: String, count: Int)] = []

    private let lock = NSLock()
    private var saveWorkItem: DispatchWorkItem?
    private let maxHistoryRecords = 1500

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? AppStorage.directory.appendingPathComponent("writing_history_v2.json")
        loadFromDisk()
        rebuildIndices()
    }

    // MARK: - Language Detection
    public static func detectLanguage(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    // MARK: - Recording & Constant Learning
    public func recordAcceptedCompletion(
        precedingText: String,
        acceptedText: String,
        appName: String,
        bundleId: String?,
        domain: String? = nil,
        windowTitle: String? = nil
    ) {
        let settings = AppSettings.shared
        guard settings.recordWritingForPersonalization else { return }
        guard bundleId != "com.freetypist.playground" else { return }
        if settings.isAppRecordingExcluded(bundleIdentifier: bundleId) { return }

        let combined = precedingText + acceptedText
        let (sanitizedPreceding, redacted1) = SecretSanitizer.sanitize(String(precedingText.suffix(400)))
        let (sanitizedAccepted, redacted2) = SecretSanitizer.sanitize(acceptedText)
        let redactedCount = redacted1.count + redacted2.count

        let lang = Self.detectLanguage(for: combined)

        let record = WritingHistoryRecord(
            appBundleIdentifier: bundleId ?? "com.freetypist.playground",
            appName: appName,
            domain: domain,
            windowTitle: windowTitle,
            textUpToCursor: sanitizedPreceding,
            acceptedCompletion: sanitizedAccepted,
            textLanguage: lang,
            wordCount: combined.split(whereSeparator: \.isWhitespace).count,
            wasAcceptedCompletion: true,
            redactedSecretsCount: redactedCount
        )

        lock.lock()
        // Merge if user just accepted another word in the same field within 8 seconds
        if let firstIdx = historyRecords.indices.first,
           historyRecords[firstIdx].appBundleIdentifier == record.appBundleIdentifier,
           Date().timeIntervalSince(historyRecords[firstIdx].updatedAt) < 8.0,
           (historyRecords[firstIdx].textUpToCursor + (historyRecords[firstIdx].acceptedCompletion ?? "")) == sanitizedPreceding {
            let prevAccepted = historyRecords[firstIdx].acceptedCompletion ?? ""
            historyRecords[firstIdx].acceptedCompletion = prevAccepted + sanitizedAccepted
            historyRecords[firstIdx].updatedAt = Date()
            historyRecords[firstIdx].wordCount = combined.split(whereSeparator: \.isWhitespace).count
        } else {
            historyRecords.insert(record, at: 0)
            if historyRecords.count > maxHistoryRecords {
                historyRecords.removeLast(historyRecords.count - maxHistoryRecords)
            }
        }
        lock.unlock()

        // Boost learned N-grams with 3x weight for explicitly accepted completions
        learnFromText(sanitizedPreceding + sanitizedAccepted, appName: appName, weight: 3)
        learnExplicitTransition(preceding: sanitizedPreceding, continuation: sanitizedAccepted, appName: appName, weight: 4)
        scheduleSave()
    }

    public func recordPassiveTyping(
        text: String,
        appName: String,
        bundleId: String?,
        domain: String? = nil,
        windowTitle: String? = nil
    ) {
        let settings = AppSettings.shared
        guard settings.recordWritingForPersonalization && settings.recordUnacceptedWriting else { return }
        guard bundleId != "com.freetypist.playground" else { return }
        if settings.isAppRecordingExcluded(bundleIdentifier: bundleId) { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return }
        // Record when user finishes a sentence or clause
        guard let lastChar = trimmed.last, [".", "!", "?", "\n"].contains(lastChar) else { return }

        let (sanitized, redacted) = SecretSanitizer.sanitize(String(trimmed.suffix(400)))
        let lang = Self.detectLanguage(for: sanitized)

        lock.lock()
        if let latest = historyRecords.first,
           latest.appBundleIdentifier == (bundleId ?? "com.freetypist.app"),
           sanitized == String((latest.textUpToCursor + (latest.acceptedCompletion ?? ""))
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)) {
            lock.unlock()
            return
        }

        let record = WritingHistoryRecord(
            appBundleIdentifier: bundleId ?? "com.freetypist.app",
            appName: appName,
            domain: domain,
            windowTitle: windowTitle,
            textUpToCursor: sanitized,
            acceptedCompletion: nil,
            textLanguage: lang,
            wordCount: sanitized.split(whereSeparator: \.isWhitespace).count,
            wasAcceptedCompletion: false,
            redactedSecretsCount: redacted.count
        )
        historyRecords.insert(record, at: 0)
        if historyRecords.count > maxHistoryRecords {
            historyRecords.removeLast(historyRecords.count - maxHistoryRecords)
        }
        lock.unlock()

        learnFromText(sanitized, appName: appName, weight: 1)
        scheduleSave()
    }

    public func trainOnCustomCorpus(_ rawCorpus: String, appName: String = "Style Training") {
        let sentences = rawCorpus
            .components(separatedBy: CharacterSet(charactersIn: ".\n!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }

        for sentence in sentences {
            let finalSentence = AppSettings.shared.sanitizeSecretsLocally
                ? SecretSanitizer.sanitize(sentence).sanitized
                : sentence
            let lang = Self.detectLanguage(for: finalSentence)
            let record = WritingHistoryRecord(
                appBundleIdentifier: "com.freetypist.training",
                appName: appName,
                domain: nil,
                windowTitle: "Manual Corpus Training",
                textUpToCursor: finalSentence + ".",
                acceptedCompletion: nil,
                textLanguage: lang,
                wordCount: finalSentence.split(whereSeparator: \.isWhitespace).count,
                wasAcceptedCompletion: true,
                redactedSecretsCount: 0
            )
            lock.lock()
            historyRecords.insert(record, at: 0)
            if historyRecords.count > maxHistoryRecords {
                historyRecords.removeLast(historyRecords.count - maxHistoryRecords)
            }
            lock.unlock()

            learnFromText(finalSentence, appName: appName, weight: 4)
            let words = finalSentence.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count >= 5 {
                let prefix = words.prefix(3).joined(separator: " ")
                let cont = words.dropFirst(3).prefix(5).joined(separator: " ")
                learnExplicitTransition(preceding: prefix, continuation: cont, appName: appName, weight: 4)
            }
        }
        scheduleSave()
    }

    // MARK: - N-Gram & Vocabulary Extraction
    private func learnExplicitTransition(preceding: String, continuation: String, appName: String, weight: Int) {
        let cleanCont = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanCont.count >= 3 else { return }

        let words = preceding
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        guard words.count >= 2 else { return }

        lock.lock()
        for n in 2...min(4, words.count) {
            let prefixKey = words.suffix(n).joined(separator: " ").lowercased()
            ngramMap[prefixKey, default: [:]][cleanCont, default: 0] += weight
        }

        let displayPrefix = words.suffix(min(3, words.count)).joined(separator: " ")
        if let idx = learnedPhrases.firstIndex(where: {
            $0.prefix.lowercased() == displayPrefix.lowercased() &&
            $0.continuation.lowercased() == cleanCont.lowercased()
        }) {
            learnedPhrases[idx].frequency += weight
            learnedPhrases[idx].lastUsed = Date()
        } else {
            learnedPhrases.append(
                LearnedPhraseStat(
                    prefix: displayPrefix,
                    continuation: cleanCont,
                    frequency: weight,
                    lastUsed: Date(),
                    appName: appName
                )
            )
        }
        learnedPhrases.sort { $0.frequency > $1.frequency }
        if learnedPhrases.count > 200 {
            learnedPhrases = Array(learnedPhrases.prefix(200))
        }
        lock.unlock()
    }

    private func learnFromText(_ text: String, appName: String, weight: Int) {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0) }
        guard tokens.count >= 3 else { return }

        lock.lock()
        totalLearnedTokens += tokens.count

        for token in tokens {
            let cleanWord = token.trimmingCharacters(in: .punctuationCharacters)
            if cleanWord.count >= 4 {
                vocabularyCounts[cleanWord, default: 0] += weight
            }
        }

        // Build sliding 2-gram and 3-gram -> next 2..4 words
        for i in 0..<(tokens.count - 2) {
            let bigram = "\(tokens[i]) \(tokens[i + 1])".lowercased()
            let contEnd = min(tokens.count, i + 5)
            let continuation = tokens[(i + 2)..<contEnd].joined(separator: " ")
            if continuation.count >= 3 {
                ngramMap[bigram, default: [:]][continuation, default: 0] += weight
            }

            if i + 2 < tokens.count - 1 {
                let trigram = "\(tokens[i]) \(tokens[i + 1]) \(tokens[i + 2])".lowercased()
                let tEnd = min(tokens.count, i + 6)
                let tCont = tokens[(i + 3)..<tEnd].joined(separator: " ")
                if tCont.count >= 3 {
                    ngramMap[trigram, default: [:]][tCont, default: 0] += weight
                }
            }
        }

        sortedVocabulary = vocabularyCounts
            .map { ($0.key, $0.value) }
            .sorted { $0.count > $1.count }
        lock.unlock()
    }

    // MARK: - Fast Querying for Predictions & Prompt Few-Shot RAG
    public func predictFromLearnedHistory(precedingText: String, strength: PersonalizationStrength) -> String? {
        guard strength != .off else { return nil }
        let trimmed = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return nil }

        let minScore: Int
        switch strength {
        case .off: return nil
        case .gentle: minScore = 4
        case .balanced: minScore = 2
        case .strong: minScore = 1
        }

        lock.lock()
        defer { lock.unlock() }

        // Two common words are not enough evidence to reuse an old sentence.
        if words.count >= 3 {
            for n in stride(from: min(4, words.count), through: 3, by: -1) {
                let key = words.suffix(n).joined(separator: " ").lowercased()
                if let candidates = ngramMap[key],
                   let best = candidates.max(by: { $0.value < $1.value }),
                   best.value >= minScore {
                    // Avoid repeating what is already in precedingText
                    if !precedingText.lowercased().contains(best.key.lowercased()) {
                        let needsLeadingSpace = !(precedingText.last?.isWhitespace ?? false)
                        return needsLeadingSpace ? " " + best.key : best.key
                    }
                }
            }
        }

        // 2. If typing mid-word (at Strong or Balanced strength), check learned personal vocabulary
        if (strength == .strong || strength == .balanced),
           let lastChar = precedingText.last, lastChar.isLetter,
           let currentStem = words.last, currentStem.count >= 3 {
            let lowerStem = currentStem.lowercased()
            if let match = sortedVocabulary.first(where: {
                $0.word.lowercased().hasPrefix(lowerStem) &&
                $0.word.count > currentStem.count + 1 &&
                $0.count >= minScore
            }) {
                return String(match.word.dropFirst(currentStem.count))
            }
        }

        return nil
    }

    /// Retrieves contextual writing examples for prompt personalization (Cotypist PromptCoordinator style)
    public func relevantWritingSamples(
        for precedingText: String,
        appBundleId: String?,
        domain: String?,
        strength: PersonalizationStrength
    ) -> [String] {
        let limit = strength.maxFewShotExamples
        guard limit > 0 else { return [] }

        lock.lock()
        let snapshot = historyRecords
        lock.unlock()

        let queryWords = Set(
            precedingText.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count >= 4 }
                .map(String.init)
        )

        let scored: [(record: WritingHistoryRecord, score: Int)] = snapshot.compactMap { rec in
            guard rec.appBundleIdentifier != "com.freetypist.playground" else { return nil }
            let full = (rec.textUpToCursor + (rec.acceptedCompletion ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard full.count >= 20,
                  !full.hasPrefix(precedingText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !precedingText.contains(full) else { return nil }
            var score = 0
            if let bid = appBundleId, rec.appBundleIdentifier == bid {
                score += 5
            }
            if let dom = domain, !dom.isEmpty, rec.domain == dom {
                score += 6
            }
            if rec.wasAcceptedCompletion {
                score += 3
            }
            let recWords = Set(
                full.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .filter { $0.count >= 4 }
                    .map(String.init)
            )
            let sharedWords = queryWords.intersection(recWords)
                .subtracting(["thank", "thanks", "please", "should", "could", "would", "there", "their",
                              "about", "this", "that", "with", "have", "been", "will", "your", "just"])
            guard sharedWords.count >= 2 else { return nil }
            score += sharedWords.count * 2
            return (rec, score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { ($0.record.textUpToCursor + ($0.record.acceptedCompletion ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Management & Filtering
    public func countByApp() -> [(appName: String, bundleId: String, count: Int)] {
        lock.lock()
        let snapshot = historyRecords
        lock.unlock()

        var grouped: [String: (name: String, count: Int)] = [:]
        for r in snapshot {
            let cur = grouped[r.appBundleIdentifier] ?? (r.appName, 0)
            grouped[r.appBundleIdentifier] = (cur.name, cur.count + 1)
        }
        return grouped.map { (appName: $0.value.name, bundleId: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    public func deleteRecord(id: UUID) {
        lock.lock()
        historyRecords.removeAll { $0.id == id }
        lock.unlock()
        rebuildIndices()
        CompletionLRUCache.shared.clear()
        scheduleSave()
    }

    public func deleteRecords(forAppBundleId bundleId: String) {
        lock.lock()
        historyRecords.removeAll { $0.appBundleIdentifier == bundleId }
        lock.unlock()
        rebuildIndices()
        CompletionLRUCache.shared.clear()
        scheduleSave()
    }

    public func importMigratedRecords(_ records: [WritingHistoryRecord]) -> (recordsAdded: Int, phrasesLearned: Int, vocabAdded: Int) {
        guard !records.isEmpty else { return (0, 0, 0) }
        let initialPhraseCount = learnedPhrases.count
        let initialVocabCount = vocabularyCounts.count

        lock.lock()
        func recordKey(_ record: WritingHistoryRecord) -> String {
            record.appBundleIdentifier + "|" + (record.textUpToCursor + (record.acceptedCompletion ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var existingTexts = Set(historyRecords.map(recordKey))
        var addedCount = 0
        var newlyAdded: [WritingHistoryRecord] = []

        for source in records {
            guard !AppSettings.shared.isAppRecordingExcluded(bundleIdentifier: source.appBundleIdentifier) else { continue }
            var rec = source
            let before = SecretSanitizer.sanitize(rec.textUpToCursor)
            let accepted = rec.acceptedCompletion.map { SecretSanitizer.sanitize($0) }
            rec.textUpToCursor = before.sanitized
            rec.acceptedCompletion = accepted?.sanitized
            rec.redactedSecretsCount += before.redactedTypes.count + (accepted?.redactedTypes.count ?? 0)
            let key = recordKey(rec)
            guard rec.textUpToCursor.count >= 8, !existingTexts.contains(key) else { continue }
            existingTexts.insert(key)
            historyRecords.append(rec)
            newlyAdded.append(rec)
            addedCount += 1
        }

        historyRecords.sort { $0.updatedAt > $1.updatedAt }
        if historyRecords.count > maxHistoryRecords {
            historyRecords = Array(historyRecords.prefix(maxHistoryRecords))
        }
        lock.unlock()

        for rec in newlyAdded {
            let full = rec.textUpToCursor + (rec.acceptedCompletion ?? "")
            learnFromText(full, appName: rec.appName, weight: rec.wasAcceptedCompletion ? 3 : 2)
            if let accepted = rec.acceptedCompletion, !accepted.isEmpty {
                learnExplicitTransition(preceding: rec.textUpToCursor, continuation: accepted, appName: rec.appName, weight: 4)
            } else {
                // Also extract natural clause transitions from Cotypist's textUpToCursor
                let words = rec.textUpToCursor.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
                if words.count >= 5 {
                    let prefix = words.prefix(3).joined(separator: " ")
                    let cont = words.dropFirst(3).prefix(5).joined(separator: " ")
                    learnExplicitTransition(preceding: prefix, continuation: cont, appName: rec.appName, weight: 3)
                }
            }
        }

        saveToDisk()
        let phrasesDelta = max(0, learnedPhrases.count - initialPhraseCount)
        let vocabDelta = max(0, vocabularyCounts.count - initialVocabCount)
        return (addedCount, phrasesDelta, vocabDelta)
    }

    public func eraseAllHistory() {
        lock.lock()
        historyRecords.removeAll()
        learnedPhrases.removeAll()
        vocabularyCounts.removeAll()
        ngramMap.removeAll()
        sortedVocabulary.removeAll()
        totalLearnedTokens = 0
        lock.unlock()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        CompletionLRUCache.shared.clear()
        saveToDisk()
    }

    // MARK: - Persistence
    private func rebuildIndices() {
        lock.lock()
        ngramMap.removeAll()
        learnedPhrases.removeAll()
        sortedVocabulary.removeAll()
        vocabularyCounts.removeAll()
        totalLearnedTokens = 0
        let snapshot = historyRecords
        lock.unlock()

        for rec in snapshot.reversed() where rec.appBundleIdentifier != "com.freetypist.playground" {
            let full = rec.textUpToCursor + (rec.acceptedCompletion ?? "")
            learnFromText(full, appName: rec.appName, weight: rec.wasAcceptedCompletion ? 2 : 1)
            if let accepted = rec.acceptedCompletion, !accepted.isEmpty {
                learnExplicitTransition(preceding: rec.textUpToCursor, continuation: accepted, appName: rec.appName, weight: 3)
            }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func saveToDisk() {
        lock.lock()
        let snapshot = historyRecords
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([WritingHistoryRecord].self, from: data) else {
            return
        }
        self.historyRecords = decoded
    }

}
