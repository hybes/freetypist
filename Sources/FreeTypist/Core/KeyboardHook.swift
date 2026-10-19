import Cocoa
import CoreGraphics
import Foundation

public final class KeyboardHook: @unchecked Sendable {
    public static let shared = KeyboardHook()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalKeyMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var reconnectTimer: Timer?
    public private(set) var isRunning: Bool = false
    private let typingBuffer = TypingBuffer()

    private init() {}

    public func start() {
        setupWorkspaceObserver()
        setupGlobalFallbackMonitor()
        tryStartEventTap()

        // If Accessibility permission isn't granted yet, poll lightly until granted
        if !isRunning {
            reconnectTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] t in
                guard let self = self else {
                    t.invalidate()
                    return
                }
                if AccessibilityService.isAccessibilityGranted() {
                    self.tryStartEventTap()
                    if self.isRunning {
                        t.invalidate()
                    }
                }
            }
            timer.tolerance = 0.5
            self.reconnectTimer = timer
        }
    }

    private func tryStartEventTap() {
        guard !isRunning else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let observer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
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
        self.isRunning = true
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
            AppSettings.shared.pausedAppBundleId = nil
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
            guard !self.isRunning else { return }
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
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        if let mon = globalKeyMonitor {
            NSEvent.removeMonitor(mon)
            globalKeyMonitor = nil
        }
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        // Ignore synthetic keystrokes posted by AccessibilityService during replacements
        if event.getIntegerValueField(.eventSourceUserData) == AccessibilityService.syntheticEventMarker ||
           AccessibilityService.shared.isPerformingSyntheticInsertion {
            return Unmanaged.passRetained(event)
        }

        if isTypingInFreeTypist() {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasActiveSuggestion = hasSuggestion()
        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let tabDisabledInApp = AppSettings.shared.rule(for: frontBundleId)?.disableTabKey ?? false

        // Keycode 48 = Tab
        if keyCode == 48 && hasActiveSuggestion && !tabDisabledInApp {
            let isOptionPressed = flags.contains(.maskAlternate)
            let isShiftPressed = flags.contains(.maskShift)

            Task { @MainActor in
                // If there is an active typo fix or slash command, always apply the full replacement
                let isReplacement = CompletionEngine.shared.activeAutocorrect != nil
                    || CompletionEngine.shared.activeSlashCommand != nil
                    || !CompletionEngine.shared.activeEmojiCandidates.isEmpty
                    || (CompletionEngine.shared.currentSuggestion?.replacementLength ?? 0) > 0

                if (isOptionPressed || isShiftPressed) && !isReplacement {
                    if let word = CompletionEngine.shared.acceptNextWord() {
                        self.typingBuffer.append(word)
                        AccessibilityService.shared.insertText(word)
                        MenuBarController.shared.rebuildMenu()
                    }
                } else {
                    if let accepted = CompletionEngine.shared.acceptFull() {
                        self.typingBuffer.replaceTrailing(
                            count: accepted.deleteBackwardsCount,
                            with: accepted.textToInsert
                        )
                        AccessibilityService.shared.insertText(
                            accepted.textToInsert,
                            deleteBackwardsCount: accepted.deleteBackwardsCount
                        )
                        MenuBarController.shared.rebuildMenu()
                    }
                }
            }
            return nil
        }

        // Keycode 53 = Escape
        if keyCode == 53 && hasActiveSuggestion {
            let escBehavior = AppSettings.shared.escapeBehavior
            if escBehavior == .passToApp {
                return Unmanaged.passRetained(event)
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
            return Unmanaged.passRetained(event)
        }

        typingBuffer.handle(event: event)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !AccessibilityService.shared.isPerformingSyntheticInsertion else { return }
            self?.requestCompletionFromContext()
        }

        return Unmanaged.passRetained(event)
    }

    @MainActor
    private func requestCompletionFromContext() {
        guard !AccessibilityService.shared.isPerformingSyntheticInsertion else { return }
        let bufferSnapshot = typingBuffer.snapshot()
        let caretInfo = AccessibilityService.shared.getCurrentCaretInfo()

        // Require a valid inline cursor rect on screen so we never show an unanchored floating modal at (0,0)
        guard let caretInfo, caretInfo.hasValidCaretRect else {
            GhostOverlayPanel.shared.invalidateCaretPosition()
            CompletionEngine.shared.dismiss()
            return
        }

        let axText = caretInfo.precedingText
        let axTrimmed = axText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preceding: String
        if axTrimmed.count >= AppSettings.shared.minTriggerCharacters {
            preceding = axText
            typingBuffer.replace(with: axText)
        } else if bufferSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).count >= AppSettings.shared.minTriggerCharacters {
            preceding = bufferSnapshot
        } else {
            CompletionEngine.shared.dismiss()
            return
        }

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

        if (123...126).contains(keyCode) { return }

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
