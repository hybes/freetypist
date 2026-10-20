import Cocoa
import SwiftUI
import Combine

@MainActor
public final class LocalModelManager: ObservableObject {
    public static let shared = LocalModelManager()

    @Published public var availableModels: [LocalModelInfo] = LocalModelInfo.catalog
    @Published public var selectedModel: LocalModelInfo {
        didSet {
            userDefaults.set(selectedModel.id, forKey: "ft_selectedLocalModelID")
            CompletionLRUCache.shared.clear()
        }
    }
    @Published public var downloadedModelPaths: [String: String] = [:]
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadStatusMessage: String = ""
    @Published public private(set) var downloadError: String?

    private let modelsDirectory: URL
    private let userDefaults: UserDefaults
    private let memoryGB: Int
    private let sessionConfiguration: URLSessionConfiguration
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var downloadID: UUID?
    private var downloadDelegate: InternalDownloadDelegate?

    public var recommendedModel: LocalModelInfo {
        LocalModelInfo.recommended(forMemoryGB: memoryGB, models: availableModels)
    }

    public var freeTypistModelsDirectory: URL {
        let dir = modelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var cotypistModelsDirectory: URL? {
        guard !AppStorage.isIsolated else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("app.cotypist.Cotypist/Models", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            return dir
        }
        return nil
    }

    init(models: [LocalModelInfo] = LocalModelInfo.catalog, directory: URL? = nil,
         sessionConfiguration: URLSessionConfiguration = .default, defaults: UserDefaults = AppStorage.defaults,
         memoryGB: Int = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))) {
        precondition(!models.isEmpty)
        self.userDefaults = defaults
        self.memoryGB = memoryGB
        self.modelsDirectory = directory ?? AppStorage.directory.appendingPathComponent("Models", isDirectory: true)
        self.sessionConfiguration = sessionConfiguration
        self.availableModels = models
        let savedID = defaults.string(forKey: "ft_selectedLocalModelID")
        self.selectedModel = models.first { $0.id == savedID } ?? LocalModelInfo.recommended(forMemoryGB: memoryGB, models: models)
        scanLocalModels()
    }

    /// Verifies that a `.gguf` file starts with the standard 4-byte ASCII `"GGUF"` magic header (`0x47 0x47 0x55 0x46`)
    public nonisolated static func isValidStandardGGUF(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data[0] == 0x47 && data[1] == 0x47 && data[2] == 0x55 && data[3] == 0x46
    }

    public func scanLocalModels() {
        var found: [String: String] = [:]
        let fm = FileManager.default

        let freeDir = freeTypistModelsDirectory
        if let files = try? fm.contentsOfDirectory(atPath: freeDir.path) {
            for file in files where file.lowercased().hasSuffix(".gguf") {
                let fullPath = freeDir.appendingPathComponent(file).path
                guard Self.isValidStandardGGUF(atPath: fullPath) else { continue }
                for model in availableModels {
                    if file.lowercased().contains(model.id) || file.lowercased() == model.filename.lowercased() {
                        found[model.id] = fullPath
                    }
                }
            }
        }

        if let coDir = cotypistModelsDirectory, let files = try? fm.contentsOfDirectory(atPath: coDir.path) {
            for file in files where file.lowercased().hasSuffix(".gguf") {
                let fullPath = coDir.appendingPathComponent(file).path
                guard Self.isValidStandardGGUF(atPath: fullPath) else { continue }
                for model in availableModels {
                    if found[model.id] == nil && file.lowercased() == model.filename.lowercased() {
                        found[model.id] = fullPath
                    }
                }
            }
        }

        self.downloadedModelPaths = found


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
        // Cancel any previous download so clicking Download always responds immediately
        cancelDownload()
        downloadError = nil

        guard let url = URL(string: model.downloadURLString) else {
            self.downloadStatusMessage = "Invalid model URL."
            self.downloadError = downloadStatusMessage
            return
        }

        let id = UUID()
        self.downloadID = id
        self.isDownloading = true
        self.downloadProgress = 0.02
        self.downloadStatusMessage = "Starting download of \(model.name) (\(model.sizeText))..."

        let expectedBytes = model.expectedSizeBytes
        let delegate = InternalDownloadDelegate(
            onProgress: { [weak self] written, total in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downloadID == id else { return }
                    let effectiveTotal = total > 0 ? total : expectedBytes
                    let progress = min(max(Double(written) / Double(max(1, effectiveTotal)), 0.02), 0.99)
                    let mbDownloaded = Double(written) / (1024 * 1024)
                    let mbTotal = Double(effectiveTotal) / (1024 * 1024)
                    self.downloadProgress = progress
                    self.downloadStatusMessage = String(
                        format: "Downloading %@: %.1f MB / %.0f MB (%.0f%%)",
                        model.name,
                        mbDownloaded,
                        mbTotal,
                        progress * 100
                    )
                }
            },
            onFinish: { [weak self] location, statusCode in
                let fm = FileManager.default
                let tempCopy = fm.temporaryDirectory.appendingPathComponent("ft_dl_\(UUID().uuidString).gguf")
                try? fm.removeItem(at: tempCopy)
                let movedTemp = (try? fm.moveItem(at: location, to: tempCopy)) != nil

                Task { @MainActor [weak self] in
                    defer { try? FileManager.default.removeItem(at: tempCopy) }
                    guard let self = self, self.downloadID == id else { return }
                    defer { self.finishDownloadSession() }

                    if !(200...299).contains(statusCode) {
                        self.isDownloading = false
                        self.downloadProgress = 0.0
                        self.downloadStatusMessage = "Download failed (HTTP \(statusCode)). Please try another model."
                        self.downloadError = self.downloadStatusMessage
                        self.downloadID = nil
                        return
                    }

                    guard movedTemp, Self.isValidStandardGGUF(atPath: tempCopy.path) else {
                        self.isDownloading = false
                        self.downloadProgress = 0.0
                        self.downloadStatusMessage = "Downloaded file was not a valid GGUF model."
                        self.downloadError = self.downloadStatusMessage
                        self.downloadID = nil
                        return
                    }

                    let receivedBytes = (try? FileManager.default.attributesOfItem(atPath: tempCopy.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard receivedBytes == model.expectedSizeBytes else {
                        self.downloadProgress = 0
                        self.downloadStatusMessage = "Downloaded model was incomplete (\(receivedBytes) of \(model.expectedSizeBytes) bytes). Please retry."
                        self.downloadError = self.downloadStatusMessage
                        return
                    }
                    let targetURL = self.freeTypistModelsDirectory.appendingPathComponent(model.filename)
                    do {
                        if FileManager.default.fileExists(atPath: targetURL.path) {
                            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempCopy)
                        } else {
                            try FileManager.default.moveItem(at: tempCopy, to: targetURL)
                        }

                        self.selectedModel = model
                        self.scanLocalModels()
                        self.isDownloading = false
                        self.downloadProgress = 1.0
                        self.downloadStatusMessage = "\(model.name) downloaded and ready."
                        self.downloadID = nil

                        if AppSettings.shared.activeProvider == .localEmbedded {
                            LocalInferenceService.shared.startServer(for: targetURL.path)
                        }
                    } catch {
                        self.isDownloading = false
                        self.downloadStatusMessage = "Error saving model: \(error.localizedDescription)"
                        self.downloadError = self.downloadStatusMessage
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self = self, self.downloadID == id else { return }
                    if let err = error as NSError?, err.code != NSURLErrorCancelled {
                        self.isDownloading = false
                        self.downloadProgress = 0.0
                        self.downloadStatusMessage = "Download failed: \(err.localizedDescription)"
                        self.downloadError = self.downloadStatusMessage
                        self.finishDownloadSession()
                    }
                }
            }
        )

        self.downloadDelegate = delegate
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.downloadSession = session

        var request = URLRequest(url: url)
        request.setValue("FreeTypist/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.downloadTask = task
        task.resume()
    }

    private func finishDownloadSession() {
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        downloadTask = nil
        downloadDelegate = nil
        downloadID = nil
        isDownloading = false
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadSession?.invalidateAndCancel()
        downloadTask = nil
        downloadSession = nil
        isDownloading = false
        downloadProgress = 0.0
        downloadStatusMessage = "Download cancelled."
        downloadError = nil
        downloadID = nil
        downloadDelegate = nil
    }
}

// MARK: - Dedicated Download Delegate
final class InternalDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (URL, Int) -> Void
    private let onError: @Sendable (Error?) -> Void

    init(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinish: @escaping @Sendable (URL, Int) -> Void,
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
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        onFinish(location, code)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onError(error)
        }
    }
}
