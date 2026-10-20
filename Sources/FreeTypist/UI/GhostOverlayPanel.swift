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
    private var caretApplicationPID: pid_t?
    public private(set) var detectedFontSize: CGFloat = 13.5

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
            .combineLatest(ReplacementFeedback.shared.$message)
            .receive(on: RunLoop.main)
            .sink { [weak self] suggestion, message in
                guard let self = self else { return }
                if message != nil || suggestion?.remainingText.isEmpty == false {
                    self.showOverlay()
                } else {
                    self.hideOverlay()
                }
            }
            .store(in: &cancellables)
    }

    public func invalidateCaretPosition() {
        hasValidCaretPosition = false
        caretApplicationPID = nil
        lastCaretRect = .zero
        hideOverlay()
    }

    public func updatePosition(caretScreenRect: CGRect, fontSize: CGFloat = 13.5) {
        guard caretScreenRect != .zero,
              caretScreenRect.origin.x.isFinite,
              caretScreenRect.origin.y.isFinite,
              caretScreenRect.width.isFinite, caretScreenRect.width >= 0,
              caretScreenRect.height.isFinite, caretScreenRect.height > 0 else {
            invalidateCaretPosition()
            return
        }

        lastCaretRect = caretScreenRect
        hasValidCaretPosition = true
        caretApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if fontSize.isFinite, detectedFontSize != fontSize {
            detectedFontSize = fontSize
            (contentView as? NSHostingView<GhostTextView>)?.rootView = GhostTextView(fontSize: fontSize)
        }
        if !layoutAtCaret() { hideOverlay() }
    }

    private func layoutAtCaret() -> Bool {
        guard hasValidCaretPosition else { return false }
        contentView?.layoutSubtreeIfNeeded()
        guard let size = contentView?.fittingSize, size.width > 1, size.height > 1 else { return false }

        let engine = CompletionEngine.shared
        let belowCaret = ReplacementFeedback.shared.message != nil
            || engine.activeAutocorrect?.replacementRange != nil
            || engine.paragraphSpellingSuggestion != nil
        let pureInline = !AppSettings.shared.showShortcutBadges && !belowCaret
            && engine.activeAutocorrect == nil && engine.activeEmojiCandidates.isEmpty

        let screen = NSScreen.screens.first { $0.frame.intersects(lastCaretRect) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let frame = Self.placement(caret: lastCaretRect, contentSize: size,
                                      visibleFrame: screen?.visibleFrame, pureInline: pureInline,
                                      belowCaret: belowCaret) {
            // Size and origin move together. A later content resize must not
            // preserve an old top edge and shift streamed text off its baseline.
            setFrame(frame, display: false)
            return true
        }
        return false
    }

    static func placement(caret: CGRect, contentSize: CGSize, visibleFrame: CGRect?,
                          pureInline: Bool, belowCaret: Bool) -> CGRect? {
        var size = CGSize(width: min(max(contentSize.width, 16), 680),
                          height: min(max(contentSize.height, 18), 80))
        var origin = CGPoint(x: caret.maxX + (pureInline ? 0 : 2),
                             y: belowCaret ? caret.minY - size.height - 6 : caret.midY - size.height / 2)
        if let visibleFrame {
            let usable = visibleFrame.insetBy(dx: 8, dy: 8)
            if pureInline {
                // Clip long suggestions at the display edge, rather than
                // shifting them backwards over the text already written.
                guard origin.x >= usable.minX, usable.maxX - origin.x >= 16 else { return nil }
                size.width = min(size.width, usable.maxX - origin.x)
            } else {
                size.width = min(size.width, usable.width)
                origin.x = min(max(origin.x, usable.minX), usable.maxX - size.width)
            }
            origin.y = min(max(origin.y, usable.minY), usable.maxY - size.height)
        }
        return CGRect(origin: origin, size: size)
    }

    public func showOverlay() {
        guard AppSettings.shared.isEnabled else {
            hideOverlay()
            return
        }
        // The playground draws ghost text inline inside its own NSTextView.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID == ProcessInfo.processInfo.processIdentifier || frontPID != caretApplicationPID {
            hideOverlay()
            return
        }

        guard hasValidCaretPosition else {
            hideOverlay()
            return
        }

        // KeyboardHook supplies the caret for this request and invalidates it
        // on clicks, scrolling and app switches. Drawing each streamed word
        // needs no second read of the focused app's text and window metadata.
        guard layoutAtCaret() else { hideOverlay(); return }
        orderFrontRegardless()
    }

    public func hideOverlay() {
        if isVisible {
            orderOut(nil)
        }
    }

}
