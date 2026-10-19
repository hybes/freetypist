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

    public static let catalog: [LocalModelInfo] = [
        LocalModelInfo(
            id: "qwen-2.5-1.5b",
            name: "Qwen 2.5 1.5B",
            sizeText: "1.1 GB",
            expectedSizeBytes: 1_120_000_000,
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "llama-3.2-3b",
            name: "Llama 3.2 3B",
            sizeText: "2.0 GB",
            expectedSizeBytes: 2_020_000_000,
            filename: "llama-3.2-3b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "qwen-2.5-3b",
            name: "Qwen 2.5 3B",
            sizeText: "2.1 GB",
            expectedSizeBytes: 2_105_000_000,
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "llama-3.2-1b",
            name: "Llama 3.2 1B",
            sizeText: "0.8 GB",
            expectedSizeBytes: 808_000_000,
            filename: "llama-3.2-1b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 8
        )
    ]
}
