import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure only one instance of FreeTypist runs at a time so older processes never duplicate menu bar icons or keyboard hooks
        let myPID = ProcessInfo.processInfo.processIdentifier
        for runningApp in NSWorkspace.shared.runningApplications {
            if runningApp.processIdentifier != myPID,
               (runningApp.bundleIdentifier == "com.freetypist.app" || runningApp.localizedName == "FreeTypist") {
                runningApp.terminate()
            }
        }

        // Run as a menu bar accessory application
        NSApp.setActivationPolicy(.accessory)

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImg = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImg
        } else if let fallbackImg = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
            NSApplication.shared.applicationIconImage = fallbackImg
        }

        // Start Deep Local Context Collector
        _ = DeepContextCollector.shared

        // Refresh Cotypist detection
        CotypistMigrator.shared.refreshDetection()
        CotypistMonitor.shared.startMonitoring()

        // Scan local models and boot on-device Metal engine if a model is already downloaded
        LocalModelManager.shared.scanLocalModels()
        if AppSettings.shared.activeProvider == .localEmbedded,
           let modelPath = LocalModelManager.shared.activeModelPath() {
            LocalInferenceService.shared.startServer(for: modelPath)
        }

        // Initialize Menubar
        MenuBarController.shared.setup()
        AppUpdater.shared.start()

        // Initialize Floating Ghost Overlay
        _ = GhostOverlayPanel.shared

        // Start Keyboard Hook
        PermissionManager.shared.startMonitoring()

        // Open main window so user can immediately see Playground & Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if SetupState.shared.isCompleted { MenuBarController.shared.openSettings(tab: 0) }
            else { MenuBarController.shared.openSetup() }
        }

        print("FreeTypist started.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardHook.shared.stop()
        PermissionManager.shared.stopMonitoring()
        CotypistMonitor.shared.stopMonitoring()
        LocalInferenceService.shared.stopServer()
    }
}

@main
struct FreeTypistAppMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        // A user-requested relaunch waits for the previous process to release its
        // keyboard tap and inference port before starting the replacement.
        if let arg = args.first(where: { $0.hasPrefix("--wait-for-pid=") }),
           let pid = Int32(arg.dropFirst("--wait-for-pid=".count)), pid > 1 {
            for _ in 0..<200 {
                if kill(pid, 0) != 0 { break }
                // Do not enter Swift's main-queue executor before installing the
                // AppKit delegate: launch events could otherwise finish first.
                usleep(50_000)
            }
        }

        if args.contains("--help") || args.contains("-h") {
            print("""
            FreeTypist — On-Device Predictive Typing for macOS
            
            Usage:
              FreeTypist [options]
            
            Options:
              --test-mock              Test offline predictive engine directly
              --test-ollama            Test local Ollama connection
              --test-local-engine      Test on-device Metal engine
              --help, -h               Show this help message
            """)
            return
        }

        if args.contains("--test-mock") {
            let provider = MockProvider()
            let settings = AppSettings.shared
            let context = PromptContext(precedingText: "thank you for")
            do {
                let (text, latency) = try await provider.complete(context: context, settings: settings)
                print("Mock Completion: '\(text)' (\(latency)ms)")
            } catch {
                print("Mock Error: \(error)")
            }
            return
        }

        if args.contains("--test-local-engine") {
            LocalModelManager.shared.scanLocalModels()
            let paths = LocalModelManager.shared.downloadedModelPaths
            print("Found \(paths.count) local models:")
            for (id, path) in paths {
                print(" - \(id): \(path)")
            }
            if let activePath = LocalModelManager.shared.activeModelPath() {
                print("Starting server for \(activePath)...")
                LocalInferenceService.shared.startServer(for: activePath)
                for _ in 0..<750 {
                    if LocalInferenceService.shared.isServerRunning || !LocalInferenceService.shared.isStarting { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard LocalInferenceService.shared.isServerRunning else {
                    print("Engine test failed: \(LocalInferenceService.shared.serverStatus)")
                    LocalInferenceService.shared.stopServer()
                    exit(EXIT_FAILURE)
                }
                let suite = "com.freetypist.diagnostic.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                let settings = AppSettings(defaults: defaults)
                settings.personalizationStrength = .off
                do {
                    for prefix in ["Thank you for ", "I think we should ", "The next step is to "] {
                        let result = try await EmbeddedLocalProvider(allowFallback: false).complete(
                            context: PromptContext(precedingText: prefix, maxWords: 4), settings: settings)
                        print("Engine completion: '\(prefix)' + '\(result.text)' (\(result.latencyMs)ms)")
                    }
                } catch {
                    print("Engine completion failed: \(error.localizedDescription)")
                    LocalInferenceService.shared.stopServer()
                    defaults.removePersistentDomain(forName: suite)
                    exit(EXIT_FAILURE)
                }
                defaults.removePersistentDomain(forName: suite)
                LocalInferenceService.shared.stopServer()
            } else {
                print("No downloaded model is selected. Download one in General settings first.")
                exit(EXIT_FAILURE)
            }
            return
        }

        if args.contains("--test-ollama") {
            let provider = OllamaProvider()
            let settings = AppSettings.shared
            do {
                let res = try await provider.testConnection(settings: settings)
                print("Ollama Connection Test: \(res.success ? "SUCCESS" : "FAILED") - \(res.message) (\(res.latencyMs)ms)")
            } catch {
                print("Ollama Error: \(error)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
