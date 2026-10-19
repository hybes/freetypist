import Cocoa
import ApplicationServices
import Foundation

public struct CaretInfo: Sendable {
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
        return AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
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
        let fullText = (valueObj as? String) ?? (valueObj as? NSAttributedString)?.string ?? ""

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
            screenRect: convertedRect,
            hasValidCaretRect: isValidCaret && convertedRect.origin.x > 4 && convertedRect.origin.y > 4,
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
        // Strategy A: Bounds of the character immediately before the cursor (most accurate for inline placement!)
        if loc > 0 && loc <= nsText.length {
            let prevChar = nsText.substring(with: NSRange(location: loc - 1, length: 1))
            if prevChar != "\n" && prevChar != "\r" {
                if let prevRect = queryBoundsForRange(axElement: axElement, location: loc - 1, length: 1),
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

        if pos.x > 8 && pos.y > 8 && !pos.x.isNaN && !pos.y.isNaN && size.width > 24 && size.height > 12 {
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

    private static func isPlausibleAXRect(_ rect: CGRect) -> Bool {
        guard !rect.origin.x.isNaN, !rect.origin.y.isNaN,
              !rect.width.isNaN, !rect.height.isNaN else {
            return false
        }
        // Reject (0,0) origin or zero-height rects
        guard rect.origin.x > 4 && rect.origin.y > 4 && rect.height >= 8 && rect.height <= 120 else {
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

    public func insertText(_ text: String, deleteBackwardsCount: Int = 0) {
        if deleteBackwardsCount > 0 {
            for _ in 0..<deleteBackwardsCount {
                simulateKeyPress(keyCode: 51, flags: []) // Backspace
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if deleteBackwardsCount == 0, result == .success, let element = focusedElement {
            let axElement = element as! AXUIElement
            let axSetResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if axSetResult == .success {
                return
            }
        }

        insertViaPasteboard(text)
    }

    private func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateKeyPress(keyCode: 9, flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let saved = previousItems, !saved.isEmpty {
                pasteboard.clearContents()
                for (type, data) in saved {
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
