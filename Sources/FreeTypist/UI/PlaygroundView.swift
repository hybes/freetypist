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
    public var paragraphSpellingShortcutEnabled = true
    public var spellingSettings: AppSettings = .shared
    public var onSentenceCorrected: ((Int) -> Void)?

    public override func keyDown(with event: NSEvent) {
        ReplacementFeedback.shared.clear()
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let active = !ghostSuggestion.isEmpty || hasInterceptableAction
        if WritingShortcut.checksParagraph(keyCode: keyCode, modifiers: flags),
           !event.isARepeat, paragraphSpellingShortcutEnabled, !hasMarkedText(),
           performSentenceSpellingCheck() {
            return
        }

        // Tab (keyCode 48)
        if keyCode == 48 && active && !flags.contains(.command) && !flags.contains(.control) {
            if flags.contains(.option) || flags.contains(.shift) {
                if onAcceptNextWord?() == true { return }
            } else {
                if onTabAcceptFull?() == true { return }
            }
        }

        // Backtick ` (keyCode 50) - word/full shortcut when suggestion is active
        if keyCode == 50 && active && flags.isEmpty {
            if onAcceptNextWord?() == true { return }
        }

        // Escape (keyCode 53)
        if keyCode == 53 && active && flags.intersection([.command, .control, .option, .shift]).isEmpty {
            if onEscapeDismiss?() == true { return }
        }

        super.keyDown(with: event)
    }

    @discardableResult
    func performSentenceSpellingCheck() -> Bool {
        guard paragraphSpellingShortcutEnabled, !hasMarkedText() else { return false }
        let snapshot = TextInputSnapshot(identity: UInt(bitPattern: ObjectIdentifier(self)),
                                         text: string, selection: selectedRange())
        guard let correction = SentenceSpellingCorrector.correction(in: snapshot,
            ignoredWords: spellingSettings.rememberedSpellings,
            feedback: spellingSettings.activeSpellingFeedback) else { return false }
        insertText(correction.edit.insertion, replacementRange: correction.edit.range)
        guard string == correction.edit.result.text else { return false }
        setSelectedRange(correction.edit.result.selection)
        spellingSettings.recordSpellingFeedback(correction.spellingPairs, accepted: true)
        onSentenceCorrected?(correction.count)
        ReplacementFeedback.shared.show("Fixed \(correction.count) spelling \(correction.count == 1 ? "mistake" : "mistakes").")
        return true
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
    @Binding public var selection: NSRange
    public var ghostSuggestion: String
    public var hasInterceptableAction: Bool
    public var ghostOpacity: Double
    public var onTabAcceptFull: () -> Bool
    public var onAcceptNextWord: () -> Bool
    public var onEscapeDismiss: () -> Bool
    public var paragraphSpellingShortcutEnabled: Bool = true
    public var spellingSettings: AppSettings = .shared
    public var onSentenceCorrected: ((Int) -> Void)?

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
        textView.setSelectedRange(selection)
        if textView.selectedRange() != selection { textView.setSelectedRange(selection) }
        textView.ghostSuggestion = ghostSuggestion
        textView.hasInterceptableAction = hasInterceptableAction
        textView.ghostOpacity = ghostOpacity
        textView.onTabAcceptFull = onTabAcceptFull
        textView.onAcceptNextWord = onAcceptNextWord
        textView.onEscapeDismiss = onEscapeDismiss
        textView.paragraphSpellingShortcutEnabled = paragraphSpellingShortcutEnabled
        textView.spellingSettings = spellingSettings
        textView.onSentenceCorrected = onSentenceCorrected

        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? GhostAwareNSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        if textView.string != text {
            textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }
        if textView.selectedRange() != selection { textView.setSelectedRange(selection) }
        textView.ghostSuggestion = ghostSuggestion
        textView.hasInterceptableAction = hasInterceptableAction
        textView.ghostOpacity = ghostOpacity
        textView.onTabAcceptFull = onTabAcceptFull
        textView.onAcceptNextWord = onAcceptNextWord
        textView.onEscapeDismiss = onEscapeDismiss
        textView.paragraphSpellingShortcutEnabled = paragraphSpellingShortcutEnabled
        textView.spellingSettings = spellingSettings
        textView.onSentenceCorrected = onSentenceCorrected
        textView.needsDisplay = true
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaygroundEditorRepresentable
        var isUpdating = false

        init(_ parent: PlaygroundEditorRepresentable) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            parent.selection = tv.selectedRange()
            let newStr = tv.string
            if parent.text != newStr {
                parent.text = newStr
            }
            tv.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            if parent.selection != tv.selectedRange() { parent.selection = tv.selectedRange() }
            tv.needsDisplay = true
        }
    }
}

public struct PlaygroundView: View {
    @ObservedObject private var replacementFeedback = ReplacementFeedback.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modelManager = LocalModelManager.shared
    @ObservedObject var inferenceService = LocalInferenceService.shared
    @ObservedObject var learningEngine = LearningEngine.shared
    @ObservedObject var resourceMonitor = SystemResourceMonitor.shared
    @ObservedObject var deepContext = DeepContextCollector.shared

    @State private var inputText: String = "Thank you for "
    @State private var selection = NSRange(location: 14, length: 0)
    @StateObject private var engine = CompletionEngine()
    private let isSetup: Bool
    private let onAccepted: (() -> Void)?

    private var editorContext: TextEditingContext { TextEditingContext(text: inputText, selection: selection) }
    private var selectedText: String { editorContext.selectedText }
    private var playgroundSuggestion: String {
        guard engine.currentSuggestion?.replacementLength == 0 else { return "" }
        return engine.currentSuggestion?.remainingText ?? ""
    }
    private var activeTypoFix: AutocorrectSuggestion? { engine.activeAutocorrect }
    private var activeEmojis: [EmojiCandidate] { engine.activeEmojiCandidates }
    private var activeSlashMatch: (trigger: String, expansion: String, replacementLength: Int)? { engine.activeSlashCommand }
    private var wordAlternatives: [WordAlternativeItem] { engine.activeWordAlternatives }
    private var synonyms: [WordAlternativeItem] { engine.activeSynonyms }
    private var lastLatency: Int { engine.lastLatencyMs }
    private var lastSourceLabel: String {
        if let error = engine.lastError { return error }
        if engine.isGenerating { return "Generating…" }
        return engine.currentSuggestion?.providerName ?? "Ready"
    }

    private let samplePrompts: [(label: String, text: String)] = [
        ("Email Reply", "Thank you for "),
        ("Spelling & Typo Fix", "I definately want to focuso on a better expeexperience "),
        ("Project Update", "I think we should "),
        ("Quick Follow-up", "Just wanted to follow "),
        ("Learned Phrase", "In order to keep CPU and memory usage minimal, ")
    ]

    public init(isSetup: Bool = false, onAccepted: (() -> Void)? = nil) {
        self.isSetup = isSetup
        self.onAccepted = onAccepted
    }

    private var hasAnyActiveAction: Bool {
        engine.currentSuggestion != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clean Header
            if !isSetup { HStack(spacing: 12) {
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
                    Text("Tab accepts a suggestion. Option+Tab accepts the next word. Control–Option–S checks the whole paragraph.")
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
                        selection = NSRange(location: (item.text as NSString).length, length: 0)
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
                    selection = NSRange(location: 0, length: 0)
                    dismissSuggestion()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Main Ghost-Aware Text Editor
            PlaygroundEditorRepresentable(
                text: $inputText,
                selection: $selection,
                ghostSuggestion: playgroundSuggestion,
                hasInterceptableAction: hasAnyActiveAction,
                ghostOpacity: settings.ghostTextOpacity,
                onTabAcceptFull: {
                    acceptFull()
                },
                onAcceptNextWord: {
                    acceptWord()
                },
                onEscapeDismiss: {
                    rejectSuggestion(honourEscapeBehaviour: true)
                },
                paragraphSpellingShortcutEnabled: settings.isEnabled && settings.paragraphSpellingShortcutEnabled,
                spellingSettings: settings,
                onSentenceCorrected: { _ in
                    engine.dismiss()
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
            .onChange(of: selection) { _, _ in
                generateSuggestion(for: inputText)
            }

            if let message = replacementFeedback.message {
                Text(message).font(.caption).foregroundColor(.secondary)
            }

            // Clean Action & Correction Bar
            HStack(spacing: 10) {
                if let paragraph = engine.paragraphSpellingSuggestion {
                    Text("Fix \(paragraph.count) spelling \(paragraph.count == 1 ? "mistake" : "mistakes") · Tab")
                        .font(.caption)
                } else if let typo = activeTypoFix {
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
                } else if let suggestion = engine.currentSuggestion, suggestion.replacementLength > 0 {
                    Text("Expand to: " + suggestion.remainingText)
                        .font(.caption)
                        .lineLimit(1)
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

                Button(action: { acceptFull() }) {
                    Text("Accept (Tab)")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasAnyActiveAction)

                Button(action: { acceptWord() }) {
                    Text("Next Word (⌥Tab)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasAnyActiveAction)

                Button(action: { rejectSuggestion() }) {
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
        .onDisappear { engine.dismiss() }
    }

    private func generateSuggestion(for text: String, force: Bool = false) {
        let context = TextEditingContext(text: text, selection: selection)
        engine.onTextContextChanged(
            precedingText: context.precedingText,
            followingText: context.followingText,
            selectedText: context.selectedText,
            appName: "FreeTypist Playground",
            bundleId: "com.freetypist.playground",
            force: force
        )
    }

    private func applyInsertion(_ insertion: String, deleteBackwardsCount: Int = 0) {
        let result = editorContext.replacingSelection(with: insertion, deleteBackwardsCount: deleteBackwardsCount)
        inputText = result.text
        selection = result.selection
        onAccepted?()
    }

    private func applyEmoji(_ candidate: EmojiCandidate) {
        applyInsertion(candidate.emoji, deleteBackwardsCount: candidate.replacementLength)
        StatsManager.shared.recordAccepted(text: candidate.emoji, appName: "FreeTypist Playground", source: "Autocorrect & Emoji")
        engine.dismiss()
    }

    @discardableResult
    private func acceptFull() -> Bool {
        guard engine.matchesContext(editorContext, bundleId: "com.freetypist.playground") else {
            engine.dismiss()
            return false
        }
        let snapshot = TextInputSnapshot(identity: 0, text: inputText, selection: selection)
        guard let accepted = engine.prepareAcceptance(nextWord: false),
              let edit = accepted.replacement(in: snapshot) else { return false }
        inputText = edit.result.text
        selection = edit.result.selection
        engine.commitAcceptance(accepted)
        onAccepted?()
        return true
    }

    @discardableResult
    private func acceptWord() -> Bool {
        guard engine.matchesContext(editorContext, bundleId: "com.freetypist.playground") else {
            engine.dismiss()
            return false
        }
        if (engine.currentSuggestion?.replacementLength ?? 0) > 0 {
            return acceptFull()
        } else if let word = engine.acceptNextWord() {
            applyInsertion(word)
            return true
        }
        return false
    }

    private func acceptAlternativeString(_ alternative: String) {
        guard let item = engine.activeWordAlternatives.first(where: { $0.text == alternative }),
              let accepted = engine.acceptAlternative(at: item.index) else { return }
        applyInsertion(accepted)
    }

    private func replaceSelectedWithSynonym(_ synonym: String) {
        guard !editorContext.selectedText.isEmpty else { return }
        applyInsertion(synonym)
        StatsManager.shared.recordAccepted(text: synonym, appName: "FreeTypist Playground", source: "Contextual Synonyms")
        engine.dismiss()
    }

    private func dismissSuggestion() {
        engine.dismiss()
    }

    @discardableResult
    private func rejectSuggestion(honourEscapeBehaviour: Bool = false) -> Bool {
        guard engine.matchesContext(editorContext, bundleId: "com.freetypist.playground") else {
            engine.dismiss()
            return false
        }
        return honourEscapeBehaviour ? engine.handleEscape() : engine.rejectCurrentSuggestion()
    }
}
