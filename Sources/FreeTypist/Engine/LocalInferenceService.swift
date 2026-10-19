import Cocoa
import Foundation
import Combine

@MainActor
public final class LocalInferenceService: ObservableObject {
    public static let shared = LocalInferenceService()

    @Published public var isServerRunning: Bool = false
    @Published public var isStarting: Bool = false
    @Published public var currentLoadedModelPath: String?
    @Published public var serverStatus: String = "Ready"
    @Published public var serverPort: Int = 58855
    @Published public var lastInferenceDate: Date = Date()

    private var serverProcess: Process?
    private var healthCheckTask: Task<Void, Never>?
    private var idleWatchTimer: Timer?

    public var baseURL: String {
        "http://127.0.0.1:\(serverPort)/v1"
    }

    private init() {
        setupIdleWatcher()
    }

    public func locateLlamaServerBinary() -> String? {
        // 1. Prefer Homebrew's latest llama-server first (supports Gemma 4 & has matched system @rpath dylibs)
        let homebrewPaths = [
            "/opt/homebrew/bin/llama-server",
            "/opt/homebrew/opt/llama.cpp/bin/llama-server",
            "/usr/local/bin/llama-server"
        ]

        for path in homebrewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Fallback to App Bundle (MacOS or Resources)
        if let execURL = Bundle.main.executableURL {
            let bundleBin = execURL.deletingLastPathComponent().appendingPathComponent("llama-server").path
            if FileManager.default.isExecutableFile(atPath: bundleBin) {
                return bundleBin
            }
        }

        if let resURL = Bundle.main.resourceURL {
            let resBin = resURL.appendingPathComponent("llama-server").path
            if FileManager.default.isExecutableFile(atPath: resBin) {
                return resBin
            }
        }

        return nil
    }

    public func markActivity() {
        lastInferenceDate = Date()
        if !isServerRunning && !isStarting,
           AppSettings.shared.activeProvider == .localEmbedded,
           let path = LocalModelManager.shared.activeModelPath() {
            startServer(for: path)
        }
    }

    public func startServer(for modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            self.serverStatus = "Model file not found"
            self.isServerRunning = false
            self.isStarting = false
            return
        }

        if (isServerRunning || isStarting) && currentLoadedModelPath == modelPath {
            return
        }

        // First check if a healthy llama-server is already listening on port 58855
        Task { @MainActor in
            if await self.checkExistingHealthyServer() && self.currentLoadedModelPath == nil {
                self.currentLoadedModelPath = modelPath
                self.isServerRunning = true
                self.isStarting = false
                self.serverStatus = "Active (Metal GPU • Low-Memory KV)"
                return
            }
            self.launchProcess(for: modelPath)
        }
    }

    private func checkExistingHealthyServer() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.6
        if let (_, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, http.statusCode == 200 {
            return true
        }
        return false
    }

    private func launchProcess(for modelPath: String) {
        stopServer()

        guard let binaryPath = locateLlamaServerBinary() else {
            self.serverStatus = "Built-in Fast Engine (No llama-server binary)"
            self.isServerRunning = false
            self.isStarting = false
            return
        }

        self.isStarting = true
        self.serverStatus = "Loading model into Metal GPU..."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let settings = AppSettings.shared
        // Optimized for ultra-low RAM & CPU footprint + disables Gemma 4 / Qwen 3 thinking trace overhead
        var args = [
            "-m", modelPath,
            "--port", "\(serverPort)",
            "-ngl", "\(settings.gpuLayers)",          // Offload layers to Apple Metal GPU
            "-c", "\(settings.contextWindowSize)",    // Configurable context size for autocomplete
            "-np", "1",                               // Single parallel slot (cuts KV RAM by 75%)
            "-ctk", settings.kvCacheQuantization,     // Quantized K cache (q8_0 / q4_0 / f16)
            "-ctv", settings.kvCacheQuantization,     // Quantized V cache
            "-fa", "on",                              // Metal Flash Attention
            "--reasoning-budget", "0",                // Disable thinking tokens so completion begins immediately
            "--reasoning-format", "none",
            "--threads", "\(settings.cpuThreads)"     // Configurable CPU threads
        ]

        let lora = AppSettings.shared.selectedLoRAAdapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lora.isEmpty && FileManager.default.fileExists(atPath: lora) {
            args.append(contentsOf: ["--lora", lora])
        }

        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isServerRunning = false
                self.isStarting = false
                if self.serverStatus != "Sleeping (Idle Memory Saver)" {
                    self.serverStatus = "Stopped"
                }
            }
        }

        do {
            try process.run()
            self.serverProcess = process
            self.currentLoadedModelPath = modelPath
            self.pollHealthCheck()
        } catch {
            self.serverStatus = "Failed to launch: \(error.localizedDescription)"
            self.isServerRunning = false
            self.isStarting = false
        }
    }

    private func pollHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            guard let self = self else { return }
            let healthURL = URL(string: "http://127.0.0.1:\(self.serverPort)/health")!

            // Poll up to 60 * 350ms (~21 seconds for large 6.2GB models to map into Metal)
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if let proc = self.serverProcess, !proc.isRunning {
                    self.isServerRunning = false
                    self.isStarting = false
                    self.serverStatus = "Engine exited (Using Smart Local Predictor)"
                    return
                }

                try? await Task.sleep(nanoseconds: 350_000_000)

                var req = URLRequest(url: healthURL)
                req.timeoutInterval = 1.0

                if let (_, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.isServerRunning = true
                    self.isStarting = false
                    self.serverStatus = "Active (Metal GPU • Low-Memory KV)"
                    return
                }
            }

            if let proc = self.serverProcess, proc.isRunning {
                self.isStarting = false
                self.serverStatus = "Warming up model..."
            } else {
                self.isServerRunning = false
                self.isStarting = false
                self.serverStatus = "Offline (Using Smart Local Predictor)"
            }
        }
    }

    private func setupIdleWatcher() {
        // Check once every 60 seconds with 10s tolerance -> 0% CPU impact
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isServerRunning else { return }
                let sleepMins = AppSettings.shared.idleEngineSleepMinutes
                guard sleepMins > 0 else { return }
                let idleSeconds = Date().timeIntervalSince(self.lastInferenceDate)
                if idleSeconds > Double(sleepMins * 60) && SystemResourceMonitor.shared.isOnBatteryPower {
                    self.stopServer(reason: "Sleeping (Idle Memory Saver)")
                }
            }
        }
        timer.tolerance = 10.0
        self.idleWatchTimer = timer
    }

    public func stopServer(reason: String = "Stopped") {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        if let proc = serverProcess, proc.isRunning {
            proc.terminate()
        }
        serverProcess = nil
        isServerRunning = false
        isStarting = false
        currentLoadedModelPath = nil
        serverStatus = reason
    }
}
