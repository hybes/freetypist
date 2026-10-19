import Cocoa
import Combine
import SwiftUI

@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
    }

    private var isTemporarilyPaused: Bool {
        if let until = AppSettings.shared.pausedUntilDate, Date() < until {
            return true
        }
        return false
    }

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateStatusButton()
        rebuildMenu()

        // Observe stats & settings changes to update menu bar badge dynamically
        StatsManager.shared.$todayWordsSaved
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        AppSettings.shared.$showWordCountInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        AppSettings.shared.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    public func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let settings = AppSettings.shared
        let stats = StatsManager.shared

        let effectivelyActive = settings.isEnabled && !isTemporarilyPaused
        let symbolName = effectivelyActive ? "character.cursor.ibeam" : "pause.circle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "FreeTypist")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        if settings.showWordCountInMenuBar && stats.todayWordsSaved > 0 {
            button.title = " \(stats.todayWordsSaved)w"
        } else {
            button.title = ""
        }
    }

    public func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let settings = AppSettings.shared
        let stats = StatsManager.shared
        let monitor = SystemResourceMonitor.shared

        // Clean Status Header (Zero Emojis)
        let statusTitle: String
        if !settings.isEnabled {
            statusTitle = "FreeTypist: Paused"
        } else if isTemporarilyPaused {
            statusTitle = "FreeTypist: Snoozed"
        } else if monitor.isSecureInputActive {
            statusTitle = "FreeTypist: Protected Field Active"
        } else {
            statusTitle = "FreeTypist: Active (\(String(format: "%.0f", monitor.appMemoryMB)) MB)"
        }
        let statusHeaderItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        let statsItem = NSMenuItem(
            title: "\(stats.todayCompletionsAccepted) completions today (\(stats.todayWordsSaved) words saved)",
            action: #selector(openStats),
            keyEquivalent: ""
        )
        statsItem.target = self
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        // Quick Toggle
        let toggleItem = NSMenuItem(
            title: settings.isEnabled ? "Pause Completions" : "Resume Completions",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Snooze 15m
        let snoozeItem = NSMenuItem(
            title: isTemporarilyPaused ? "Resume from Snooze" : "Snooze for 15 Minutes",
            action: #selector(toggleSnooze15m),
            keyEquivalent: ""
        )
        snoozeItem.target = self
        menu.addItem(snoozeItem)

        menu.addItem(NSMenuItem.separator())

        // Playground
        let playgroundItem = NSMenuItem(title: "Open Playground...", action: #selector(openPlayground), keyEquivalent: "p")
        playgroundItem.target = self
        menu.addItem(playgroundItem)

        // Settings
        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(openAISettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit FreeTypist", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        AppSettings.shared.isEnabled.toggle()
        AppSettings.shared.pausedUntilDate = nil
        updateStatusButton()
        rebuildMenu()
    }

    @objc private func toggleSnooze15m() {
        if isTemporarilyPaused {
            AppSettings.shared.pausedUntilDate = nil
        } else {
            AppSettings.shared.pausedUntilDate = Date().addingTimeInterval(15 * 60)
        }
        updateStatusButton()
        rebuildMenu()
    }

    @objc public func openPlayground() {
        openSettings(tab: 0)
    }

    @objc private func openAISettings() {
        openSettings(tab: 1)
    }

    @objc private func openStats() {
        openSettings(tab: 4)
    }

    @objc public func openSettings(tab: Int = 0) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImg = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImg
        } else if let fallbackImg = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
            NSApplication.shared.applicationIconImage = fallbackImg
        }

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 760, height: 560)
            window.title = "FreeTypist"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        } else {
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
