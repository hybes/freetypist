import AppKit
import Combine

/// Observes the other typing app. Quitting is an explicit user action and uses
/// the normal application quit request, never force termination or TCC changes.
@MainActor
final class CotypistMonitor: ObservableObject {
    static let shared = CotypistMonitor()
    static let bundleIdentifier = "app.cotypist.Cotypist"

    @Published private(set) var runningProcessCount = 0
    @Published private(set) var appURL: URL?
    @Published private(set) var isQuitting = false
    @Published private(set) var actionError: String?
    var isRunning: Bool { runningProcessCount > 0 }
    var isInstalled: Bool { appURL != nil || isRunning }

    private let runningProcessIDs: () -> [pid_t]
    private let requestTermination: (pid_t) -> Bool
    private let locateApp: () -> URL?
    private let quitTimeoutNanoseconds: UInt64
    private var observers = Set<AnyCancellable>()
    private var quitCheck: Task<Void, Never>?

    init(runningProcessIDs: (() -> [pid_t])? = nil,
         requestTermination: ((pid_t) -> Bool)? = nil,
         locateApp: (() -> URL?)? = nil,
         quitTimeoutNanoseconds: UInt64 = 3_000_000_000) {
        self.runningProcessIDs = runningProcessIDs ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
                .filter { !$0.isTerminated }.map(\.processIdentifier)
        }
        self.requestTermination = requestTermination ?? { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == Self.bundleIdentifier, !app.isTerminated else { return false }
            return app.terminate()
        }
        self.locateApp = locateApp ?? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        self.quitTimeoutNanoseconds = quitTimeoutNanoseconds
        refresh()
    }

    func startMonitoring() {
        guard observers.isEmpty else { refresh(); return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &observers)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
        refresh()
    }

    func refresh() {
        let count = runningProcessIDs().count
        if count != runningProcessCount { runningProcessCount = count }
        let installed = locateApp()
        if installed != appURL { appURL = installed }
        if count == 0 {
            isQuitting = false
            actionError = nil
            quitCheck?.cancel()
            quitCheck = nil
        }
    }

    func quitCotypist() {
        guard !isQuitting else { return }
        actionError = nil
        let processes = runningProcessIDs()
        guard !processes.isEmpty else { refresh(); return }
        isQuitting = true
        // Request every instance once; do not short-circuit after a refusal.
        let accepted = processes.map(requestTermination).allSatisfy { $0 }
        refresh()
        guard isRunning else { return }
        if !accepted {
            isQuitting = false
            actionError = "Cotypist did not accept the quit request. Open Cotypist and choose Quit from its menu."
            return
        }
        quitCheck = Task { [weak self, quitTimeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: quitTimeoutNanoseconds) }
            catch { return }
            guard let self else { return }
            self.refresh()
            if self.isRunning {
                self.isQuitting = false
                self.actionError = "Cotypist is still running. Check it for an open dialog, then try quitting again."
            }
        }
    }

    func openLoginItems() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            actionError = "Open System Settings → General → Login Items & Extensions to manage Cotypist at login."
        }
    }

    func stopMonitoring() {
        observers.removeAll()
        quitCheck?.cancel()
        quitCheck = nil
    }
}
