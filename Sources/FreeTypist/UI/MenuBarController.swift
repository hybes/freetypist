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
        let symbolName = effectivelyActive ? "sparkles" : "pause.circle"
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

        // Status Header
        let statusTitle: String
        if !settings.isEnabled {
            statusTitle = "○ Autocomplete: Paused"
        } else if isTemporarilyPaused {
            statusTitle = "◐ Autocomplete: Snoozed"
        } else if monitor.isSecureInputActive {
            statusTitle = "🔒 Protected Password Field Active"
        } else {
            statusTitle = "● Autocomplete: Active (\(String(format: "%.0f", monitor.appMemoryMB)) MB RAM)"
        }
        let statusHeaderItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        menu.addItem(NSMenuItem.separator())

        // Playground
        let playgroundItem = NSMenuItem(title: "🎮 Open Interactive Playground...", action: #selector(openPlayground), keyEquivalent: "p")
        playgroundItem.target = self
        menu.addItem(playgroundItem)

        // Quick Toggle
        let toggleItem = NSMenuItem(
            title: settings.isEnabled ? "Pause Autocomplete" : "Resume Autocomplete",
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

        // Quick Model Switcher Submenu
        let modelSubmenu = NSMenu()
        for provider in AIProviderType.allCases {
            let item = NSMenuItem(
                title: provider.rawValue,
                action: #selector(selectProvider(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider
            item.state = (settings.activeProvider == provider) ? .on : .off
            modelSubmenu.addItem(item)
        }
        let modelMenuItem = NSMenuItem(title: "Active Engine: \(settings.activeProvider.rawValue)", action: nil, keyEquivalent: "")
        modelMenuItem.submenu = modelSubmenu
        menu.addItem(modelMenuItem)

        // Personalization Strength Submenu
        let strengthSubmenu = NSMenu()
        for strength in PersonalizationStrength.allCases {
            let item = NSMenuItem(
                title: "\(strength.rawValue) — \(strength.subtitle)",
                action: #selector(selectStrength(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = strength.rawValue
            item.state = (settings.personalizationStrength == strength) ? .on : .off
            strengthSubmenu.addItem(item)
        }
        let strengthMenuItem = NSMenuItem(title: "Constant Learning: \(settings.personalizationStrength.rawValue)", action: nil, keyEquivalent: "")
        strengthMenuItem.submenu = strengthSubmenu
        menu.addItem(strengthMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Today's Stats
        let statsItem = NSMenuItem(
            title: "⚡️ \(stats.todayCompletionsAccepted) accepted today • \(stats.todayWordsSaved) words (\(stats.totalWordsSaved) total)",
            action: #selector(openStats),
            keyEquivalent: ""
        )
        statsItem.target = self
        menu.addItem(statsItem)

        // Writing History & Learning
        let historyItem = NSMenuItem(
            title: "🧠 Writing History & Learned Vocabulary (\(LearningEngine.shared.historyRecords.count))...",
            action: #selector(openHistory),
            keyEquivalent: "h"
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let prefsItem = NSMenuItem(title: "Settings & Personalization...", action: #selector(openAISettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // Permissions & Battery
        let permItem = NSMenuItem(title: "Battery, RAM & Accessibility Setup...", action: #selector(openPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        if LocalInferenceService.shared.isServerRunning {
            let sleepItem = NSMenuItem(title: "💤 Unload Local Model from RAM", action: #selector(sleepLocalModel), keyEquivalent: "")
            sleepItem.target = self
            menu.addItem(sleepItem)
        }

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

    @objc private func selectProvider(_ sender: NSMenuItem) {
        if let provider = sender.representedObject as? AIProviderType {
            AppSettings.shared.activeProvider = provider
            AppSettings.shared.baseURL = provider.defaultBaseURL
            AppSettings.shared.modelName = provider.defaultModel
            rebuildMenu()
        }
    }

    @objc private func selectStrength(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let strength = PersonalizationStrength(rawValue: raw) {
            AppSettings.shared.personalizationStrength = strength
            rebuildMenu()
        }
    }

    @objc private func sleepLocalModel() {
        LocalInferenceService.shared.stopServer()
        rebuildMenu()
    }

    @objc public func openPlayground() {
        openSettings(tab: 0)
    }

    @objc private func openAISettings() {
        openSettings(tab: 1)
    }

    @objc private func openHistory() {
        openSettings(tab: 3)
    }

    @objc private func openStats() {
        openSettings(tab: 5)
    }

    @objc private func openPermissions() {
        openSettings(tab: 6)
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
