import AppKit
import SwiftUI

/// Custom AppKit NSTextView that renders pixel-perfect inline ghost text right at the cursor
/// and intercepts Tab, Option+Tab / `, and Escape.
public final class GhostAwareNSTextView: NSTextView {
    public var ghostSuggestion: String = "" {
        didSet { needsDisplay = true }
    }
    public var hasInterceptableAction: Bool = false
    public var ghostOpacity: Double = 0.65 {
        didSet { needsDisplay = true }
    }
    public var onTabAcceptFull: (() -> Bool)?
    public var onAcceptNextWord: (() -> Bool)?
    public var onEscapeDismiss: (() -> Bool)?

    public override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let active = !ghostSuggestion.isEmpty || hasInterceptableAction

        // Tab (keyCode 48)
        if keyCode == 48 && active {
            if flags.contains(.option) || flags.contains(.shift) {
                if onAcceptNextWord?() == true { return }
            } else {
                if onTabAcceptFull?() == true { return }
            }
        }

        // Backtick ` (keyCode 50) - word/full shortcut when suggestion is active
        if keyCode == 50 && !ghostSuggestion.isEmpty && flags.isEmpty {
            if onAcceptNextWord?() == true { return }
        }

        // Escape (keyCode 53)
        if keyCode == 53 && active {
            if onEscapeDismiss?() == true { return }
        }

        super.keyDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !ghostSuggestion.isEmpty,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else {
            return
        }

        let selRange = self.selectedRange()
        guard selRange.length == 0 else { return }

        let nsStr = self.string as NSString
        let cursorIndex = min(selRange.location, nsStr.length)

        var glyphRect: NSRect = .zero
        if nsStr.length == 0 {
            glyphRect = NSRect(x: textContainerInset.width + 5, y: textContainerInset.height, width: 0, height: 18)
        } else if cursorIndex > 0 {
            let charIdx = cursorIndex - 1
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIdx)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: textContainer)
            if nsStr.character(at: charIdx) == 10 { // newline
                glyphRect = NSRect(
                    x: textContainerInset.width + 5,
                    y: rect.maxY + textContainerInset.height,
                    width: 0,
                    height: rect.height
                )
            } else {
                glyphRect = NSRect(
                    x: rect.maxX + textContainerInset.width,
                    y: rect.minY + textContainerInset.height,
                    width: 0,
                    height: rect.height
                )
            }
        } else {
            glyphRect = NSRect(x: textContainerInset.width + 5, y: textContainerInset.height, width: 0, height: 18)
        }

        let fontToUse = self.font ?? NSFont.systemFont(ofSize: 15)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fontToUse,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(CGFloat(ghostOpacity))
        ]

        let drawPoint = NSPoint(x: glyphRect.origin.x, y: glyphRect.origin.y)
        let singleLineGhost = ghostSuggestion.components(separatedBy: .newlines).first ?? ghostSuggestion
        (singleLineGhost as NSString).draw(at: drawPoint, withAttributes: attrs)
    }
}

public struct PlaygroundEditorRepresentable: NSViewRepresentable {
    @Binding public var text: String
    @Binding public var selectedText: String
    public var ghostSuggestion: String
    public var hasInterceptableAction: Bool
    public var ghostOpacity: Double
    public var onTabAcceptFull: () -> Bool
    public var onAcceptNextWord: () -> Bool
    public var onEscapeDismiss: () -> Bool

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = GhostAwareNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        textView.string = text
        textView.ghostSuggestion = ghostSuggestion
        textView.hasInterceptableAction = hasInterceptableAction
        textView.ghostOpacity = ghostOpacity
        textView.onTabAcceptFull = onTabAcceptFull
        textView.onAcceptNextWord = onAcceptNextWord
        textView.onEscapeDismiss = onEscapeDismiss

        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? GhostAwareNSTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
            let endLoc = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endLoc, length: 0))
        }
        textView.ghostSuggestion = ghostSuggestion
        textView.hasInterceptableAction = hasInterceptableAction
        textView.ghostOpacity = ghostOpacity
        textView.onTabAcceptFull = onTabAcceptFull
        textView.onAcceptNextWord = onAcceptNextWord
        textView.onEscapeDismiss = onEscapeDismiss
        textView.needsDisplay = true
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaygroundEditorRepresentable

        init(_ parent: PlaygroundEditorRepresentable) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newStr = tv.string
            if parent.text != newStr {
                parent.text = newStr
            }
            tv.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            let nsStr = tv.string as NSString
            if range.length > 0 && range.location + range.length <= nsStr.length {
                let sel = nsStr.substring(with: range)
                if parent.selectedText != sel {
                    parent.selectedText = sel
                }
            } else if !parent.selectedText.isEmpty {
                parent.selectedText = ""
            }
            tv.needsDisplay = true
        }
    }
}

public struct PlaygroundView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modelManager = LocalModelManager.shared
    @ObservedObject var inferenceService = LocalInferenceService.shared
    @ObservedObject var learningEngine = LearningEngine.shared
    @ObservedObject var resourceMonitor = SystemResourceMonitor.shared
    @ObservedObject var deepContext = DeepContextCollector.shared

    @State private var inputText: String = "Thank you for "
    @State private var selectedText: String = ""
    @State private var playgroundSuggestion: String = ""
    @State private var activeTypoFix: AutocorrectSuggestion?
    @State private var activeEmojis: [EmojiCandidate] = []
    @State private var activeSlashMatch: (trigger: String, expansion: String, replacementLength: Int)?
    @State private var wordAlternatives: [WordAlternativeItem] = []
    @State private var synonyms: [WordAlternativeItem] = []
    @State private var lastLatency: Int = 0
    @State private var lastSourceLabel: String = "Ready"

    private let samplePrompts: [(label: String, text: String)] = [
        ("Email Reply", "Thank you for "),
        ("Spelling & Typo Fix", "I definately want to focuso on a better expeexperience "),
        ("Project Update", "I think we should "),
        ("Quick Follow-up", "Just wanted to follow "),
        ("Learned Phrase", "In order to keep CPU and memory usage minimal, ")
    ]

    public init() {}

    private var hasAnyActiveAction: Bool {
        !playgroundSuggestion.isEmpty || activeTypoFix != nil || !activeEmojis.isEmpty || activeSlashMatch != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clean Header
            HStack(spacing: 12) {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let nsImg = NSImage(contentsOf: iconURL) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                } else if let fallbackImg = NSImage(contentsOfFile: "Resources/AppIcon_1024.png") {
                    Image(nsImage: fallbackImg)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("FreeTypist Playground")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Type naturally below. Press Tab to accept a completion or fix a typo, and Option+Tab to accept word-by-word.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(inferenceService.isServerRunning ? Color.green : Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text(inferenceService.isServerRunning ? "\(modelManager.selectedModel.name)" : "On-Device Predictor")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            // Sample Prompts Bar
            HStack(spacing: 8) {
                Text("Try:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .fixedSize()

                ForEach(samplePrompts, id: \.label) { item in
                    Button(action: {
                        inputText = item.text
                        generateSuggestion(for: item.text, force: true)
                    }) {
                        Text(item.label)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button("Clear") {
                    inputText = ""
                    dismissSuggestion()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Main Ghost-Aware Text Editor
            PlaygroundEditorRepresentable(
                text: $inputText,
                selectedText: $selectedText,
                ghostSuggestion: playgroundSuggestion,
                hasInterceptableAction: hasAnyActiveAction,
                ghostOpacity: settings.ghostTextOpacity,
                onTabAcceptFull: {
                    acceptFull()
                    return true
                },
                onAcceptNextWord: {
                    acceptWord()
                    return true
                },
                onEscapeDismiss: {
                    dismissSuggestion()
                    return true
                }
            )
            .frame(minHeight: 195, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .onChange(of: inputText) { _, newText in
                generateSuggestion(for: newText)
            }
            .onChange(of: selectedText) { _, newSel in
                synonyms = SmartWritingFeatures.lookupSynonyms(for: newSel)
            }

            // Clean Action & Correction Bar
            HStack(spacing: 10) {
                if let typo = activeTypoFix {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Fix typo:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(typo.misspelledWord)
                            .font(.caption)
                            .strikethrough(true, color: .red)
                            .foregroundColor(.red.opacity(0.9))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(typo.correctedWord.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.green)
                        Text("(Press Tab)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.1)))
                } else if let slash = activeSlashMatch {
                    HStack(spacing: 6) {
                        Image(systemName: "text.insert")
                            .foregroundColor(.accentColor)
                        Text("Snippet \(slash.trigger):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(slash.expansion.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                } else if !activeEmojis.isEmpty {
                    HStack(spacing: 6) {
                        Text("Shortcode:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(activeEmojis.prefix(3)) { em in
                            Button(action: { applyEmoji(em) }) {
                                Text("\(em.emoji) \(em.shortcode)")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else if !synonyms.isEmpty {
                    HStack(spacing: 6) {
                        Text("Replace \"\(selectedText)\":")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(synonyms.prefix(4)) { syn in
                            Button(action: { replaceSelectedWithSynonym(syn.text) }) {
                                Text(syn.text)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else if !wordAlternatives.isEmpty && settings.enableWordAlternatives {
                    HStack(spacing: 6) {
                        Text("Alternatives:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        ForEach(wordAlternatives.prefix(2)) { alt in
                            Button(action: { acceptAlternativeString(alt.text) }) {
                                Text(alt.text.trimmingCharacters(in: .whitespaces))
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    Text("Predictions appear inline at your cursor as you type.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: acceptFull) {
                    Text("Accept (Tab)")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasAnyActiveAction)

                Button(action: acceptWord) {
                    Text("Next Word (⌥Tab)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(playgroundSuggestion.isEmpty)

                Button(action: dismissSuggestion) {
                    Text("Dismiss (Esc)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasAnyActiveAction)
            }
            .frame(minHeight: 28)

            // Clean Bottom Settings Strip (Never wraps labels)
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Status:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Text(lastSourceLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize()
                    if lastLatency > 0 {
                        Text("(\(lastLatency) ms)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("Length:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Picker("", selection: $settings.completionLength) {
                        ForEach(CompletionLengthPreset.allCases) { len in
                            Text(len.rawValue).tag(len)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .controlSize(.small)
                    .onChange(of: settings.completionLength) { _, _ in
                        generateSuggestion(for: inputText, force: true)
                    }
                }

                HStack(spacing: 6) {
                    Text("Tone:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Picker("", selection: $settings.selectedTone) {
                        ForEach(TonePreset.allCases) { tone in
                            Text(tone.rawValue).tag(tone)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .controlSize(.small)
                    .onChange(of: settings.selectedTone) { _, _ in
                        generateSuggestion(for: inputText, force: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .padding(14)
        .onAppear {
            generateSuggestion(for: inputText)
        }
    }

    private func generateSuggestion(for text: String, force: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            playgroundSuggestion = ""
            activeTypoFix = nil
            activeEmojis = []
            activeSlashMatch = nil
            wordAlternatives = []
            return
        }

        // 0. Check Slash Commands (/date, /time, /sig, /lgtm...)
        if settings.enableSlashCommands {
            let clips = deepContext.clipboardHistory.map(\.text)
            if let slashMatch = SmartWritingFeatures.matchSlashCommand(
                in: text,
                customCommands: settings.slashCommands,
                recentClips: clips
            ) {
                self.activeSlashMatch = slashMatch
                self.activeTypoFix = nil
                self.activeEmojis = []
                self.playgroundSuggestion = ""
                self.lastLatency = 0
                self.lastSourceLabel = "Slash Snippet"
                return
            } else {
                self.activeSlashMatch = nil
            }
        } else {
            self.activeSlashCommandCleared()
        }

        // 1. Check Inline Autocorrect FIRST (so typos like "focuso" or "expeexperience" are immediately caught)
        if settings.showSuggestedTypoFixes, let typo = SmartWritingFeatures.detectAutocorrect(in: text) {
            self.activeTypoFix = typo
            self.activeEmojis = []
            self.playgroundSuggestion = ""
            self.wordAlternatives = []
            self.lastLatency = 1
            self.lastSourceLabel = "Autocorrect"
            return
        } else {
            self.activeTypoFix = nil
        }

        // 2. Check Emoji Shortcodes (:joy, :crylaugh, :rocket)
        let emojis = SmartWritingFeatures.matchEmoji(
            in: text,
            enableShortcodes: settings.enableEmojiSuggestions,
            enableEmoticons: settings.suggestEmojiFromEmoticons,
            skinTone: settings.preferredEmojiSkinTone,
            includeNeutralSkinTone: settings.includeNeutralEmojiVariant
        )
        self.activeEmojis = emojis
        if let firstEmoji = emojis.first {
            self.playgroundSuggestion = " " + firstEmoji.emoji
            self.wordAlternatives = []
            self.lastLatency = 1
            self.lastSourceLabel = "Shortcode"
            return
        }

        let tone = settings.selectedTone
        let ragSamples = learningEngine.relevantWritingSamples(
            for: text,
            appBundleId: "com.freetypist.playground",
            domain: nil,
            strength: settings.personalizationStrength
        )
        let deepSummary = deepContext.buildSynthesizedContextSummary(
            currentAppName: "FreeTypist Playground",
            currentBundleId: "com.freetypist.playground",
            activeFieldText: text
        )

        let context = PromptContext(
            precedingText: text,
            followingText: "",
            appName: "FreeTypist Playground",
            bundleIdentifier: "com.freetypist.playground",
            clipboardSnippet: deepContext.clipboardHistory.first?.text,
            deepContextSummary: deepSummary,
            personaDescription: settings.personaDescription,
            toneInstruction: tone == .custom ? settings.customToneInstructions : tone.promptInstruction,
            dictionary: settings.personalDictionary,
            learnedSamples: ragSamples,
            maxWords: settings.completionLength.maxWords
        )

        if let learned = learningEngine.predictFromLearnedHistory(precedingText: text, strength: settings.personalizationStrength) {
            self.playgroundSuggestion = PromptBuilder.cleanCompletionText(learned, precedingText: text, maxWords: settings.completionLength.maxWords)
            self.lastLatency = 1
            self.lastSourceLabel = "Learned Style"
            self.wordAlternatives = SmartWritingFeatures.generateWordAlternatives(
                primarySuggestion: self.playgroundSuggestion,
                precedingText: text,
                tone: tone
            )
        } else {
            let instant = OfflinePredictor().complete(context: context, tone: tone)
            self.playgroundSuggestion = PromptBuilder.cleanCompletionText(instant, precedingText: text, maxWords: settings.completionLength.maxWords)
            self.lastLatency = 2
            self.lastSourceLabel = inferenceService.isServerRunning ? "Metal Engine" : "On-Device Predictor"
            self.wordAlternatives = SmartWritingFeatures.generateWordAlternatives(
                primarySuggestion: self.playgroundSuggestion,
                precedingText: text,
                tone: tone
            )
        }

        let provider = ModelProviderFactory.provider(for: settings.activeProvider)
        Task {
            do {
                let (completion, latency) = try await provider.complete(context: context, settings: settings)
                await MainActor.run {
                    guard self.inputText == text else { return }
                    if !completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.playgroundSuggestion = completion
                        self.lastLatency = latency
                        self.lastSourceLabel = self.inferenceService.isServerRunning
                            ? "\(self.modelManager.selectedModel.name)"
                            : "On-Device Predictor"
                        self.wordAlternatives = SmartWritingFeatures.generateWordAlternatives(
                            primarySuggestion: completion,
                            precedingText: text,
                            tone: tone
                        )
                    }
                }
            } catch {}
        }
    }

    private func activeSlashCommandCleared() {
        self.activeSlashMatch = nil
    }

    private func applyEmoji(_ candidate: EmojiCandidate) {
        if inputText.count >= candidate.replacementLength {
            inputText.removeLast(candidate.replacementLength)
        }
        inputText += candidate.emoji + " "
        StatsManager.shared.recordAccepted(text: candidate.emoji, appName: "FreeTypist Playground", source: "Autocorrect & Emoji")
        activeEmojis = []
        playgroundSuggestion = ""
    }

    private func acceptFull() {
        if let slash = activeSlashMatch {
            if inputText.count >= slash.replacementLength {
                inputText.removeLast(slash.replacementLength)
            }
            inputText += slash.expansion
            StatsManager.shared.recordAccepted(text: slash.expansion, appName: "FreeTypist Playground", source: "Slash Snippets")
            activeSlashMatch = nil
            playgroundSuggestion = ""
            return
        }
        if let typo = activeTypoFix {
            if inputText.count >= typo.replacementLength {
                inputText.removeLast(typo.replacementLength)
            }
            inputText += typo.correctedWord
            StatsManager.shared.recordAccepted(text: typo.correctedWord, appName: "FreeTypist Playground", source: "Autocorrect & Emoji")
            activeTypoFix = nil
            playgroundSuggestion = ""
            return
        }
        if let emoji = activeEmojis.first {
            applyEmoji(emoji)
            return
        }
        guard !playgroundSuggestion.isEmpty else { return }
        let accepted = playgroundSuggestion
        let before = inputText
        inputText += accepted
        StatsManager.shared.recordAccepted(text: accepted, appName: "FreeTypist Playground", source: lastSourceLabel)
        learningEngine.recordAcceptedCompletion(
            precedingText: before,
            acceptedText: accepted,
            appName: "FreeTypist Playground",
            bundleId: "com.freetypist.playground"
        )
        if settings.playSoundOnAccept {
            NSSound(named: "Tink")?.play()
        }
        playgroundSuggestion = ""
    }

    private func acceptWord() {
        guard !playgroundSuggestion.isEmpty else { return }
        var item = CompletionItem(fullText: playgroundSuggestion)
        if let word = item.advanceOneWord() {
            let before = inputText
            inputText += word
            StatsManager.shared.recordAccepted(text: word, appName: "FreeTypist Playground", source: lastSourceLabel)
            learningEngine.recordAcceptedCompletion(
                precedingText: before,
                acceptedText: word,
                appName: "FreeTypist Playground",
                bundleId: "com.freetypist.playground"
            )
            playgroundSuggestion = item.remainingText
        }
    }

    private func acceptAlternativeString(_ alt: String) {
        let before = inputText
        inputText += alt
        StatsManager.shared.recordAccepted(text: alt, appName: "FreeTypist Playground", source: lastSourceLabel)
        learningEngine.recordAcceptedCompletion(
            precedingText: before,
            acceptedText: alt,
            appName: "FreeTypist Playground",
            bundleId: "com.freetypist.playground"
        )
        playgroundSuggestion = ""
        wordAlternatives = []
    }

    private func replaceSelectedWithSynonym(_ syn: String) {
        guard !selectedText.isEmpty, let range = inputText.range(of: selectedText, options: .backwards) else { return }
        inputText.replaceSubrange(range, with: syn)
        StatsManager.shared.recordAccepted(text: syn, appName: "FreeTypist Playground", source: "Contextual Synonyms")
        selectedText = ""
        synonyms = []
    }

    private func dismissSuggestion() {
        playgroundSuggestion = ""
        activeTypoFix = nil
        activeEmojis = []
        activeSlashMatch = nil
        wordAlternatives = []
    }
}
