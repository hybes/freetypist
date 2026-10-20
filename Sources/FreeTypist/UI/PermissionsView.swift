import AppKit
import SwiftUI

public struct PermissionsView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var showRecovery = false
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permissions.isReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 24)).foregroundColor(permissions.isReady ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if permissions.readiness == .needsAccess {
                HStack(spacing: 10) {
                    Button("Allow Accessibility…") { permissions.requestAccess() }.buttonStyle(.borderedProminent)
                    Button("Open System Settings") { AccessibilityService.openSystemSettingsAccessibility() }
                    Button("Recheck") { permissions.refresh() }
                }
                Text("In System Settings → Privacy & Security → Accessibility, enable FreeTypist. On newer macOS versions, this pane may be called Device Control and Data Access.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if permissions.isReady {
                Button("Open System Settings") { AccessibilityService.openSystemSettingsAccessibility() }.controlSize(.small)
            }
            if !permissions.isReady {
                HStack(spacing: 12) {
                    AppFileDragIcon(appURL: permissions.appURL)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drag this icon into the app list in System Settings")
                            .font(.callout.weight(.medium))
                        Text("Then turn on FreeTypist. If the list does not accept the drop, use + to add this app.")
                            .font(.caption).foregroundColor(.secondary)
                        Text(permissions.appURL.path)
                            .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Show in Finder") { permissions.revealApp() }
                }
                DisclosureGroup("Already enabled in System Settings?", isExpanded: $showRecovery) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Turn FreeTypist off and on again, then choose Recheck.")
                        Text("2. If it still fails, remove the old FreeTypist entry with −. Drag the icon above into the list, or add this app with +, then enable it.")
                        Text("3. Quit and reopen FreeTypist to refresh its access. Your settings and setup progress are saved; the Playground closes.")
                        Button("Quit & Reopen FreeTypist") { permissions.relaunch() }
                        if permissions.signingTeam == nil {
                            Text("This development build needs access again after it changes. Signed releases keep a stable identity between updates.")
                                .foregroundColor(.secondary)
                        }
                    }.font(.callout).padding(.top, 8)
                }
                if permissions.readiness == .needsKeyboardHook {
                    Button("Quit & Reopen FreeTypist") { permissions.relaunch() }
                }
            }
            if let error = permissions.relaunchError { Text(error).foregroundColor(.red).font(.caption) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill((permissions.isReady ? Color.green : Color.orange).opacity(0.06)))
        .onAppear { permissions.startMonitoring() }
        .onChange(of: permissions.hasRequestedAccess) { _, requested in
            if requested && !permissions.isReady { showRecovery = true }
        }
    }

    private var title: String {
        switch permissions.readiness {
        case .ready: "Accessibility is working"
        case .needsAccess: "Allow FreeTypist to work in other apps"
        case .needsKeyboardHook: "Accessibility is allowed; keyboard access needs a restart"
        }
    }
    private var detail: String {
        switch permissions.readiness {
        case .ready: "macOS allows this copy of FreeTypist to read the cursor, and its keyboard hook is active."
        case .needsAccess: "FreeTypist needs this to place suggestions beside your cursor and insert the text you accept. Password fields are excluded."
        case .needsKeyboardHook: "FreeTypist can read the cursor, but it cannot intercept Tab yet. Quit and reopen it, then recheck."
        }
    }
}

/// Export the running app as a file URL, like dragging it from Finder. Only
/// copying is offered so a drop cannot move the installed application.
private struct AppFileDragIcon: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> DragImageView { DragImageView(appURL: appURL) }
    func updateNSView(_ view: DragImageView, context: Context) { view.appURL = appURL }

    final class DragImageView: NSImageView, NSDraggingSource {
        var appURL: URL {
            didSet { image = NSWorkspace.shared.icon(forFile: appURL.path) }
        }

        init(appURL: URL) {
            self.appURL = appURL
            super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
            image = NSWorkspace.shared.icon(forFile: appURL.path)
            imageScaling = .scaleProportionallyUpOrDown
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("FreeTypist app, drag to System Settings")
            setAccessibilityHelp("Drag this app into the Accessibility app list. Show in Finder is also available beside this icon.")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) { }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    }
}
