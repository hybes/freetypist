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

        // Scan local models and boot on-device Metal engine if a model is already downloaded
        LocalModelManager.shared.scanLocalModels()
        if AppSettings.shared.activeProvider == .localEmbedded,
           let modelPath = LocalModelManager.shared.activeModelPath() {
            LocalInferenceService.shared.startServer(for: modelPath)
        }

        // Initialize Menubar
        MenuBarController.shared.setup()

        // Initialize Floating Ghost Overlay
        _ = GhostOverlayPanel.shared

        // Start Keyboard Hook
        KeyboardHook.shared.start()

        // Open main window so user can immediately see Playground & Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MenuBarController.shared.openSettings(tab: 0)
        }

        print("FreeTypist started.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardHook.shared.stop()
        LocalInferenceService.shared.stopServer()
    }
}

@main
struct FreeTypistAppMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments

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
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                LocalInferenceService.shared.stopServer()
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
        app.run()
    }
}
