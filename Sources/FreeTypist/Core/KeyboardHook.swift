import Cocoa
import CoreGraphics
import Foundation

public final class KeyboardHook: @unchecked Sendable {
    public static let shared = KeyboardHook()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalKeyMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    public var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }
    private let typingBuffer = TypingBuffer()
    private var lastFieldHash: UInt?
    private var sentenceCorrectionInProgress = false
    private var suppressReturnRepeats = false
    private var correctedSentence: TextInputSnapshot?

    private init() {}

    private func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["FREETYPIST_DEBUG_KEYBOARD"] == "1" else { return }
        FileHandle.standardError.write(Data(("FreeTypist keyboard: " + message + "\n").utf8))
    }

    public func start() {
        setupWorkspaceObserver()
        setupGlobalFallbackMonitor()
        if AccessibilityService.isAccessibilityGranted() { tryStartEventTap() }

        // PermissionManager owns authorisation monitoring and reconnects.
    }

    private func tryStartEventTap() {
        guard !isRunning else { return }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let observer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let hook = Unmanaged<KeyboardHook>.fromOpaque(refcon).takeUnretainedValue()
                return hook.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observer
        ) else {
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("FreeTypist: KeyboardHook event tap active.")
    }

    private func setupWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.typingBuffer.reset()
            self?.correctedSentence = nil
            MainActor.assumeIsolated {
                AccessibilityService.shared.cancelPendingInsertion()
                ReplacementFeedback.shared.clear()
            }
            if AppSettings.shared.pausedAppBundleId != nil {
                AppSettings.shared.pausedAppBundleId = nil
            }
            Task { @MainActor in
                CompletionEngine.shared.dismiss()
            }
        }
    }

    private func setupGlobalFallbackMonitor() {
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return }
            // Only use fallback monitor when CGEventTap isn't active
            guard !self.isRunning, AccessibilityService.isAccessibilityGranted(), AppSettings.shared.isEnabled else { return }
            if AccessibilityService.shared.isPerformingSyntheticInsertion { return }
            if self.isTypingInFreeTypist() { return }
            if let cgEvent = event.cgEvent {
                if cgEvent.getIntegerValueField(.eventSourceUserData) == AccessibilityService.syntheticEventMarker {
                    return
                }
                self.typingBuffer.handle(event: cgEvent)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000)
                self?.requestCompletionFromContext()
            }
        }
    }

    public func stop() {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        if let mon = globalKeyMonitor {
            NSEvent.removeMonitor(mon)
            globalKeyMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            if [36, 76].contains(event.getIntegerValueField(.keyboardEventKeycode)) { suppressReturnRepeats = false }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            MainActor.assumeIsolated {
                AccessibilityService.shared.cancelPendingInsertion()
                ReplacementFeedback.shared.clear()
            }
            correctedSentence = nil
            typingBuffer.reset()
            lastFieldHash = nil
            Task { @MainActor in
                CompletionEngine.shared.dismiss()
                GhostOverlayPanel.shared.invalidateCaretPosition()
            }
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        trace("Key event received")

        // Ignore synthetic keystrokes posted by AccessibilityService during replacements
        if event.getIntegerValueField(.eventSourceUserData) == AccessibilityService.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if isTypingInFreeTypist() {
            trace("Own application; using Playground controls")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let plainReturn = [36, 76].contains(keyCode)
            && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if plainReturn && (sentenceCorrectionInProgress ||
            (suppressReturnRepeats && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)) { return nil }
        MainActor.assumeIsolated {
            AccessibilityService.shared.cancelPendingInsertion()
            ReplacementFeedback.shared.clear()
        }
        if plainReturn && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let handled = MainActor.assumeIsolated { handleSentenceReturn() }
            if handled { suppressReturnRepeats = true; return nil }
        } else { correctedSentence = nil }
        let hasActiveSuggestion = hasSuggestion() && AppSettings.shared.isEnabled
        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let tabDisabledInApp = AppSettings.shared.rule(for: frontBundleId)?.disableTabKey ?? false

        // Tab accepts a suggestion; an unmodified backtick accepts its next word.
        let plainBacktick = keyCode == 50 && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if ((keyCode == 48 && !tabDisabledInApp) || plainBacktick) && hasActiveSuggestion
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) {
            let handled = MainActor.assumeIsolated {
                handleSuggestionAcceptance(nextWord: flags.contains(.maskAlternate) || flags.contains(.maskShift) || plainBacktick)
            }
            return handled ? nil : Unmanaged.passUnretained(event)
        }

        // Keycode 53 = Escape
        if keyCode == 53 && hasActiveSuggestion {
            let escBehavior = AppSettings.shared.escapeBehavior
            if escBehavior == .passToApp {
                return Unmanaged.passUnretained(event)
            }
            Task { @MainActor in
                switch escBehavior {
                case .dismissThenPassToApp:
                    CompletionEngine.shared.dismiss()
                case .pauseBriefly:
                    AppSettings.shared.pausedUntilDate = Date().addingTimeInterval(15)
                    CompletionEngine.shared.dismiss()
                case .offUntilAppSwitch:
                    AppSettings.shared.pausedAppBundleId = frontBundleId
                    CompletionEngine.shared.dismiss()
                case .passToApp:
                    break
                }
            }
            return nil
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            typingBuffer.handleCommandKey(keyCode: keyCode)
            Task { @MainActor [weak self] in
                CompletionEngine.shared.dismiss()
                if [0, 6, 7, 9, 51, 123, 124, 125, 126].contains(keyCode) {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    self?.requestCompletionFromContext()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        typingBuffer.handle(event: event)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !AccessibilityService.shared.isPerformingSyntheticInsertion else { return }
            self?.requestCompletionFromContext()
        }

        return Unmanaged.passUnretained(event)
    }

    @MainActor
    private func handleSuggestionAcceptance(nextWord: Bool) -> Bool {
        let service = AccessibilityService.shared
        let engine = CompletionEngine.shared
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !service.isPerformingSyntheticInsertion,
              let target = service.captureTextTarget(), let snapshot = target.snapshot(),
              snapshot.identity == lastFieldHash, engine.matchesContext(snapshot.context, bundleId: bundle),
              let acceptance = engine.prepareAcceptance(nextWord: nextWord),
              let edit = TextReplacement.trailing(acceptance.text, count: acceptance.deleteCount, in: snapshot) else {
            engine.dismiss()
            return false
        }
        Task { @MainActor in
            let result = await service.apply(edit, to: target)
            if result == .applied {
                self.typingBuffer.replace(with: edit.result.context.precedingText)
                engine.commitAcceptance(acceptance)
                MenuBarController.shared.rebuildMenu()
            } else {
                engine.dismiss()
                if result == .unsupported {
                    ReplacementFeedback.shared.show("This field could not confirm the replacement. Check the text before continuing.")
                }
            }
        }
        return true
    }

    @MainActor
    private func handleSentenceReturn() -> Bool {
        let settings = AppSettings.shared
        let service = AccessibilityService.shared
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard settings.correctSentenceOnEnter, settings.isEnabled,
              !settings.isAppExcluded(bundleIdentifier: bundle),
              settings.rule(for: bundle)?.disableAutocorrect != true,
              !service.isPerformingSyntheticInsertion,
              let target = service.captureTextTarget(), let snapshot = target.snapshot(),
              snapshot != correctedSentence,
              let correction = SentenceSpellingCorrector.correction(in: snapshot) else { return false }
        CompletionEngine.shared.dismiss()
        if let caret = service.getCurrentCaretInfo(), caret.hasValidCaretRect {
            GhostOverlayPanel.shared.updatePosition(caretScreenRect: caret.screenRect, fontSize: caret.estimatedFontSize)
        }
        sentenceCorrectionInProgress = true
        Task { @MainActor in
            defer { self.sentenceCorrectionInProgress = false }
            let result = await service.apply(correction.edit, to: target)
            if result == .applied {
                self.correctedSentence = correction.edit.result
                self.typingBuffer.replace(with: correction.edit.result.context.precedingText)
                ReplacementFeedback.shared.show("Fixed \(correction.count) spelling \(correction.count == 1 ? "mistake" : "mistakes"). Press Enter again to continue.")
            } else if result == .unsupported {
                // Allow the next Enter to behave normally even in an unsupported field.
                self.correctedSentence = target.snapshot()
                ReplacementFeedback.shared.show("This field could not confirm the spelling changes. Check the text; Enter again continues.")
            }
        }
        return true
    }

    @MainActor
    private func requestCompletionFromContext() {
        guard !AccessibilityService.shared.isPerformingSyntheticInsertion else { return }
        let settings = AppSettings.shared
        guard settings.isEnabled,
              !settings.isAppExcluded(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else {
            typingBuffer.reset()
            CompletionEngine.shared.dismiss()
            return
        }
        let bufferSnapshot = typingBuffer.snapshot()
        let caretInfo = AccessibilityService.shared.getCurrentCaretInfo()

        // Require a valid inline cursor rect on screen so we never show an unanchored floating modal at (0,0)
        guard let caretInfo, caretInfo.hasValidCaretRect else {
            trace(caretInfo == nil ? "No accessible text field" : "Text field has no valid caret bounds")
            GhostOverlayPanel.shared.invalidateCaretPosition()
            CompletionEngine.shared.dismiss()
            return
        }

        let preceding: String
        if caretInfo.hasReadableText {
            preceding = caretInfo.precedingText
            typingBuffer.replace(with: preceding)
        } else if lastFieldHash == caretInfo.elementHash {
            preceding = bufferSnapshot
        } else {
            typingBuffer.reset()
            preceding = ""
        }
        lastFieldHash = caretInfo.elementHash
        trace("Accessible context: \(preceding.count) characters")

        GhostOverlayPanel.shared.updatePosition(
            caretScreenRect: caretInfo.screenRect,
            fontSize: caretInfo.estimatedFontSize
        )

        CompletionEngine.shared.onTextContextChanged(
            precedingText: preceding,
            followingText: caretInfo.followingText,
            selectedText: caretInfo.selectedText,
            appName: caretInfo.appName,
            bundleId: caretInfo.bundleId,
            domain: caretInfo.domain,
            windowTitle: caretInfo.windowTitle
        )
    }

    private func isTypingInFreeTypist() -> Bool {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            return bid == Bundle.main.bundleIdentifier || bid == "com.freetypist.app"
        }
        return false
    }

    private func hasSuggestion() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                let eng = CompletionEngine.shared
                return eng.currentSuggestion != nil || eng.activeAutocorrect != nil || eng.activeSlashCommand != nil || !eng.activeEmojiCandidates.isEmpty
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let eng = CompletionEngine.shared
                return eng.currentSuggestion != nil || eng.activeAutocorrect != nil || eng.activeSlashCommand != nil || !eng.activeEmojiCandidates.isEmpty
            }
        }
    }
}

/// Reconstructs recently typed text when Accessibility does not expose the field value.
final class TypingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String = ""
    private let maxLength = 800

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func replace(with value: String) {
        lock.lock()
        text = String(value.suffix(maxLength))
        lock.unlock()
    }

    func append(_ value: String) {
        lock.lock()
        text.append(value)
        trimLocked()
        lock.unlock()
    }

    func replaceTrailing(count: Int, with replacement: String) {
        lock.lock()
        if count > 0 {
            let dropCount = min(count, text.count)
            text.removeLast(dropCount)
        }
        text.append(replacement)
        trimLocked()
        lock.unlock()
    }

    func handleCommandKey(keyCode: Int64) {
        if keyCode == 0 || keyCode == 9 || keyCode == 7 || keyCode == 6 {
            reset()
        }
    }

    func handle(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == 51 { // delete
            lock.lock()
            if !text.isEmpty { text.removeLast() }
            lock.unlock()
            return
        }

        if keyCode == 36 || keyCode == 76 { // return / keypad enter
            lock.lock()
            text.append("\n")
            trimLocked()
            lock.unlock()
            return
        }

        if (123...126).contains(keyCode) { reset(); return }

        guard let nsEvent = NSEvent(cgEvent: event),
              let chars = nsEvent.characters else { return }

        let filtered = chars.filter { ch in
            ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isWhitespace || ch.isSymbol
        }
        guard !filtered.isEmpty else { return }

        lock.lock()
        text.append(contentsOf: filtered)
        trimLocked()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        text = ""
        lock.unlock()
    }

    private func trimLocked() {
        if text.count > maxLength {
            text = String(text.suffix(maxLength))
        }
    }
}
