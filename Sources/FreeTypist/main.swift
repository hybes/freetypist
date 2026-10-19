import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Auto-import Cotypist completion stats & preferences if installed
        if CotypistMigrator.shared.isCotypistInstalled {
            _ = CotypistMigrator.shared.migrateAllFromCotypist(includeDatabaseKeychainUnlock: false)
        }

        // Scan local models and auto-boot (or auto-download) on-device Metal engine
        LocalModelManager.shared.ensureDefaultModelReady()
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

        // If accessibility permission not yet granted, guide user
        if !AccessibilityService.isAccessibilityGranted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MenuBarController.shared.openSettings()
            }
        }

        print("🚀 FreeTypist started.")
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
              --test-local-engine      Test on-device Metal engine with Gemma 4 / Qwen
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
                print("✅ Mock Completion: '\(text)' (\(latency)ms)")
            } catch {
                print("❌ Mock Error: \(error)")
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
                print("Server starting at \(LocalInferenceService.shared.baseURL)")
            }
            return
        }

        if args.contains("--test-ollama") {
            let provider = OllamaProvider()
            let settings = AppSettings.shared
            if let res = try? await provider.testConnection(settings: settings) {
                print("Ollama Connection Test: \(res.success ? "✅ SUCCESS" : "❌ FAILED") - \(res.message) (\(res.latencyMs)ms)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
