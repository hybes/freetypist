import AppKit
import XCTest
@testable import FreeTypist

final class GhostOverlayTests: XCTestCase {
    @MainActor
    func testNativeTextViewCaretUsesTheTextLineRatherThanItsEmptyAXRange() throws {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 240, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = editor
        let screenTop = NSScreen.screens.first!.frame.maxY
        for fontSize: CGFloat in [12, 18, 28] {
            editor.font = NSFont(name: "Helvetica", size: fontSize)
            for text in ["The navbar needs to ", "One line.\nThe navbar needs to ",
                         "The navbar needs to wrap across several lines before we ",
                         "👩🏽‍💻 Café — the navbar needs to "] {
                editor.string = text
                let nsText = text as NSString
                for location in [0, nsText.range(of: "navbar").location + 3, nsText.length] {
                    editor.setSelectedRange(NSRange(location: location, length: 0))
                    editor.layoutManager?.ensureLayout(for: editor.textContainer!)
                    let native = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                    let ax = try XCTUnwrap(AccessibilityService.caretBounds(in: nsText, location: location) { range in
                        let cocoa = editor.accessibilityFrame(for: range)
                        // Public AX clients receive top-left screen coordinates.
                        return CGRect(x: cocoa.minX, y: screenTop - cocoa.maxY,
                                      width: cocoa.width, height: cocoa.height)
                    })
                    let resolved = AccessibilityService.cocoaCaretRect(from: ax, primaryScreenTop: screenTop)
                    XCTAssertEqual(resolved.minX, native.minX, accuracy: 0.01, "\(fontSize): \(text)")
                    XCTAssertEqual(resolved.minY, native.minY, accuracy: 0.01, "\(fontSize): \(text)")
                    XCTAssertEqual(resolved.height, native.height, accuracy: 0.01)
                }
            }
        }
    }

    func testCaretBoundsKeepValidWebCaretAndWrapAffinity() throws {
        let zero = CGRect(x: 120, y: 100, width: 0, height: 20)
        let glyph = CGRect(x: 120, y: 100, width: 10, height: 20)
        XCTAssertEqual(AccessibilityService.caretBounds(in: "hello", location: 2) {
            $0.length == 0 ? zero : glyph
        }, zero)
        // Right-to-left insertion points can sit at the glyph's right edge.
        let rtl = CGRect(x: 130, y: 80, width: 0, height: 20)
        XCTAssertEqual(AccessibilityService.caretBounds(in: "שלום", location: 2) {
            $0.length == 0 ? rtl : glyph
        }, CGRect(x: 130, y: 100, width: 0, height: 20))
        let wrapped = CGRect(x: 10, y: 120, width: 0, height: 20)
        XCTAssertEqual(AccessibilityService.caretBounds(in: "hello ", location: 6) {
            $0.length == 0 ? wrapped : glyph
        }, wrapped)
        XCTAssertEqual(AccessibilityService.caretBounds(in: "hello", location: 5) {
            $0.length == 0 ? nil : glyph
        }, CGRect(x: 130, y: 100, width: 0, height: 20))
        XCTAssertNil(AccessibilityService.caretBounds(in: "hello", location: 5) { _ in .zero })
        XCTAssertNil(AccessibilityService.caretBounds(in: "hello", location: 6) { _ in glyph })
    }

    func testCaretLookupUsesWholeComposedCharacters() {
        let text = "Go 👩🏽‍💻" as NSString
        var queried: [NSRange] = []
        _ = AccessibilityService.caretBounds(in: text, location: text.length) { range in
            queried.append(range)
            return CGRect(x: 100, y: 200, width: 20, height: 20)
        }
        XCTAssertEqual(queried.last, text.rangeOfComposedCharacterSequence(at: text.length - 1))
    }

    func testScreenConversionKeepsActualHeightAndOtherDisplayCoordinates() {
        for ax in [CGRect(x: 100, y: 200, width: 0, height: 14),
                   CGRect(x: -1200, y: -400, width: 1, height: 56),
                   CGRect(x: 3500, y: 1800, width: 1, height: 42)] {
            let cocoa = AccessibilityService.cocoaCaretRect(from: ax, primaryScreenTop: 1440)
            XCTAssertEqual(cocoa.minX, ax.minX)
            XCTAssertEqual(cocoa.maxY, 1440 - ax.minY)
            XCTAssertEqual(cocoa.height, ax.height)
        }
    }

    @MainActor
    func testStreamedOverlayStaysOnTheSameLineAndUsesTheCurrentFont() throws {
        let engine = CompletionEngine.shared
        let panel = GhostOverlayPanel.shared
        let settings = AppSettings.shared
        let previousBadges = settings.showShortcutBadges
        defer { engine.dismiss(); panel.invalidateCaretPosition(); settings.showShortcutBadges = previousBadges }
        let caret = CGRect(x: 400, y: 500, width: 1, height: 14)
        for badges in [false, true] {
            settings.showShortcutBadges = badges
            for text in ["be ", "be updated with the new logo and", "be responsive"] {
                engine.currentSuggestion = CompletionItem(fullText: text, providerName: "Test")
                panel.updatePosition(caretScreenRect: caret, fontSize: 12)
                panel.contentView?.layoutSubtreeIfNeeded()
                XCTAssertEqual(panel.frame.midY, caret.midY, accuracy: 1)
                XCTAssertEqual(panel.frame.minX, caret.maxX + (badges ? 2 : 0), accuracy: 1)
            }
        }
        let smallHeight = try XCTUnwrap(panel.contentView?.fittingSize.height)
        panel.updatePosition(caretScreenRect: caret, fontSize: 20)
        XCTAssertGreaterThan(try XCTUnwrap(panel.contentView?.fittingSize.height), smallHeight)
        panel.invalidateCaretPosition()
        panel.showOverlay()
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testLongInlineTextClipsAtDisplayEdgeWithoutCoveringTheDraft() throws {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let caret = CGRect(x: -90, y: 500, width: 1, height: 14)
        let frame = try XCTUnwrap(GhostOverlayPanel.placement(caret: caret,
            contentSize: CGSize(width: 400, height: 15), visibleFrame: screen, pureInline: true, belowCaret: false))
        XCTAssertEqual(frame.minX, caret.maxX)
        XCTAssertEqual(frame.maxX, screen.maxX - 8)
        XCTAssertEqual(frame.midY, caret.midY)
        XCTAssertNil(GhostOverlayPanel.placement(caret: CGRect(x: -10, y: 500, width: 1, height: 14),
            contentSize: CGSize(width: 400, height: 15), visibleFrame: screen, pureInline: true, belowCaret: false))
        let correction = try XCTUnwrap(GhostOverlayPanel.placement(caret: caret,
            contentSize: CGSize(width: 200, height: 24), visibleFrame: screen, pureInline: false, belowCaret: true))
        XCTAssertEqual(correction.maxY, caret.minY - 6)
        XCTAssertTrue(screen.contains(correction))
    }
}
