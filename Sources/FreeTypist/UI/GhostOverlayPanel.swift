import Cocoa
import SwiftUI
import Combine
import CoreGraphics

@MainActor
public final class GhostOverlayPanel: NSPanel {
    public static let shared = GhostOverlayPanel()

    private var cancellables = Set<AnyCancellable>()
    private var lastCaretRect: CGRect = .zero
    private var hasValidCaretPosition: Bool = false
    public var detectedFontSize: CGFloat = 13.5

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    private init() {
        super.init(
            contentRect: NSRect(x: -2000, y: -2000, width: 240, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: GhostTextView())
        hostingView.sizingOptions = [.intrinsicContentSize]
        contentView = hostingView

        setupObservers()
    }

    private func setupObservers() {
        CompletionEngine.shared.$currentSuggestion
            .receive(on: RunLoop.main)
            .sink { [weak self] suggestion in
                guard let self = self else { return }
                if let sugg = suggestion, !sugg.remainingText.isEmpty {
                    self.showOverlay()
                } else {
                    self.hideOverlay()
                }
            }
            .store(in: &cancellables)
    }

    public func invalidateCaretPosition() {
        hasValidCaretPosition = false
        lastCaretRect = .zero
        hideOverlay()
    }

    public func updatePosition(caretScreenRect: CGRect, fontSize: CGFloat = 13.5) {
        guard caretScreenRect != .zero,
              !caretScreenRect.origin.x.isNaN,
              !caretScreenRect.origin.y.isNaN,
              caretScreenRect.origin.x > 4,
              caretScreenRect.origin.y > 4 else {
            invalidateCaretPosition()
            return
        }

        lastCaretRect = caretScreenRect
        hasValidCaretPosition = true
        detectedFontSize = fontSize
        fitToContent()

        // Place inline ghost text directly at the cursor edge & baseline (like Cotypist SingleCompletionOverlayWindow)
        let isPureInline = !AppSettings.shared.showShortcutBadges
            && CompletionEngine.shared.activeAutocorrect == nil
            && CompletionEngine.shared.activeEmojiCandidates.isEmpty
        let xNudge: CGFloat = isPureInline ? 0 : 2
        let yNudge: CGFloat = isPureInline ? -1 : -2

        let targetOrigin = NSPoint(
            x: caretScreenRect.origin.x + caretScreenRect.width + xNudge,
            y: caretScreenRect.origin.y + yNudge
        )

        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -40, dy: -40).contains(targetOrigin) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let maxX = screen.visibleFrame.maxX - frame.width - 8
            let minX = screen.visibleFrame.minX + 8
            let maxY = screen.visibleFrame.maxY - frame.height - 8
            let minY = screen.visibleFrame.minY + 8
            setFrameOrigin(NSPoint(
                x: min(max(targetOrigin.x, minX), maxX),
                y: min(max(targetOrigin.y, minY), maxY)
            ))
        } else {
            setFrameOrigin(targetOrigin)
        }
    }

    public func showOverlay() {
        guard AppSettings.shared.isEnabled else {
            hideOverlay()
            return
        }
        // The playground draws ghost text inline inside its own NSTextView.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            hideOverlay()
            return
        }

        // Refresh cursor position from Accessibility
        if let caretInfo = AccessibilityService.shared.getCurrentCaretInfo(), caretInfo.hasValidCaretRect {
            updatePosition(caretScreenRect: caretInfo.screenRect, fontSize: caretInfo.estimatedFontSize)
        } else if hasValidCaretPosition && lastCaretRect.origin.x > 4 && lastCaretRect.origin.y > 4 {
            updatePosition(caretScreenRect: lastCaretRect, fontSize: detectedFontSize)
        } else {
            // Never display a floating modal at (0,0) bottom-left corner when cursor bounds are unavailable!
            hideOverlay()
            return
        }

        guard hasValidCaretPosition, lastCaretRect.origin.x > 4, lastCaretRect.origin.y > 4 else {
            hideOverlay()
            return
        }

        fitToContent()
        orderFrontRegardless()
    }

    public func hideOverlay() {
        if isVisible {
            orderOut(nil)
        }
    }

    private func fitToContent() {
        contentView?.layoutSubtreeIfNeeded()
        guard let size = contentView?.fittingSize, size.width > 1, size.height > 1 else { return }
        setContentSize(NSSize(
            width: min(max(size.width, 16), 680),
            height: min(max(size.height, 18), 80)
        ))
    }
}
