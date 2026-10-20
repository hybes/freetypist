import Cocoa
import Combine
import SwiftUI

@MainActor
public final class MenuBarController: NSObject, NSMenuItemValidation {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pauseTimer: Timer?

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
        setupApplicationMenu()
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

        AppSettings.shared.$pausedUntilDate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                if let until = AppSettings.shared.pausedUntilDate, until <= Date() {
                    AppSettings.shared.pausedUntilDate = nil
                }
            }
        }
    }

    private func setupApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "FreeTypist", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "FreeTypist")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openAISettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let setup = NSMenuItem(title: "Setup FreeTypist…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        appMenu.addItem(setup)
        appMenu.addItem(updateMenuItem())
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FreeTypist", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
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
        } else if PermissionManager.shared.readiness == .needsAccess {
            statusTitle = "FreeTypist: Accessibility Access Needed"
        } else if !PermissionManager.shared.isReady {
            statusTitle = "FreeTypist: Keyboard Access Needed"
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
        let setupItem = NSMenuItem(title: "Setup FreeTypist…", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(updateMenuItem())

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit FreeTypist", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    private func updateMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || AppUpdater.shared.canCheckForUpdates
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

    @objc private func showSetup() { openSetup() }

    public func openSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Set up FreeTypist"
            window.center()
            window.isReleasedWhenClosed = false
            setupWindow = window
        }
        setupWindow?.contentView = NSHostingView(rootView: SetupView(onFinish: { [weak self] in
            self?.setupWindow?.close()
            self?.openSettings(tab: 0)
        }))
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
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
