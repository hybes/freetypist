import Foundation

public struct LocalModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sizeText: String
    public let expectedSizeBytes: Int64
    public let filename: String
    public let downloadURLString: String
    public let minRAMGigabytes: Int

    public init(
        id: String,
        name: String,
        sizeText: String,
        expectedSizeBytes: Int64 = 1_500_000_000,
        filename: String,
        downloadURLString: String,
        minRAMGigabytes: Int
    ) {
        self.id = id
        self.name = name
        self.sizeText = sizeText
        self.expectedSizeBytes = expectedSizeBytes
        self.filename = filename
        self.downloadURLString = downloadURLString
        self.minRAMGigabytes = minRAMGigabytes
    }

    public var displayName: String {
        "\(name) (\(sizeText))"
    }

    /// Keep inline generation responsive without using most of an 8 GB Mac's memory.
    public static func recommended(forMemoryGB memoryGB: Int, models: [LocalModelInfo] = catalog) -> LocalModelInfo {
        precondition(!models.isEmpty)
        let preferredID = memoryGB >= 24 ? "qwen-3.5-4b" : memoryGB >= 16 ? "qwen-3.5-2b" : "qwen-3.5-0.8b"
        return models.first { $0.id == preferredID }
            ?? models.first { $0.minRAMGigabytes <= memoryGB }
            ?? models[0]
    }

    public static let catalog: [LocalModelInfo] = [
        LocalModelInfo(
            id: "qwen-3.5-0.8b",
            name: "Qwen 3.5 0.8B",
            sizeText: "0.53 GB",
            expectedSizeBytes: 532517120,
            filename: "Qwen3.5-0.8B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "qwen-3.5-2b",
            name: "Qwen 3.5 2B",
            sizeText: "1.28 GB",
            expectedSizeBytes: 1280835840,
            filename: "Qwen3.5-2B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "qwen-3.5-4b",
            name: "Qwen 3.5 4B",
            sizeText: "2.74 GB",
            expectedSizeBytes: 2740937888,
            filename: "Qwen3.5-4B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "qwen-2.5-1.5b",
            name: "Qwen 2.5 1.5B",
            sizeText: "1.1 GB",
            expectedSizeBytes: 1_117_320_736,
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "llama-3.2-3b",
            name: "Llama 3.2 3B",
            sizeText: "2.0 GB",
            expectedSizeBytes: 2_019_377_696,
            filename: "llama-3.2-3b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "qwen-2.5-3b",
            name: "Qwen 2.5 3B",
            sizeText: "2.1 GB",
            expectedSizeBytes: 2_104_932_768,
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "llama-3.2-1b",
            name: "Llama 3.2 1B",
            sizeText: "0.8 GB",
            expectedSizeBytes: 807_694_464,
            filename: "llama-3.2-1b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 8
        )
    ]
}
