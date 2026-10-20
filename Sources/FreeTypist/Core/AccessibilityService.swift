import Cocoa
import ApplicationServices
import Foundation

public struct CaretInfo: Sendable {
    public let elementHash: UInt
    public let hasReadableText: Bool
    public let screenRect: CGRect
    public let hasValidCaretRect: Bool
    public let estimatedFontSize: CGFloat
    public let precedingText: String
    public let followingText: String
    public let selectedText: String
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String?
    public let domain: String?
}

public final class AccessibilityService: @unchecked Sendable {
    public static let shared = AccessibilityService()

    private let lock = NSLock()
    private var enhancedPIDs = Set<pid_t>()

    private init() {}

    public static func isAccessibilityGranted() -> Bool {
        // A successful query for public AX metadata (such as the frontmost app)
        // does not establish authorisation to read or edit another app's text.
        return AXIsProcessTrustedWithOptions(nil)
    }

    public static func requestAccessibilityPermission() {
        // The SDK exposes this key as a mutable C global, which is unavailable under Swift 6 concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openSystemSettingsAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Enables AXManualAccessibility and AXEnhancedUserInterface on Chromium/Electron/WebKit apps
    /// (Antigravity, Cursor, VS Code, Slack, Discord, Chrome, Notion, Obsidian) so they expose exact inline text metrics.
    private func enableEnhancedAccessibilityIfNeeded(for pid: pid_t) {
        lock.lock()
        let alreadyEnabled = enhancedPIDs.contains(pid)
        if !alreadyEnabled {
            enhancedPIDs.insert(pid)
        }
        lock.unlock()

        let appAX = AXUIElementCreateApplication(pid)
        if !alreadyEnabled {
            _ = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appAX, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    public func getCurrentCaretInfo() -> CaretInfo? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "App"
        let bundleId = frontApp?.bundleIdentifier

        if let pid = frontApp?.processIdentifier {
            enableEnhancedAccessibilityIfNeeded(for: pid)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        var result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        // Fallback: query the frontmost application'sAXFocusedUIElementAttribute directly
        if (result != .success || focusedElement == nil), let pid = frontApp?.processIdentifier {
            let appAX = AXUIElementCreateApplication(pid)
            result = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        }

        guard result == .success, let element = focusedElement else {
            return nil
        }
        let axElement = element as! AXUIElement

        // Skip password / secure text fields automatically
        var roleObj: AnyObject?
        var subroleObj: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleObj)
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleObj)
        if let subrole = subroleObj as? String, subrole == "AXSecureTextField" {
            return nil
        }

        // Read window title if available
        var windowTitle: String?
        if let pid = frontApp?.processIdentifier {
            let appAX = AXUIElementCreateApplication(pid)
            var focusedWin: AnyObject?
            if AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
               let win = focusedWin {
                var titleObj: AnyObject?
                if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleObj) == .success {
                    windowTitle = titleObj as? String
                }
            }
        }

        let domain = Self.inferDomain(fromWindowTitle: windowTitle, bundleId: bundleId)

        // 1. Get entire text value
        var valueObj: AnyObject?
        _ = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueObj)
        let readableText = (valueObj as? String) ?? (valueObj as? NSAttributedString)?.string
        let fullText = readableText ?? ""

        // 2. Get selected text range (or cursor location)
        var rangeObj: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeObj)

        var selectedRange = CFRange(location: 0, length: 0)
        if rangeResult == .success, let rObj = rangeObj, CFGetTypeID(rObj) == AXValueGetTypeID() {
            let rangeVal = rObj as! AXValue
            AXValueGetValue(rangeVal, .cfRange, &selectedRange)
        } else {
            selectedRange = CFRange(location: (fullText as NSString).length, length: 0)
        }

        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(roleObj as? String ?? "") || rangeResult == .success else { return nil }
        let nsText = fullText as NSString
        let loc = max(0, min(selectedRange.location, nsText.length))
        let selLen = max(0, min(selectedRange.length, nsText.length - loc))
        let precedingText = nsText.substring(to: loc)
        let selectedText = selLen > 0 ? nsText.substring(with: NSRange(location: loc, length: selLen)) : ""
        let followingText = nsText.substring(from: loc + selLen)

        // 3. Multi-Strategy Inline Caret Rect Resolution (Cotypist SingleCompletionOverlay + TextMirror)
        let (axCaretRect, isValidCaret) = resolveCaretAXRect(
            axElement: axElement,
            nsText: nsText,
            precedingText: precedingText,
            loc: loc
        )

        var convertedRect: CGRect = .zero
        var estimatedFontSize: CGFloat = 13.5

        if isValidCaret {
            // AX screen coordinates have (0,0) at the top-left of the primary screen.
            // Cocoa NSWindow coordinates have (0,0) at the bottom-left of the primary screen.
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
            let lineHeight = min(max(axCaretRect.height, 14), 32)
            estimatedFontSize = min(max(round(lineHeight * 0.76), 12), 20)
            let cocoaY = primaryScreenHeight - axCaretRect.origin.y - lineHeight
            convertedRect = CGRect(
                x: axCaretRect.origin.x,
                y: cocoaY,
                width: max(axCaretRect.width, 1),
                height: lineHeight
            )
        }

        return CaretInfo(
            elementHash: CFHash(axElement),
            hasReadableText: readableText != nil,
            screenRect: convertedRect,
            hasValidCaretRect: isValidCaret && NSScreen.screens.contains { $0.frame.intersects(convertedRect) },
            estimatedFontSize: estimatedFontSize,
            precedingText: precedingText,
            followingText: followingText,
            selectedText: selectedText,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            domain: domain
        )
    }

    private func resolveCaretAXRect(
        axElement: AXUIElement,
        nsText: NSString,
        precedingText: String,
        loc: Int
    ) -> (rect: CGRect, valid: Bool) {
        if let rect = queryBoundsForRange(axElement: axElement, location: loc, length: 0),
           Self.isPlausibleAXRect(rect) { return (rect, true) }

        // Strategy A: Bounds of the character immediately before the cursor (most accurate for inline placement!)
        if loc > 0 && loc <= nsText.length {
            let previousRange = nsText.rangeOfComposedCharacterSequence(at: loc - 1)
            let prevChar = nsText.substring(with: previousRange)
            if prevChar != "\n" && prevChar != "\r" {
                if let prevRect = queryBoundsForRange(axElement: axElement, location: previousRange.location, length: previousRange.length),
                   Self.isPlausibleAXRect(prevRect) {
                    let caretAtRightEdge = CGRect(
                        x: prevRect.origin.x + prevRect.width,
                        y: prevRect.origin.y,
                        width: 1,
                        height: max(prevRect.height, 16)
                    )
                    return (caretAtRightEdge, true)
                }
            }
        }

        // Strategy B: Zero-length or 1-char range at cursor location
        if let zeroRect = queryBoundsForRange(axElement: axElement, location: loc, length: 0),
           Self.isPlausibleAXRect(zeroRect) {
            return (zeroRect, true)
        }
        if loc < nsText.length,
           let nextRect = queryBoundsForRange(axElement: axElement, location: loc, length: 1),
           Self.isPlausibleAXRect(nextRect) {
            let caretAtLeftEdge = CGRect(
                x: nextRect.origin.x,
                y: nextRect.origin.y,
                width: 1,
                height: max(nextRect.height, 16)
            )
            return (caretAtLeftEdge, true)
        }

        // Strategy C: WebKit / Chromium / Electron AXSelectedTextMarkerRange -> AXBoundsForTextMarkerRange
        var markerRangeObj: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, "AXSelectedTextMarkerRange" as CFString, &markerRangeObj) == .success,
           let markerRange = markerRangeObj {
            var markerBoundsObj: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                axElement,
                "AXBoundsForTextMarkerRange" as CFString,
                markerRange,
                &markerBoundsObj
            ) == .success,
               let bObj = markerBoundsObj,
               CFGetTypeID(bObj) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(bObj as! AXValue, .cgRect, &rect)
                if Self.isPlausibleAXRect(rect) {
                    return (CGRect(x: rect.origin.x + rect.width, y: rect.origin.y, width: 1, height: max(rect.height, 16)), true)
                }
            }
        }

        // Strategy D: Cotypist TextMirror estimation inside the focused element's AXPosition & AXSize frame
        var posObj: AnyObject?
        var sizeObj: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posObj)
        AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeObj)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let pObj = posObj, CFGetTypeID(pObj) == AXValueGetTypeID() {
            AXValueGetValue(pObj as! AXValue, .cgPoint, &pos)
        }
        if let sObj = sizeObj, CFGetTypeID(sObj) == AXValueGetTypeID() {
            AXValueGetValue(sObj as! AXValue, .cgSize, &size)
        }

        if pos.x.isFinite && pos.y.isFinite && size.width > 24 && size.height > 12 {
            // Estimate character column and line inside the input field
            let lines = precedingText.components(separatedBy: .newlines)
            let currentLine = lines.last ?? ""
            let font = NSFont.systemFont(ofSize: 13.5)
            let rawLineWidth = (currentLine as NSString).size(withAttributes: [.font: font]).width
            let usableWidth = max(60, size.width - 20)
            let wrappedLines = max(0, Int(floor(rawLineWidth / usableWidth)))
            let totalLineIndex = max(0, lines.count - 1) + wrappedLines
            let xOffsetInLine = rawLineWidth.truncatingRemainder(dividingBy: usableWidth)

            let estimatedX = min(pos.x + 8 + xOffsetInLine, pos.x + size.width - 16)
            let lineHeight: CGFloat = 18
            let estimatedY = min(pos.y + 6 + (CGFloat(totalLineIndex) * lineHeight), pos.y + size.height - lineHeight)
            let mirrorRect = CGRect(x: estimatedX, y: estimatedY, width: 1, height: lineHeight)
            if Self.isPlausibleAXRect(mirrorRect) {
                return (mirrorRect, true)
            }
        }

        // Never fall back to (0,0) or mouseLocation!
        return (.zero, false)
    }

    private func queryBoundsForRange(axElement: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let axRangeVal = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsObj: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            axElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRangeVal,
            &boundsObj
        )
        guard status == .success, let bObj = boundsObj, CFGetTypeID(bObj) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        AXValueGetValue(bObj as! AXValue, .cgRect, &rect)
        return rect
    }

    static func isPlausibleAXRect(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return false
        }
        // Reject (0,0) origin or zero-height rects
        guard rect.width >= 0 && rect.height >= 8 && rect.height <= 120 else {
            return false
        }
        return true
    }

    private static func inferDomain(fromWindowTitle title: String?, bundleId: String?) -> String? {
        guard let title = title?.lowercased() else { return nil }
        let knownDomains = [
            "github.com", "gmail.com", "mail.google.com", "docs.google.com",
            "slack.com", "notion.so", "linear.app", "discord.com", "linkedin.com", "x.com"
        ]
        for dom in knownDomains where title.contains(dom.replacingOccurrences(of: ".com", with: "")) {
            return dom
        }
        return nil
    }

    public static let syntheticEventMarker: Int64 = 0x46545950
    private var inserting = false
    public private(set) var isPerformingSyntheticInsertion: Bool {
        get { lock.lock(); defer { lock.unlock() }; return inserting }
        set { lock.lock(); inserting = newValue; lock.unlock() }
    }
    private let syntheticQueue = DispatchQueue(label: "com.freetypist.syntheticInput", qos: .userInteractive)

    public func insertText(_ text: String, deleteBackwardsCount: Int = 0) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        var result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if (result != .success || focusedElement == nil),
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let appAX = AXUIElementCreateApplication(pid)
            result = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        }

        // 1. Try atomic Accessibility range replacement first (0 keystrokes when supported by native Cocoa apps)
        var wordAlreadySelectedViaAX = false
        if result == .success, let element = focusedElement {
            let axElement = element as! AXUIElement

            var beforeValObj: AnyObject?
            _ = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &beforeValObj)
            let beforeValue = (beforeValObj as? String) ?? (beforeValObj as? NSAttributedString)?.string

            var rangeObj: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeObj) == .success,
               let rObj = rangeObj,
               CFGetTypeID(rObj) == AXValueGetTypeID() {
                var selectedRange = CFRange(location: 0, length: 0)
                AXValueGetValue(rObj as! AXValue, .cfRange, &selectedRange)

                let deletionUnits = beforeValue.map {
                    TextEditingContext(text: $0, selection: NSRange(location: selectedRange.location, length: selectedRange.length))
                        .precedingText.suffix(max(0, deleteBackwardsCount)).utf16.count
                } ?? deleteBackwardsCount
                if deleteBackwardsCount > 0 && selectedRange.location >= deletionUnits {
                    var replaceRange = CFRange(
                        location: selectedRange.location - deletionUnits,
                        length: deletionUnits + selectedRange.length
                    )
                    if let axRange = AXValueCreate(.cfRange, &replaceRange) {
                        if AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                            // Verify whether the app actually selected the range
                            var verifyRangeObj: AnyObject?
                            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &verifyRangeObj) == .success,
                               let vObj = verifyRangeObj,
                               CFGetTypeID(vObj) == AXValueGetTypeID() {
                                var verifiedRange = CFRange(location: 0, length: 0)
                                AXValueGetValue(vObj as! AXValue, .cfRange, &verifiedRange)
                                if verifiedRange.location == replaceRange.location && verifiedRange.length == replaceRange.length {
                                    wordAlreadySelectedViaAX = true
                                }
                            }
                        }
                    }
                }

                if deleteBackwardsCount == 0 || wordAlreadySelectedViaAX {
                    if AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                        var afterValObj: AnyObject?
                        _ = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &afterValObj)
                        let afterValue = (afterValObj as? String) ?? (afterValObj as? NSAttributedString)?.string
                        // Confirm the underlying text value actually changed
                        if beforeValue == nil || afterValue == nil || afterValue != beforeValue {
                            return
                        }
                    }
                }
            }
        }

        // 2. Reliable Paced Keyboard Replacement (never mixes unmodified Backspaces with Cmd+V modifier flags)
        let backspacesToSend = wordAlreadySelectedViaAX ? 1 : deleteBackwardsCount
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        syntheticQueue.async { [weak self] in
            guard let self = self, let targetPID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
            self.isPerformingSyntheticInsertion = true
            defer {
                usleep(18_000)
                self.isPerformingSyntheticInsertion = false
            }

            let source = CGEventSource(stateID: .privateState)

            if backspacesToSend > 0 {
                for _ in 0..<backspacesToSend {
                    self.postKey(keyCode: 51, flags: [], source: source)
                    usleep(4_500) // 4.5ms spacing guarantees Chromium/Electron/Cocoa processes every single Backspace
                }
                // Wait 20ms for all Backspaces to commit in the target app before typing the replacement
                usleep(20_000)
            }

            self.postUnicodeString(text, source: source, targetPID: targetPID)
        }
    }

    private func postUnicodeString(_ text: String, source: CGEventSource?, targetPID: pid_t) {
        for char in text {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
            var utf16Units = Array(String(char).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(2_000)
        }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        keyUp?.post(tap: .cghidEventTap)
    }
}
