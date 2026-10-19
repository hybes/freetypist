import Foundation
import SwiftUI

public enum AIProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case localEmbedded = "On-Device Engine (Local Metal)"
    case ollama = "Ollama (Local)"
    case mock = "Built-in Instant Predictor"

    public var id: String { rawValue }

    public var defaultBaseURL: String {
        switch self {
        case .localEmbedded: return "http://127.0.0.1:58855/v1"
        case .ollama: return "http://127.0.0.1:11434"
        case .mock: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .localEmbedded: return "default"
        case .ollama: return "qwen2.5:1.5b"
        case .mock: return "offline-predictive"
        }
    }

    public var requiresAPIKey: Bool {
        return false
    }
}

public enum CompletionLengthPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case short = "Short (~ 1–2 words)"
    case medium = "Medium (~ 2–4 words)"
    case long = "Long (~ 4–7 words)"
    case veryLong = "Very Long (~ 7–10 words)"
    case ultraLong = "Ultra Long (~ 10–15 words)"

    public var id: String { rawValue }

    public var maxTokens: Int {
        switch self {
        case .short: return 8
        case .medium: return 16
        case .long: return 28
        case .veryLong: return 40
        case .ultraLong: return 60
        }
    }

    public var maxWords: Int {
        switch self {
        case .short: return 2
        case .medium: return 4
        case .long: return 7
        case .veryLong: return 10
        case .ultraLong: return 15
        }
    }
}

public enum GhostColorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case systemGray = "System Gray (Classic)"
    case electricIndigo = "Electric Indigo"
    case cyanGlow = "Cyan Glow"
    case emerald = "Emerald Green"
    case amberGold = "Amber Gold"

    public var id: String { rawValue }

    public var swiftUIColor: Color {
        switch self {
        case .systemGray: return .secondary
        case .electricIndigo: return .indigo
        case .cyanGlow: return .cyan
        case .emerald: return .mint
        case .amberGold: return .orange
        }
    }
}

public enum EscapeKeyBehavior: String, CaseIterable, Identifiable, Codable, Sendable {
    case dismissThenPassToApp = "Dismiss suggestion (second press goes to app)"
    case pauseBriefly = "Pause completions for 15 seconds"
    case offUntilAppSwitch = "Turn completions off until I switch apps"
    case passToApp = "Do nothing (always send Escape to the app)"

    public var id: String { rawValue }
}

public enum TonePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case natural = "Natural & Balanced"
    case professional = "Professional & Formal"
    case casual = "Casual & Friendly"
    case concise = "Concise & Direct"
    case technical = "Technical & Code-Aware"
    case bulletPoints = "Bullet Points / Structured"
    case executive = "Executive & Persuasive"
    case custom = "Custom Instructions"

    public var id: String { rawValue }

    public var promptInstruction: String {
        switch self {
        case .natural:
            return "Write in a natural, balanced voice matching the preceding text."
        case .professional:
            return "Use clear, professional, respectful, and well-structured business language."
        case .casual:
            return "Keep it relaxed, friendly, and conversational with natural phrasing."
        case .concise:
            return "Be extremely concise, eliminating filler words and getting straight to the point."
        case .technical:
            return "Use precise technical terminology, exact syntax, and standard engineering terminology."
        case .bulletPoints:
            return "Structure completions in neat, organized points or crisp phrases."
        case .executive:
            return "Write with high-impact, action-oriented executive clarity and strategic focus."
        case .custom:
            return ""
        }
    }
}

public struct AppRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var bundleIdentifier: String
    public var appName: String
    public var isExcluded: Bool
    public var customTone: TonePreset?
    public var customInstructions: String
    public var disableTabKey: Bool
    public var disableAutocorrect: Bool
    public var stopRecordingWriting: Bool
    public var disableMidLineCompletions: Bool

    public init(
        bundleIdentifier: String,
        appName: String,
        isExcluded: Bool = true,
        customTone: TonePreset? = nil,
        customInstructions: String = "",
        disableTabKey: Bool = false,
        disableAutocorrect: Bool = false,
        stopRecordingWriting: Bool = false,
        disableMidLineCompletions: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.isExcluded = isExcluded
        self.customTone = customTone
        self.customInstructions = customInstructions
        self.disableTabKey = disableTabKey
        self.disableAutocorrect = disableAutocorrect
        self.stopRecordingWriting = stopRecordingWriting
        self.disableMidLineCompletions = disableMidLineCompletions
    }
}

public final class AppSettings: ObservableObject, @unchecked Sendable {
    public static let shared = AppSettings()

    // General & Completion Settings (Cotypist GeneralSettingsPane)
    @Published public var isEnabled: Bool { didSet { save() } }
    @Published public var launchAtLogin: Bool { didSet { save() } }
    @Published public var showWordCountInMenuBar: Bool { didSet { save() } }
    @Published public var completionLength: CompletionLengthPreset { didSet { save() } }
    @Published public var enableMidLineCompletions: Bool { didSet { save() } }
    @Published public var hideCompletionsOnSuspectedTypo: Bool { didSet { save() } }
    @Published public var showSuggestedTypoFixes: Bool { didSet { save() } }
    @Published public var debounceMs: Int { didSet { save() } }
    @Published public var minTriggerCharacters: Int { didSet { save() } }
    @Published public var playSoundOnAccept: Bool { didSet { save() } }
    @Published public var showShortcutBadges: Bool { didSet { save() } }
    @Published public var ghostTextOpacity: Double { didSet { save() } }
    @Published public var ghostTextColorPreset: GhostColorPreset { didSet { save() } }
    @Published public var ghostFontSizeOffset: Double { didSet { save() } }
    @Published public var autoSpaceAfterAccept: Bool { didSet { save() } }

    // Model, AI Provider & Granular Sampling / Hardware Controls
    @Published public var activeProvider: AIProviderType { didSet { save() } }
    @Published public var baseURL: String { didSet { save() } }
    @Published public var apiKey: String { didSet { save() } }
    @Published public var modelName: String { didSet { save() } }
    @Published public var maxTokens: Int { didSet { save() } }
    @Published public var temperature: Double { didSet { save() } }
    @Published public var topP: Double { didSet { save() } }
    @Published public var topK: Int { didSet { save() } }
    @Published public var repeatPenalty: Double { didSet { save() } }
    @Published public var contextWindowSize: Int { didSet { save() } }
    @Published public var gpuLayers: Int { didSet { save() } }
    @Published public var cpuThreads: Int { didSet { save() } }
    @Published public var kvCacheQuantization: String { didSet { save() } }
    @Published public var selectedLoRAAdapterPath: String { didSet { save() } }

    // Personalization & Constant Learning (Cotypist PersonalizationSettingsPane)
    @Published public var personaDescription: String { didSet { save() } }
    @Published public var selectedTone: TonePreset { didSet { save() } }
    @Published public var customToneInstructions: String { didSet { save() } }
    @Published public var personalizationStrength: PersonalizationStrength { didSet { save() } }
    @Published public var recordWritingForPersonalization: Bool { didSet { save() } }
    @Published public var recordUnacceptedWriting: Bool { didSet { save() } }
    @Published public var personalDictionary: [String: String] { didSet { save() } }

    // Slash Commands & Dynamic Snippets (Power-User Extra)
    @Published public var enableSlashCommands: Bool { didSet { save() } }
    @Published public var slashCommands: [String: String] { didSet { save() } }

    // Deep Local Context Awareness (100% On-Device)
    @Published public var useClipboardContext: Bool { didSet { save() } }
    @Published public var useWindowEnvironmentContext: Bool { didSet { save() } }
    @Published public var readSurroundingWindowText: Bool { didSet { save() } }
    @Published public var trackCrossAppContext: Bool { didSet { save() } }
    @Published public var trackMultiClipboardHistory: Bool { didSet { save() } }
    @Published public var includeSystemAndUserMetadata: Bool { didSet { save() } }
    @Published public var sanitizeSecretsLocally: Bool { didSet { save() } }

    // Emoji Settings (Cotypist EmojiSettingsPane)
    @Published public var enableEmojiSuggestions: Bool { didSet { save() } }
    @Published public var suggestEmojiFromEmoticons: Bool { didSet { save() } }
    @Published public var preferredEmojiSkinTone: EmojiSkinTone { didSet { save() } }
    @Published public var includeNeutralEmojiVariant: Bool { didSet { save() } }
    @Published public var preferredEmojiGender: EmojiGenderPreference { didSet { save() } }

    // Cotypist Labs Settings (Word Alternatives & Contextual Thesaurus)
    @Published public var enableWordAlternatives: Bool { didSet { save() } }
    @Published public var enableContextualSynonyms: Bool { didSet { save() } }

    // Battery & Performance Settings (Cotypist BatterySettingsPane)
    @Published public var batteryOnlyOnDemand: Bool { didSet { save() } }
    @Published public var batteryShorterCompletions: Bool { didSet { save() } }
    @Published public var batteryUseSmallerModel: Bool { didSet { save() } }
    @Published public var idleEngineSleepMinutes: Int { didSet { save() } }

    // Shortcuts & Behavior (Cotypist ShortcutsSettingsPane)
    @Published public var acceptAllKey: String { didSet { save() } }
    @Published public var acceptWordKey: String { didSet { save() } }
    @Published public var dismissKey: String { didSet { save() } }
    @Published public var escapeBehavior: EscapeKeyBehavior { didSet { save() } }
    @Published public var includeTrailingSpaceOnWordAccept: Bool { didSet { save() } }
    @Published public var includeTrailingPunctuationOnWordAccept: Bool { didSet { save() } }

    // App Rules
    @Published public var appRules: [AppRule] { didSet { save() } }

    // Runtime Temporary Pause State
    public var pausedUntilDate: Date?
    public var pausedAppBundleId: String?

    private init() {
        let defaults = UserDefaults.standard

        self.isEnabled = defaults.object(forKey: "ft_isEnabled") as? Bool ?? true
        self.launchAtLogin = defaults.object(forKey: "ft_launchAtLogin") as? Bool ?? false
        self.showWordCountInMenuBar = defaults.object(forKey: "ft_showWordCountInMenuBar") as? Bool ?? true

        let lenRaw = defaults.string(forKey: "ft_completionLength") ?? CompletionLengthPreset.medium.rawValue
        self.completionLength = CompletionLengthPreset(rawValue: lenRaw) ?? .medium
        self.enableMidLineCompletions = defaults.object(forKey: "ft_enableMidLineCompletions") as? Bool ?? true
        self.hideCompletionsOnSuspectedTypo = defaults.object(forKey: "ft_hideOnTypo") as? Bool ?? true
        self.showSuggestedTypoFixes = defaults.object(forKey: "ft_showTypoFixes") as? Bool ?? true

        self.debounceMs = defaults.object(forKey: "ft_debounceMs") as? Int ?? 140
        self.minTriggerCharacters = defaults.object(forKey: "ft_minTriggerCharacters") as? Int ?? 2
        self.playSoundOnAccept = defaults.object(forKey: "ft_playSoundOnAccept") as? Bool ?? false
        self.showShortcutBadges = defaults.object(forKey: "ft_showInlineBadges_v2") as? Bool ?? false
        self.ghostTextOpacity = defaults.object(forKey: "ft_ghostTextOpacity") as? Double ?? 0.65
        let colorRaw = defaults.string(forKey: "ft_ghostColorPreset") ?? GhostColorPreset.systemGray.rawValue
        self.ghostTextColorPreset = GhostColorPreset(rawValue: colorRaw) ?? .systemGray
        self.ghostFontSizeOffset = defaults.object(forKey: "ft_ghostFontSizeOffset") as? Double ?? 0.0
        self.autoSpaceAfterAccept = defaults.object(forKey: "ft_autoSpaceAfterAccept") as? Bool ?? true

        let providerRaw = defaults.string(forKey: "ft_activeProvider") ?? AIProviderType.localEmbedded.rawValue
        let provider = AIProviderType(rawValue: providerRaw) ?? .localEmbedded
        self.activeProvider = provider
        self.baseURL = defaults.string(forKey: "ft_baseURL") ?? provider.defaultBaseURL
        self.apiKey = defaults.string(forKey: "ft_apiKey") ?? ""
        self.modelName = defaults.string(forKey: "ft_modelName") ?? provider.defaultModel
        self.maxTokens = defaults.object(forKey: "ft_maxTokens") as? Int ?? 24
        self.temperature = defaults.object(forKey: "ft_temperature") as? Double ?? 0.25
        self.topP = defaults.object(forKey: "ft_topP") as? Double ?? 0.90
        self.topK = defaults.object(forKey: "ft_topK") as? Int ?? 40
        self.repeatPenalty = defaults.object(forKey: "ft_repeatPenalty") as? Double ?? 1.10
        self.contextWindowSize = defaults.object(forKey: "ft_contextWindowSize") as? Int ?? 1024
        self.gpuLayers = defaults.object(forKey: "ft_gpuLayers") as? Int ?? 99
        self.cpuThreads = defaults.object(forKey: "ft_cpuThreads") as? Int ?? 2
        self.kvCacheQuantization = defaults.string(forKey: "ft_kvCacheQuant") ?? "q8_0"
        self.selectedLoRAAdapterPath = defaults.string(forKey: "ft_selectedLoRA") ?? ""

        self.personaDescription = defaults.string(forKey: "ft_personaDescription") ?? "Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."
        let toneRaw = defaults.string(forKey: "ft_selectedTone") ?? TonePreset.natural.rawValue
        self.selectedTone = TonePreset(rawValue: toneRaw) ?? .natural
        self.customToneInstructions = defaults.string(forKey: "ft_customToneInstructions") ?? ""

        let strengthRaw = defaults.string(forKey: "ft_personalizationStrength") ?? PersonalizationStrength.strong.rawValue
        self.personalizationStrength = PersonalizationStrength(rawValue: strengthRaw) ?? .strong
        self.recordWritingForPersonalization = defaults.object(forKey: "ft_recordWriting") as? Bool ?? true
        self.recordUnacceptedWriting = defaults.object(forKey: "ft_recordUnaccepted") as? Bool ?? true
        self.personalDictionary = (defaults.dictionary(forKey: "ft_personalDictionary") as? [String: String]) ?? [
            "btw": "by the way",
            "lmk": "let me know if you have any questions",
            "imo": "in my opinion",
            "fyi": "for your information",
            "tl;dr": "too long; didn't read — summary:",
            "wfh": "working from home today",
            "eod": "by the end of the day",
            "asap": "as soon as possible"
        ]

        self.enableSlashCommands = defaults.object(forKey: "ft_enableSlashCommands") as? Bool ?? true
        self.slashCommands = (defaults.dictionary(forKey: "ft_slashCommands_v2") as? [String: String]) ?? [
            "/sig": "Best regards,\n\(NSFullUserName().isEmpty ? "Alex" : NSFullUserName())",
            "/followup": "Just following up on my previous message to see if you had any thoughts or questions.",
            "/lgtm": "Looks good to me. Approved and ready to merge.",
            "/cal": "Feel free to grab any time on my calendar that works best for you.",
            "/standup": "Yesterday: Completed core implementation & tests. Today: Polishing UI & benchmarks. Blockers: None.",
            "/review": "Thanks for putting this together. I've reviewed the changes and left a few comments inline.",
            "/meeting": "Let's sync briefly on this tomorrow afternoon to align on next steps."
        ]

        self.useClipboardContext = defaults.object(forKey: "ft_useClipboardContext") as? Bool ?? true
        self.useWindowEnvironmentContext = defaults.object(forKey: "ft_useWindowContext") as? Bool ?? true
        self.readSurroundingWindowText = defaults.object(forKey: "ft_readSurroundingWindowText") as? Bool ?? true
        self.trackCrossAppContext = defaults.object(forKey: "ft_trackCrossAppContext") as? Bool ?? true
        self.trackMultiClipboardHistory = defaults.object(forKey: "ft_trackMultiClipboardHistory") as? Bool ?? true
        self.includeSystemAndUserMetadata = defaults.object(forKey: "ft_includeSystemMetadata") as? Bool ?? true
        self.sanitizeSecretsLocally = defaults.object(forKey: "ft_sanitizeSecretsLocally") as? Bool ?? false

        self.enableEmojiSuggestions = defaults.object(forKey: "ft_enableEmoji_v3") as? Bool ?? false
        self.suggestEmojiFromEmoticons = defaults.object(forKey: "ft_emojiEmoticons_v3") as? Bool ?? false
        let skinRaw = defaults.string(forKey: "ft_emojiSkinTone") ?? EmojiSkinTone.neutral.rawValue
        self.preferredEmojiSkinTone = EmojiSkinTone(rawValue: skinRaw) ?? .neutral
        self.includeNeutralEmojiVariant = defaults.object(forKey: "ft_emojiNeutralVar") as? Bool ?? true
        let genderRaw = defaults.string(forKey: "ft_emojiGender") ?? EmojiGenderPreference.neutral.rawValue
        self.preferredEmojiGender = EmojiGenderPreference(rawValue: genderRaw) ?? .neutral

        self.enableWordAlternatives = defaults.object(forKey: "ft_enableWordAlternatives") as? Bool ?? true
        self.enableContextualSynonyms = defaults.object(forKey: "ft_enableSynonyms") as? Bool ?? true

        self.batteryOnlyOnDemand = defaults.object(forKey: "ft_batteryOnDemand") as? Bool ?? false
        self.batteryShorterCompletions = defaults.object(forKey: "ft_batteryShorter") as? Bool ?? true
        self.batteryUseSmallerModel = defaults.object(forKey: "ft_batterySmallerModel") as? Bool ?? false
        self.idleEngineSleepMinutes = defaults.object(forKey: "ft_idleSleepMins") as? Int ?? 15

        self.acceptAllKey = defaults.string(forKey: "ft_acceptAllKey") ?? "Tab"
        self.acceptWordKey = defaults.string(forKey: "ft_acceptWordKey") ?? "⌥ Tab / `"
        self.dismissKey = defaults.string(forKey: "ft_dismissKey") ?? "Esc"
        let escRaw = defaults.string(forKey: "ft_escapeBehavior") ?? EscapeKeyBehavior.dismissThenPassToApp.rawValue
        self.escapeBehavior = EscapeKeyBehavior(rawValue: escRaw) ?? .dismissThenPassToApp
        self.includeTrailingSpaceOnWordAccept = defaults.object(forKey: "ft_wordTrailingSpace") as? Bool ?? true
        self.includeTrailingPunctuationOnWordAccept = defaults.object(forKey: "ft_wordTrailingPunct") as? Bool ?? true

        if let data = defaults.data(forKey: "ft_appRules_v2"),
           let rules = try? JSONDecoder().decode([AppRule].self, from: data) {
            self.appRules = rules
        } else {
            self.appRules = [
                AppRule(bundleIdentifier: "com.agilebits.onepassword", appName: "1Password", isExcluded: true, stopRecordingWriting: true),
                AppRule(bundleIdentifier: "com.1password.1password", appName: "1Password 8", isExcluded: true, stopRecordingWriting: true),
                AppRule(bundleIdentifier: "com.apple.keychainaccess", appName: "Keychain Access", isExcluded: true, stopRecordingWriting: true),
                AppRule(bundleIdentifier: "com.apple.Passwords", appName: "Apple Passwords", isExcluded: true, stopRecordingWriting: true),
                AppRule(bundleIdentifier: "com.bitwarden.desktop", appName: "Bitwarden", isExcluded: true, stopRecordingWriting: true),
                AppRule(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", isExcluded: false, customTone: .casual, customInstructions: "Keep messages concise, friendly, and conversational."),
                AppRule(bundleIdentifier: "com.apple.mail", appName: "Apple Mail", isExcluded: false, customTone: .professional, customInstructions: "Write clear, polite, well-structured email responses."),
                AppRule(bundleIdentifier: "com.apple.Notes", appName: "Apple Notes", isExcluded: false, customTone: .natural, customInstructions: "Use clean, structured sentences and action items.")
            ]
        }
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "ft_isEnabled")
        defaults.set(launchAtLogin, forKey: "ft_launchAtLogin")
        defaults.set(showWordCountInMenuBar, forKey: "ft_showWordCountInMenuBar")
        defaults.set(completionLength.rawValue, forKey: "ft_completionLength")
        defaults.set(enableMidLineCompletions, forKey: "ft_enableMidLineCompletions")
        defaults.set(hideCompletionsOnSuspectedTypo, forKey: "ft_hideOnTypo")
        defaults.set(showSuggestedTypoFixes, forKey: "ft_showTypoFixes")

        defaults.set(debounceMs, forKey: "ft_debounceMs")
        defaults.set(minTriggerCharacters, forKey: "ft_minTriggerCharacters")
        defaults.set(playSoundOnAccept, forKey: "ft_playSoundOnAccept")
        defaults.set(showShortcutBadges, forKey: "ft_showInlineBadges_v2")
        defaults.set(ghostTextOpacity, forKey: "ft_ghostTextOpacity")
        defaults.set(ghostTextColorPreset.rawValue, forKey: "ft_ghostColorPreset")
        defaults.set(ghostFontSizeOffset, forKey: "ft_ghostFontSizeOffset")
        defaults.set(autoSpaceAfterAccept, forKey: "ft_autoSpaceAfterAccept")

        defaults.set(activeProvider.rawValue, forKey: "ft_activeProvider")
        defaults.set(baseURL, forKey: "ft_baseURL")
        defaults.set(apiKey, forKey: "ft_apiKey")
        defaults.set(modelName, forKey: "ft_modelName")
        defaults.set(maxTokens, forKey: "ft_maxTokens")
        defaults.set(temperature, forKey: "ft_temperature")
        defaults.set(topP, forKey: "ft_topP")
        defaults.set(topK, forKey: "ft_topK")
        defaults.set(repeatPenalty, forKey: "ft_repeatPenalty")
        defaults.set(contextWindowSize, forKey: "ft_contextWindowSize")
        defaults.set(gpuLayers, forKey: "ft_gpuLayers")
        defaults.set(cpuThreads, forKey: "ft_cpuThreads")
        defaults.set(kvCacheQuantization, forKey: "ft_kvCacheQuant")
        defaults.set(selectedLoRAAdapterPath, forKey: "ft_selectedLoRA")

        defaults.set(personaDescription, forKey: "ft_personaDescription")
        defaults.set(selectedTone.rawValue, forKey: "ft_selectedTone")
        defaults.set(customToneInstructions, forKey: "ft_customToneInstructions")
        defaults.set(personalizationStrength.rawValue, forKey: "ft_personalizationStrength")
        defaults.set(recordWritingForPersonalization, forKey: "ft_recordWriting")
        defaults.set(recordUnacceptedWriting, forKey: "ft_recordUnaccepted")
        defaults.set(personalDictionary, forKey: "ft_personalDictionary")

        defaults.set(enableSlashCommands, forKey: "ft_enableSlashCommands")
        defaults.set(slashCommands, forKey: "ft_slashCommands_v2")

        defaults.set(useClipboardContext, forKey: "ft_useClipboardContext")
        defaults.set(useWindowEnvironmentContext, forKey: "ft_useWindowContext")
        defaults.set(readSurroundingWindowText, forKey: "ft_readSurroundingWindowText")
        defaults.set(trackCrossAppContext, forKey: "ft_trackCrossAppContext")
        defaults.set(trackMultiClipboardHistory, forKey: "ft_trackMultiClipboardHistory")
        defaults.set(includeSystemAndUserMetadata, forKey: "ft_includeSystemMetadata")
        defaults.set(sanitizeSecretsLocally, forKey: "ft_sanitizeSecretsLocally")

        defaults.set(enableEmojiSuggestions, forKey: "ft_enableEmoji_v3")
        defaults.set(suggestEmojiFromEmoticons, forKey: "ft_emojiEmoticons_v3")
        defaults.set(preferredEmojiSkinTone.rawValue, forKey: "ft_emojiSkinTone")
        defaults.set(includeNeutralEmojiVariant, forKey: "ft_emojiNeutralVar")
        defaults.set(preferredEmojiGender.rawValue, forKey: "ft_emojiGender")

        defaults.set(enableWordAlternatives, forKey: "ft_enableWordAlternatives")
        defaults.set(enableContextualSynonyms, forKey: "ft_enableSynonyms")

        defaults.set(batteryOnlyOnDemand, forKey: "ft_batteryOnDemand")
        defaults.set(batteryShorterCompletions, forKey: "ft_batteryShorter")
        defaults.set(batteryUseSmallerModel, forKey: "ft_batterySmallerModel")
        defaults.set(idleEngineSleepMinutes, forKey: "ft_idleSleepMins")

        defaults.set(acceptAllKey, forKey: "ft_acceptAllKey")
        defaults.set(acceptWordKey, forKey: "ft_acceptWordKey")
        defaults.set(dismissKey, forKey: "ft_dismissKey")
        defaults.set(escapeBehavior.rawValue, forKey: "ft_escapeBehavior")
        defaults.set(includeTrailingSpaceOnWordAccept, forKey: "ft_wordTrailingSpace")
        defaults.set(includeTrailingPunctuationOnWordAccept, forKey: "ft_wordTrailingPunct")

        if let encoded = try? JSONEncoder().encode(appRules) {
            defaults.set(encoded, forKey: "ft_appRules_v2")
        }
    }

    public func rule(for bundleIdentifier: String?) -> AppRule? {
        guard let bundleIdentifier = bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return appRules.first { $0.bundleIdentifier.lowercased() == bundleIdentifier.lowercased() }
    }

    public func mergeImportedAppRule(_ rule: AppRule) {
        if let idx = appRules.firstIndex(where: { $0.bundleIdentifier.lowercased() == rule.bundleIdentifier.lowercased() }) {
            appRules[idx] = rule
        } else {
            appRules.append(rule)
        }
        save()
    }

    public func isAppExcluded(bundleIdentifier: String?) -> Bool {
        if let until = pausedUntilDate, Date() < until {
            return true
        }
        if let pausedApp = pausedAppBundleId, let bid = bundleIdentifier, pausedApp == bid {
            return true
        }
        return rule(for: bundleIdentifier)?.isExcluded ?? false
    }

    public func isAppRecordingExcluded(bundleIdentifier: String?) -> Bool {
        guard let r = rule(for: bundleIdentifier) else { return false }
        return r.isExcluded || r.stopRecordingWriting
    }

    public func effectiveTone(for bundleIdentifier: String?) -> TonePreset {
        if let r = rule(for: bundleIdentifier), let tone = r.customTone {
            return tone
        }
        return selectedTone
    }

    public func effectiveCustomInstructions(for bundleIdentifier: String?) -> String {
        var parts: [String] = []
        if !personaDescription.isEmpty {
            parts.append(personaDescription)
        }
        if !customToneInstructions.isEmpty {
            parts.append(customToneInstructions)
        }
        if let r = rule(for: bundleIdentifier), !r.customInstructions.isEmpty {
            parts.append("App-specific instructions (\(r.appName)): \(r.customInstructions)")
        }
        return parts.joined(separator: " ")
    }

    public func exportProfileJSON() -> String {
        let payload: [String: Any] = [
            "personaDescription": personaDescription,
            "selectedTone": selectedTone.rawValue,
            "personalizationStrength": personalizationStrength.rawValue,
            "personalDictionary": personalDictionary,
            "slashCommands": slashCommands
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
