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
    private(set) var authorizationToken = UUID().uuidString

    private var serverProcess: Process?
    private var startupTask: Task<Void, Never>?
    private var generation = UUID()
    private var engineLog: FileHandle?
    private var healthCheckTask: Task<Void, Never>?
    private var idleWatchTimer: Timer?

    public var baseURL: String {
        "http://127.0.0.1:\(serverPort)/v1"
    }

    private init() {
        setupIdleWatcher()
    }

    public func locateLlamaServerBinary() -> String? {
        // Prefer the engine packaged and verified with this app.
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

        // Development builds can use a local Homebrew installation.
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
        if (isServerRunning || isStarting) && currentLoadedModelPath == modelPath { return }
        stopServer()
        guard LocalModelManager.isValidStandardGGUF(atPath: modelPath) else {
            serverStatus = "Model is missing or is not a valid GGUF file"
            return
        }
        isStarting = true
        authorizationToken = UUID().uuidString
        currentLoadedModelPath = modelPath
        serverStatus = "Starting local engine…"
        let id = generation
        startupTask = Task { [weak self] in
            guard let self else { return }
            let occupied = await self.checkExistingHealthyServer()
            guard !Task.isCancelled, self.generation == id else { return }
            guard !occupied else {
                self.isStarting = false
                self.currentLoadedModelPath = nil
                self.serverStatus = "Engine port is already in use. Stop the other server and retry."
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

        guard let binaryPath = locateLlamaServerBinary() else {
            self.serverStatus = "Engine not installed. Run brew install llama.cpp, then rebuild FreeTypist."
            self.isServerRunning = false
            self.isStarting = false
            return
        }

        self.isStarting = true
        self.serverStatus = "Loading model into Metal GPU..."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.environment = ProcessInfo.processInfo.environment.merging(["LLAMA_API_KEY": authorizationToken]) { _, new in new }

        let settings = AppSettings.shared
        // Optimized for ultra-low RAM & CPU footprint + disables Gemma 4 / Qwen 3 thinking trace overhead
        var args = [
            "-m", modelPath,
            "--port", "\(serverPort)",
            "--host", "127.0.0.1",
            "-ngl", "\(settings.gpuLayers)",          // Offload layers to Apple Metal GPU
            "-c", "\(settings.contextWindowSize)",    // Configurable context size for autocomplete
            "-np", "1",                               // Single parallel slot (cuts KV RAM by 75%)
            "-ctk", settings.kvCacheQuantization,     // Quantized K cache (q8_0 / q4_0 / f16)
            "-ctv", settings.kvCacheQuantization,     // Quantized V cache
            "-fa", "on",                              // Metal Flash Attention
            "--reasoning", "off",
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
        let logURL = AppStorage.directory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        engineLog = try? FileHandle(forWritingTo: logURL)
        process.standardError = engineLog ?? FileHandle.nullDevice

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self = self, self.serverProcess === terminated else { return }
                self.healthCheckTask?.cancel()
                self.serverProcess = nil
                try? self.engineLog?.close()
                self.engineLog = nil
                self.isServerRunning = false
                self.isStarting = false
                self.serverStatus = "Engine exited (code \(terminated.terminationStatus)). See \(logURL.path)."
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
        let id = generation
        healthCheckTask = Task { [weak self] in
            guard let self = self else { return }
            let healthURL = URL(string: "http://127.0.0.1:\(self.serverPort)/health")!

            // Allow larger models time to load; stop cleanly if startup never completes.
            for _ in 0..<180 {
                if Task.isCancelled || self.generation != id { return }
                if let proc = self.serverProcess, !proc.isRunning {
                    self.isServerRunning = false
                    self.isStarting = false
                    self.serverStatus = "Engine exited (Using Smart Local Predictor)"
                    return
                }

                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                guard self.generation == id else { return }
                var req = URLRequest(url: healthURL)
                req.timeoutInterval = 1.0

                if let (_, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   !Task.isCancelled, self.generation == id,
                   self.serverProcess?.isRunning == true {
                    self.serverStatus = "Preparing the first suggestion…"
                    await self.warmPrediction()
                    guard !Task.isCancelled, self.generation == id,
                          self.serverProcess?.isRunning == true else { return }
                    self.isServerRunning = true
                    self.isStarting = false
                    self.serverStatus = "Active (Metal GPU • Low-Memory KV)"
                    return
                }
            }

            guard !Task.isCancelled, self.generation == id else { return }
            self.stopServer(reason: "Model startup timed out. See engine.log for details.")
        }
    }

    /// Compile the first inference kernels and cache the stable instructions
    /// during startup, using synthetic text rather than the user's first draft.
    private func warmPrediction() async {
        let settings = AppSettings.shared
        let tone = settings.effectiveTone(for: nil)
        let context = PromptContext(precedingText: "The project is ready for ",
                                    personaDescription: settings.effectiveCustomInstructions(for: nil),
                                    toneInstruction: tone == .custom
                                        ? settings.customToneInstructions : tone.promptInstruction,
                                    maxWords: settings.completionLength.maxWords)
        let prompt = PromptBuilder.completionPrompt(context: context)
        var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            // One token only evaluates the prompt. Several tokens also warm
            // the incremental decoder used by the first visible suggestion.
            "messages": prompt.messages, "max_tokens": 4, "temperature": 0,
            "cache_prompt": true, "id_slot": 0, "stream": false,
            "reasoning_format": "none", "chat_template_kwargs": ["enable_thinking": false]
        ])
        _ = try? await URLSession.shared.data(for: request)
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
        generation = UUID()
        startupTask?.cancel()
        startupTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil

        let oldProcess = serverProcess
        serverProcess = nil
        if let oldProcess, oldProcess.isRunning { oldProcess.terminate() }
        try? engineLog?.close()
        engineLog = nil
        isServerRunning = false
        isStarting = false
        currentLoadedModelPath = nil
        serverStatus = reason
    }
}
