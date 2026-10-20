import Cocoa
import ApplicationServices
import Combine
import Foundation

public struct ClipboardHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public let text: String
    public let sourceApp: String
    public let copiedAt: Date

    public init(id: UUID = UUID(), text: String, sourceApp: String, copiedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.copiedAt = copiedAt
    }
}

public struct CrossAppContextEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public let appName: String
    public let bundleId: String
    public let windowTitle: String
    public let domainOrURL: String?
    public let capturedSnippet: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        appName: String,
        bundleId: String,
        windowTitle: String,
        domainOrURL: String? = nil,
        capturedSnippet: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.domainOrURL = domainOrURL
        self.capturedSnippet = capturedSnippet
        self.timestamp = timestamp
    }
}

/// Deep On-Device Context Engine.
/// Since FreeTypist runs 100% locally on the user's Mac, it can synthesize rich context from:
/// 1. Visible text & conversation threads in the active window (AX hierarchy traversal)
/// 2. Active browser URL / document path (AXURL / AXDocument)
/// 3. Multi-item clipboard history ring buffer (last 10 copied items)
/// 4. Cross-app recent activity trail (what you were reading/writing in the previous 5 apps)
/// 5. Local user, date/time, and workspace metadata
@MainActor
public final class DeepContextCollector: ObservableObject {
    public static let shared = DeepContextCollector()

    @Published public private(set) var clipboardHistory: [ClipboardHistoryEntry] = []
    @Published public private(set) var crossAppTrail: [CrossAppContextEntry] = []
    @Published public private(set) var activeWindowSurroundingText: [String] = []
    @Published public private(set) var activeDocumentOrURL: String?
    @Published public private(set) var lastCapturedWindowTitle: String = ""
    @Published public private(set) var lastCapturedAppName: String = "FreeTypist"

    private var lastPasteboardChangeCount: Int = 0
    private var clipboardTimer: Timer?
    private var appSwitchObserver: NSObjectProtocol?
    private var settingsObserver: AnyCancellable?
    private var cachedWindowContextKey: String = ""
    private var windowCaptureTask: Task<Void, Never>?
    private var cachedWindowSnippets: [String] = []
    private var cachedWindowTimestamp: Date = .distantPast

    private init() {
        self.lastPasteboardChangeCount = NSPasteboard.general.changeCount
        if !AppStorage.isIsolated {
            captureSafeClipboard()
            startMonitoring()
        }
        settingsObserver = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let settings = AppSettings.shared
                if !settings.useClipboardContext { self.clipboardHistory = [] }
                if !settings.trackCrossAppContext { self.crossAppTrail = [] }
                if !settings.readSurroundingWindowText {
                    self.activeWindowSurroundingText = []
                    self.activeDocumentOrURL = nil
                    self.cachedWindowSnippets = []
                    self.cachedWindowContextKey = ""
                }
            }
    }

    public func startMonitoring() {
        clipboardTimer?.invalidate()
        // Lightweight 2.5s poll with 0.8s tolerance for clipboard changes (~0.0% CPU)
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardIfChanged()
            }
        }
        timer.tolerance = 0.8
        self.clipboardTimer = timer

        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleAppSwitch(to: app)
            }
        }
    }

    private func checkPasteboardIfChanged() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pb.changeCount

        captureSafeClipboard()
    }

    private func captureSafeClipboard() {
        let settings = AppSettings.shared
        guard settings.isEnabled, settings.useClipboardContext,
              !settings.isAppRecordingExcluded(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
              let raw = PromptBuilder.readSafeClipboardSnippet(enabled: true) else { return }
        let finalClip = raw

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Clipboard"
        clipboardHistory.removeAll { $0.text == finalClip }
        clipboardHistory.insert(
            ClipboardHistoryEntry(text: finalClip, sourceApp: frontApp, copiedAt: Date()),
            at: 0
        )
        let limit = settings.trackMultiClipboardHistory ? 10 : 1
        if clipboardHistory.count > limit {
            clipboardHistory.removeLast(clipboardHistory.count - limit)
        }
    }

    private func handleAppSwitch(to app: NSRunningApplication) {
        let settings = AppSettings.shared
        guard settings.isEnabled, settings.trackCrossAppContext,
              !settings.isAppRecordingExcluded(bundleIdentifier: app.bundleIdentifier) else { return }
        let appName = app.localizedName ?? "App"
        let bundleId = app.bundleIdentifier ?? "unknown"
        // Don't overwrite trail when opening FreeTypist's own settings window
        guard bundleId != Bundle.main.bundleIdentifier else { return }

        lastCapturedAppName = appName
        scheduleWindowCapture(pid: app.processIdentifier, appName: appName, bundleId: bundleId)
    }

    private func scheduleWindowCapture(pid: pid_t, appName: String, bundleId: String) {
        guard windowCaptureTask == nil else { return }
        let worker = Task.detached(priority: .utility) {
            Self.captureFocusedWindowHierarchy(pid: pid)
        }
        windowCaptureTask = Task { [weak self] in
            let snapshot = await worker.value
            guard let self else { return }
            self.windowCaptureTask = nil
            let settings = AppSettings.shared
            guard settings.isEnabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !settings.isAppRecordingExcluded(bundleIdentifier: bundleId) else { return }
            self.cachedWindowContextKey = String(pid)
            self.cachedWindowTimestamp = Date()
            if settings.readSurroundingWindowText {
                self.cachedWindowSnippets = snapshot.snippets
                self.activeWindowSurroundingText = snapshot.snippets
                self.activeDocumentOrURL = snapshot.documentOrURL
                self.lastCapturedWindowTitle = snapshot.windowTitle
            }
            if settings.trackCrossAppContext {
                self.recordCrossAppSnapshot(appName: appName, bundleId: bundleId,
                    windowTitle: snapshot.windowTitle, domainOrURL: snapshot.documentOrURL,
                    snippet: snapshot.snippets.prefix(2).joined(separator: " | "))
            }
        }
    }

    public func recordCrossAppSnapshot(
        appName: String,
        bundleId: String,
        windowTitle: String,
        domainOrURL: String?,
        snippet: String
    ) {
        let settings = AppSettings.shared
        guard settings.isEnabled, settings.trackCrossAppContext,
              !settings.isAppRecordingExcluded(bundleIdentifier: bundleId) else { return }
        let cleanSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSnippet.isEmpty || !windowTitle.isEmpty else { return }

        crossAppTrail.removeAll { $0.bundleId == bundleId && $0.windowTitle == windowTitle }
        crossAppTrail.insert(
            CrossAppContextEntry(
                appName: appName,
                bundleId: bundleId,
                windowTitle: windowTitle.isEmpty ? appName : windowTitle,
                domainOrURL: domainOrURL,
                capturedSnippet: String(cleanSnippet.prefix(320)),
                timestamp: Date()
            ),
            at: 0
        )
        if crossAppTrail.count > 8 {
            crossAppTrail.removeLast(crossAppTrail.count - 8)
        }
    }

    /// Captures visible text elements inside the active window (messages above reply box, email subject, headings, URLs)
    /// Uses a 2.5-second cache per window so rapid typing never re-walks the AX tree on every keystroke.
    public func gatherRichWindowContext(activeFieldText: String) -> (surroundingSnippets: [String], documentOrURL: String?) {
        let settings = AppSettings.shared
        guard settings.isEnabled, settings.readSurroundingWindowText else {
            return ([], nil)
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return (activeWindowSurroundingText, activeDocumentOrURL)
        }

        guard !settings.isAppRecordingExcluded(bundleIdentifier: frontApp.bundleIdentifier) else { return ([], nil) }
        guard frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return ([], nil) }
        let cacheKey = String(frontApp.processIdentifier)
        if cacheKey != cachedWindowContextKey || Date().timeIntervalSince(cachedWindowTimestamp) >= 2.5 {
            scheduleWindowCapture(pid: frontApp.processIdentifier, appName: frontApp.localizedName ?? "App",
                                  bundleId: frontApp.bundleIdentifier ?? "unknown")
        }
        // Never wait for a window scan on the keyboard/main thread, or reuse another app's window.
        guard cacheKey == cachedWindowContextKey else { return ([], nil) }
        return (cachedWindowSnippets, activeDocumentOrURL)
    }

    nonisolated private static func captureFocusedWindowHierarchy(
        pid: pid_t
    ) -> (windowTitle: String, documentOrURL: String?, snippets: [String]) {
        guard AXIsProcessTrusted() else { return ("", nil, []) }
        let deadline = Date().addingTimeInterval(0.1)
        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAX, 0.025)
        var focusedWinObj: AnyObject?
        guard AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focusedWinObj) == .success,
              let win = focusedWinObj else {
            return ("", nil, [])
        }
        let winAX = win as! AXUIElement

        var titleObj: AnyObject?
        AXUIElementCopyAttributeValue(winAX, kAXTitleAttribute as CFString, &titleObj)
        let windowTitle = (titleObj as? String) ?? ""

        var docObj: AnyObject?
        AXUIElementCopyAttributeValue(winAX, kAXDocumentAttribute as CFString, &docObj)
        var documentOrURL = docObj as? String

        // Bounded BFS traversal of up to 65 AX nodes in the active window to extract visible labels/messages/headings
        var queue: [AXUIElement] = [winAX]
        var visited = 0
        let maxNodes = 65
        var collected: [String] = []

        while !queue.isEmpty && visited < maxNodes && collected.count < 10 && Date() < deadline {
            let current = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(current, 0.025)

            var roleObj: AnyObject?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleObj)
            let role = (roleObj as? String) ?? ""

            var subroleObj: AnyObject?
            AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subroleObj)
            if (subroleObj as? String) == "AXSecureTextField" || ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
                continue
            }

            if documentOrURL == nil {
                var urlObj: AnyObject?
                if AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &urlObj) == .success {
                    if let url = urlObj as? URL {
                        documentOrURL = url.absoluteString
                    } else if let str = urlObj as? String {
                        documentOrURL = str
                    }
                }
            }

            // Extract text from StaticText, Heading, TextArea, Cell, Link, or WebArea description
            if ["AXStaticText", "AXHeading", "AXLink", "AXCell"].contains(role) {
                var valObj: AnyObject?
                if AXUIElementCopyAttributeValue(current, kAXValueAttribute as CFString, &valObj) == .success,
                   let str = (valObj as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   str.count >= 8,
                   !collected.contains(str) {
                    collected.append(String(str.prefix(240)))
                } else {
                    var descObj: AnyObject?
                    if AXUIElementCopyAttributeValue(current, kAXDescriptionAttribute as CFString, &descObj) == .success,
                       let desc = (descObj as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       desc.count >= 10,
                       !collected.contains(desc) {
                        collected.append(String(desc.prefix(240)))
                    }
                }
            }

            var childrenObj: AnyObject?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenObj) == .success,
               let children = childrenObj as? [AXUIElement] {
                for child in children.prefix(12) {
                    queue.append(child)
                }
            }
        }

        return (windowTitle, documentOrURL, collected)
    }

    /// Synthesizes a compact, high-signal multi-source local context block for PromptBuilder and OfflinePredictor
    public func buildSynthesizedContextSummary(
        currentAppName: String,
        currentBundleId: String?,
        activeFieldText: String
    ) -> String {
        let settings = AppSettings.shared
        guard settings.isEnabled, currentBundleId != "com.freetypist.playground",
              !settings.isAppRecordingExcluded(bundleIdentifier: currentBundleId) else { return "" }
        var sections: [String] = []

        // 1. User & Temporal Environment
        if settings.includeSystemAndUserMetadata {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
            let nowStr = formatter.string(from: Date())
            let fullName = NSFullUserName()
            let userLabel = fullName.isEmpty ? NSUserName() : fullName
            sections.append("User: \(userLabel) | Local Time: \(nowStr)")
        }

        // 2. Surrounding Window Text / Conversation Thread
        if settings.readSurroundingWindowText {
            let (windowSnippets, docURL) = gatherRichWindowContext(activeFieldText: activeFieldText)
            if let url = docURL, !url.isEmpty {
                sections.append("Active Document/URL: \(url)")
            }
            if !windowSnippets.isEmpty {
                let joined = windowSnippets.prefix(4).joined(separator: " • ")
                sections.append("Visible Window / Thread Context: \(joined)")
            }
        }

        // 3. Cross-App Recent Activity Trail
        if settings.trackCrossAppContext {
            let recentOtherApps = crossAppTrail
                .filter { $0.bundleId != currentBundleId && !settings.isAppRecordingExcluded(bundleIdentifier: $0.bundleId) }
                .prefix(3)
            if !recentOtherApps.isEmpty {
                let trailDesc = recentOtherApps.map { entry in
                    "[\(entry.appName) — \(entry.windowTitle): \(entry.capturedSnippet)]"
                }.joined(separator: " ; ")
                sections.append("Recent Cross-App Activity: \(trailDesc)")
            }
        }

        // 4. Multi-Clipboard Ring Buffer
        if settings.useClipboardContext && !clipboardHistory.isEmpty {
            let count = settings.trackMultiClipboardHistory ? min(3, clipboardHistory.count) : 1
            let clips = clipboardHistory.prefix(count).enumerated().map { idx, item in
                "Clip #\(idx + 1) (\(item.sourceApp)): \(item.text)"
            }.joined(separator: " | ")
            sections.append("Clipboard Memory: \(clips)")
        }

        let summary = sections.joined(separator: "\n")
        return settings.sanitizeSecretsLocally ? SecretSanitizer.sanitize(summary).sanitized : summary
    }

    public func addSimulatedWindowContext(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeWindowSurroundingText.removeAll { $0 == trimmed }
        activeWindowSurroundingText.insert(trimmed, at: 0)
        if activeWindowSurroundingText.count > 6 {
            activeWindowSurroundingText.removeLast()
        }
    }

    public func clearClipboardHistory() {
        clipboardHistory.removeAll()
    }

    public func clearCrossAppTrail() {
        crossAppTrail.removeAll()
    }
}
