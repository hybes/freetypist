import Cocoa
import Combine
import Security

enum AccessibilityReadiness: Equatable {
    case needsAccess, needsKeyboardHook, ready
    init(accessGranted: Bool, hookRunning: Bool) {
        self = !accessGranted ? .needsAccess : (hookRunning ? .ready : .needsKeyboardHook)
    }
}

/// One source of truth for onboarding, Settings and the menu bar. This only
/// observes authorisation; the user grants access in macOS System Settings.
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    @Published private(set) var readiness: AccessibilityReadiness = .needsAccess
    @Published private(set) var hasRequestedAccess = false
    @Published private(set) var relaunchError: String?
    private var timer: Timer?
    private var activationObserver: AnyCancellable?

    var isReady: Bool { readiness == .ready }
    let appURL = Bundle.main.bundleURL
    let signingTeam: String? = {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any] else { return nil }
        return fields["teamid"] as? String
    }()

    func startMonitoring() {
        guard timer == nil else { refresh(); return }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let granted = AccessibilityService.isAccessibilityGranted()
        if granted {
            if !KeyboardHook.shared.isRunning { KeyboardHook.shared.start() }
        } else if KeyboardHook.shared.isRunning {
            KeyboardHook.shared.stop()
            CompletionEngine.shared.dismiss()
        }
        let next = AccessibilityReadiness(accessGranted: granted, hookRunning: KeyboardHook.shared.isRunning)
        if next != readiness { readiness = next; MenuBarController.shared.updateStatusButton(); MenuBarController.shared.rebuildMenu() }
    }

    func requestAccess() {
        hasRequestedAccess = true
        AccessibilityService.requestAccessibilityPermission()
        refresh()
    }

    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }

    func relaunch() {
        relaunchError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = Self.relaunchArguments(appURL: appURL, processID: ProcessInfo.processInfo.processIdentifier,
                                                  environment: ProcessInfo.processInfo.environment)
        // `open` may wait for the new application's launch handshake. Quit as
        // soon as it is started so the replacement can finish waiting for us.
        do { try process.run(); NSApp.terminate(nil) }
        catch { relaunchError = "Could not reopen FreeTypist: \(error.localizedDescription)" }
    }

    func stopMonitoring() {
        timer?.invalidate(); timer = nil; activationObserver = nil
    }

    static func relaunchArguments(appURL: URL, processID: Int32, environment: [String: String]) -> [String] {
        var arguments = ["-n"]
        // Keep review runs isolated after a user-requested restart as well.
        for key in ["FREETYPIST_DATA_DIRECTORY", "FREETYPIST_DEFAULTS_SUITE", "FREETYPIST_TEST_UPDATER"] {
            if let value = environment[key] { arguments += ["--env", "\(key)=\(value)"] }
        }
        return arguments + [appURL.path, "--args", "--wait-for-pid=\(processID)"]
    }
}
