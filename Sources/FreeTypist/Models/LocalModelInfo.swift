import Foundation

public struct LocalModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sizeText: String
    public let filename: String
    public let downloadURLString: String
    public let minRAMGigabytes: Int
    public let tierBadge: String

    public init(
        id: String,
        name: String,
        sizeText: String,
        filename: String,
        downloadURLString: String,
        minRAMGigabytes: Int,
        tierBadge: String = "Unlocked"
    ) {
        self.id = id
        self.name = name
        self.sizeText = sizeText
        self.filename = filename
        self.downloadURLString = downloadURLString
        self.minRAMGigabytes = minRAMGigabytes
        self.tierBadge = tierBadge
    }

    public var displayName: String {
        "\(name) (\(sizeText))"
    }

    public static let catalog: [LocalModelInfo] = [
        LocalModelInfo(
            id: "gemma-4-e4b",
            name: "Gemma 4 E4B",
            sizeText: "6.2 GB",
            filename: "gemma-4-E4B-UD-Q5_K_XL.gguf",
            downloadURLString: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-UD-Q4_K_XL.gguf",
            minRAMGigabytes: 16,
            tierBadge: "Recommended"
        ),
        LocalModelInfo(
            id: "qwen-3-1.7b",
            name: "Qwen 3 1.7B",
            sizeText: "1.2 GB",
            filename: "Qwen3-1.7B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
            minRAMGigabytes: 8,
            tierBadge: "Fast & Light"
        ),
        LocalModelInfo(
            id: "qwen-3-4b",
            name: "Qwen 3 4B",
            sizeText: "2.6 GB",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
            minRAMGigabytes: 16,
            tierBadge: "Balanced"
        ),
        LocalModelInfo(
            id: "qwen-2.5-1.5b",
            name: "Qwen 2.5 1.5B",
            sizeText: "1.1 GB",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            minRAMGigabytes: 8,
            tierBadge: "Battery Saver"
        ),
        LocalModelInfo(
            id: "gemma-3-4b",
            name: "Gemma 3 4B",
            sizeText: "2.5 GB",
            filename: "gemma-3-4b-it-UD-Q4_K_XL.gguf",
            downloadURLString: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-UD-Q4_K_XL.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "gemma-3-1b",
            name: "Gemma 3 1B",
            sizeText: "0.8 GB",
            filename: "gemma-3-1b-it-UD-Q4_K_XL.gguf",
            downloadURLString: "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-UD-Q4_K_XL.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "llama-3.2-3b",
            name: "Llama 3.2 3B",
            sizeText: "2.0 GB",
            filename: "llama-3.2-3b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 16
        ),
        LocalModelInfo(
            id: "llama-3.2-1b",
            name: "Llama 3.2 1B",
            sizeText: "0.8 GB",
            filename: "llama-3.2-1b-instruct-q4_k_m.gguf",
            downloadURLString: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            minRAMGigabytes: 8
        ),
        LocalModelInfo(
            id: "qwen-3-8b",
            name: "Qwen 3 8B (Pro Unlocked)",
            sizeText: "5.0 GB",
            filename: "Qwen3-8B-Q4_K_M.gguf",
            downloadURLString: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
            minRAMGigabytes: 16,
            tierBadge: "Pro Unlocked"
        )
    ]
}
