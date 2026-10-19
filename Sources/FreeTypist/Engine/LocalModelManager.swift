import Cocoa
import SwiftUI
import Combine

@MainActor
public final class LocalModelManager: ObservableObject {
    public static let shared = LocalModelManager()

    @Published public var availableModels: [LocalModelInfo] = LocalModelInfo.catalog
    @Published public var selectedModel: LocalModelInfo
    @Published public var downloadedModelPaths: [String: String] = [:]
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadStatusMessage: String = ""

    private var downloadTask: URLSessionDownloadTask?
    private var activeDownloadingModel: LocalModelInfo?
    private var downloadDelegate: InternalDownloadDelegate?

    public var recommendedModel: LocalModelInfo {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Int(ramBytes / (1024 * 1024 * 1024))

        if ramGB >= 16 {
            return availableModels.first(where: { $0.id == "gemma-4-e4b" }) ?? availableModels[0]
        } else {
            return availableModels.first(where: { $0.id == "qwen-2.5-1.5b" }) ?? availableModels[1]
        }
    }

    public var freeTypistModelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FreeTypist/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var cotypistModelsDirectory: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("app.cotypist.Cotypist/Models", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            return dir
        }
        return nil
    }

    private init() {
        let defaultModel = LocalModelInfo.catalog[0]
        self.selectedModel = defaultModel

        self.selectedModel = recommendedModel
        scanLocalModels()
    }

    /// Verifies that a `.gguf` file starts with the standard 4-byte ASCII `"GGUF"` magic header (`0x47 0x47 0x55 0x46`)
    /// so Cotypist's encrypted `-Q5_C.gguf` / `-Q4_C.gguf` containers are never passed to `llama-server`.
    public nonisolated static func isValidStandardGGUF(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        // 'G' = 0x47, 'G' = 0x47, 'U' = 0x55, 'F' = 0x46
        return data[0] == 0x47 && data[1] == 0x47 && data[2] == 0x55 && data[3] == 0x46
    }

    public func scanLocalModels() {
        var found: [String: String] = [:]
        let fm = FileManager.default

        // 1. Scan FreeTypist Models Directory
        let freeDir = freeTypistModelsDirectory
        if let files = try? fm.contentsOfDirectory(atPath: freeDir.path) {
            for file in files where file.hasSuffix(".gguf") {
                let fullPath = freeDir.appendingPathComponent(file).path
                guard Self.isValidStandardGGUF(atPath: fullPath) else { continue }
                for model in availableModels {
                    if file.lowercased().contains(model.id) || file.lowercased() == model.filename.lowercased() {
                        found[model.id] = fullPath
                    }
                }
            }
        }

        // 2. Scan Cotypist Models Directory ONLY for unencrypted standard GGUF models
        if let coDir = cotypistModelsDirectory, let files = try? fm.contentsOfDirectory(atPath: coDir.path) {
            for file in files where file.hasSuffix(".gguf") {
                let fullPath = coDir.appendingPathComponent(file).path
                // Skip Cotypist's encrypted -Q5_C / -Q4_C containers that lack 'GGUF' magic bytes
                guard Self.isValidStandardGGUF(atPath: fullPath) else { continue }
                for model in availableModels {
                    if found[model.id] == nil {
                        if file.lowercased().contains("gemma-4") && model.id == "gemma-4-e4b" {
                            found[model.id] = fullPath
                        } else if file.lowercased().contains("qwen") && model.id == "qwen-2.5-1.5b" {
                            found[model.id] = fullPath
                        } else if file.lowercased().contains("llama-3.2-1b") && model.id == "llama-3.2-1b" {
                            found[model.id] = fullPath
                        } else if file.lowercased().contains("llama-3.2-3b") && model.id == "llama-3.2-3b" {
                            found[model.id] = fullPath
                        } else if file.lowercased() == model.filename.lowercased() {
                            found[model.id] = fullPath
                        }
                    }
                }
                if !found.values.contains(fullPath) {
                    found[file] = fullPath
                }
            }
        }

        self.downloadedModelPaths = found

        // If the selected model is not downloaded but another valid GGUF is, default to the downloaded one
        if downloadedModelPaths[selectedModel.id] == nil, let firstAvailableId = downloadedModelPaths.keys.first,
           let model = availableModels.first(where: { $0.id == firstAvailableId }) {
            self.selectedModel = model
        }
    }

    /// Automatically begins downloading a fast standard GGUF model (`gemma-3-1b` or `qwen-2.5-1.5b`) if no valid GGUF is installed yet.
    public func ensureDefaultModelReady() {
        scanLocalModels()
        guard downloadedModelPaths.isEmpty && !isDownloading else { return }
        if let fastModel = availableModels.first(where: { $0.id == "gemma-3-1b" }) ?? availableModels.first(where: { $0.id == "qwen-2.5-1.5b" }) {
            self.selectedModel = fastModel
            startDownload(model: fastModel)
        }
    }

    public func isModelDownloaded(_ model: LocalModelInfo) -> Bool {
        return downloadedModelPaths[model.id] != nil
    }

    public func activeModelPath() -> String? {
        return downloadedModelPaths[selectedModel.id]
    }

    public func revealInFinder() {
        let dir = freeTypistModelsDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    public func startDownload(model: LocalModelInfo) {
        guard !isDownloading else { return }
        guard let url = URL(string: model.downloadURLString) else { return }

        self.activeDownloadingModel = model
        self.isDownloading = true
        self.downloadProgress = 0.0
        self.downloadStatusMessage = "Connecting to download \(model.name)..."

        let delegate = InternalDownloadDelegate(
            onProgress: { [weak self] written, total in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if total > 0 {
                        let progress = Double(written) / Double(total)
                        let mbDownloaded = Double(written) / (1024 * 1024)
                        let mbTotal = Double(total) / (1024 * 1024)
                        self.downloadProgress = progress
                        self.downloadStatusMessage = String(format: "Downloading %.1f / %.1f MB (%.0f%%)", mbDownloaded, mbTotal, progress * 100)
                    }
                }
            },
            onFinish: { [weak self] location in
                Task { @MainActor [weak self] in
                    guard let self = self, let model = self.activeDownloadingModel else { return }
                    let targetURL = self.freeTypistModelsDirectory.appendingPathComponent(model.filename)
                    do {
                        if FileManager.default.fileExists(atPath: targetURL.path) {
                            try FileManager.default.removeItem(at: targetURL)
                        }
                        try FileManager.default.moveItem(at: location, to: targetURL)

                        self.scanLocalModels()
                        self.isDownloading = false
                        self.downloadStatusMessage = "Download completed!"
                        self.activeDownloadingModel = nil

                        LocalInferenceService.shared.startServer(for: targetURL.path)
                    } catch {
                        self.isDownloading = false
                        self.downloadStatusMessage = "Error saving model: \(error.localizedDescription)"
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let err = error as NSError?, err.code != NSURLErrorCancelled {
                        self.isDownloading = false
                        self.downloadStatusMessage = "Download failed: \(err.localizedDescription)"
                        self.activeDownloadingModel = nil
                    }
                }
            }
        )

        self.downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.downloadTask = task
        task.resume()
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
        downloadStatusMessage = ""
        activeDownloadingModel = nil
        downloadDelegate = nil
    }
}

// MARK: - Dedicated Download Delegate
final class InternalDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (URL) -> Void
    private let onError: @Sendable (Error?) -> Void

    init(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinish: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onFinish(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onError(error)
    }
}
