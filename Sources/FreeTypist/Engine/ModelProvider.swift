import Foundation

public protocol ModelProvider: Sendable {
    func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int)
    func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int)
}

/// Thread-safe LRU cache to avoid redundant LLM calls when backspacing or retyping
public final class CompletionLRUCache: @unchecked Sendable {
    public static let shared = CompletionLRUCache()

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var order: [String] = []
    private let capacity = 160

    private init() {}

    public func get(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    public func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if storage[key] == nil {
            order.append(key)
            if order.count > capacity, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
        storage[key] = value
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        order.removeAll()
        lock.unlock()
    }
}

public struct ModelProviderFactory {
    public static func provider(for type: AIProviderType) -> ModelProvider {
        switch type {
        case .localEmbedded:
            return EmbeddedLocalProvider()
        case .ollama:
            return OllamaProvider()
        case .mock:
            return MockProvider()
        }
    }
}

// MARK: - On-Device Embedded Local Provider (Cotypist Replica Engine)
public struct EmbeddedLocalProvider: ModelProvider {
    private let allowFallback: Bool
    public init(allowFallback: Bool = true) { self.allowFallback = allowFallback }

    private func fallback(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        guard allowFallback else {
            throw NSError(domain: "FreeTypist.LocalModel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The local model did not return a completion. Check that it is running, then retry."])
        }
        return try await MockProvider().complete(context: context, settings: settings)
    }

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        try Task.checkCancellation()
        let modelIdentity = await MainActor.run {
            LocalInferenceService.shared.currentLoadedModelPath ?? LocalModelManager.shared.selectedModel.id
        }
        let onBattery = await MainActor.run { SystemResourceMonitor.shared.isOnBatteryPower }
        let keyParts = [PromptBuilder.buildSystemPrompt(context: context), PromptBuilder.buildUserPrompt(context: context),
                        modelIdentity, settings.selectedLoRAAdapterPath, String(settings.temperature), String(settings.topP),
                        String(settings.topK), String(settings.repeatPenalty), settings.personalizationStrength.rawValue,
                        String(onBattery && settings.batteryShorterCompletions)]
        let cacheKey = String(decoding: try JSONEncoder().encode(keyParts), as: UTF8.self)
        if allowFallback, let cached = CompletionLRUCache.shared.get(forKey: cacheKey) { return (cached, 1) }

        // Check if Constant Learning Booster has a strong personal phrase match
        if allowFallback, settings.personalizationStrength == .strong,
           let boosterMatch = LearningEngine.shared.predictFromLearnedHistory(
               precedingText: context.precedingText,
               strength: .strong
           ),
           !boosterMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = PromptBuilder.cleanCompletionText(boosterMatch, precedingText: context.precedingText, maxWords: context.maxWords)
            return (cleaned, 2)
        }

        let serverReady = await MainActor.run {
            LocalInferenceService.shared.markActivity()
            return LocalInferenceService.shared.isServerRunning
        }

        if !serverReady {
            return try await fallback(context: context, settings: settings)
        }

        let startTime = DispatchTime.now()
        let baseURL = await MainActor.run { LocalInferenceService.shared.baseURL }
        guard let url = URL(string: baseURL + "/chat/completions") else {
            return try await fallback(context: context, settings: settings)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = await MainActor.run { LocalInferenceService.shared.authorizationToken }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3.5

        let systemPrompt = PromptBuilder.buildSystemPrompt(context: context)
        let userPrompt = PromptBuilder.buildUserPrompt(context: context)

        let effectiveMaxTokens: Int
        if onBattery && settings.batteryShorterCompletions {
            effectiveMaxTokens = min(14, settings.completionLength.maxTokens)
        } else {
            effectiveMaxTokens = settings.completionLength.maxTokens
        }

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": effectiveMaxTokens,
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "top_k": settings.topK,
            "repeat_penalty": settings.repeatPenalty,
            "cache_prompt": true,
            "id_slot": 0,
            "reasoning_format": "none",
            "chat_template_kwargs": ["enable_thinking": false],
            "stop": ["\n\n", "<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<turn|>"],
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return try await fallback(context: context, settings: settings)
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any] {
                let rawContent = (message["content"] as? String) ?? ""
                let cleaned = PromptBuilder.cleanCompletionText(
                    rawContent,
                    precedingText: context.precedingText,
                    maxWords: context.maxWords
                )

                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if allowFallback { CompletionLRUCache.shared.set(cleaned, forKey: cacheKey) }
                    return (cleaned, latencyMs)
                }
            }

            // Never return an empty string; fall back to the fast local predictor
            return try await fallback(context: context, settings: settings)
        } catch {
            try Task.checkCancellation()
            if !allowFallback { throw error }
            return try await fallback(context: context, settings: settings)
        }
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        let port = await MainActor.run { LocalInferenceService.shared.serverPort }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return (false, "Invalid local URL", 0)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return (true, "On-Device Metal Engine running (\(latencyMs)ms)", latencyMs)
            } else {
                return (false, "Local server returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)", latencyMs)
            }
        } catch {
            return (false, "Metal engine is unavailable; the built-in predictor is available.", 0)
        }
    }
}

// MARK: - Ollama Provider
public struct OllamaProvider: ModelProvider {
    public init() {}

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        let baseURL = (settings.activeProvider == .ollama ? settings.baseURL : AIProviderType.ollama.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0

        let systemPrompt = PromptBuilder.buildSystemPrompt(context: context)
        let userPrompt = PromptBuilder.buildUserPrompt(context: context)

        let body: [String: Any] = [
            "model": settings.activeProvider == .ollama && !settings.modelName.isEmpty ? settings.modelName : AIProviderType.ollama.defaultModel,
            "system": systemPrompt,
            "prompt": userPrompt,
            "stream": false,
            "options": [
                "temperature": settings.temperature,
                "num_predict": settings.completionLength.maxTokens
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = DispatchTime.now()
        let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "OllamaError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawResponse = json["response"] as? String {
            let cleaned = PromptBuilder.cleanCompletionText(rawResponse, precedingText: context.precedingText, maxWords: context.maxWords)
            if !cleaned.isEmpty {
                return (cleaned, latencyMs)
            }
        }

        return try await MockProvider().complete(context: context, settings: settings)
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        let baseURL = (settings.activeProvider == .ollama ? settings.baseURL : AIProviderType.ollama.defaultBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            return (false, "Invalid URL: \(baseURL)", 0)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return (false, "Ollama returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)", latencyMs)
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let modelNames = models.compactMap { $0["name"] as? String }
                let msg = "Connected! Found \(modelNames.count) local models: " + modelNames.prefix(3).joined(separator: ", ")
                return (true, msg, latencyMs)
            }
            return (true, "Connected to Ollama successfully (\(latencyMs)ms)", latencyMs)
        } catch {
            return (false, "Could not reach Ollama at \(baseURL): \(error.localizedDescription)", 0)
        }
    }
}

// MARK: - OpenAI-Compatible Provider (LM Studio, Groq, OpenAI, DeepSeek, LocalAI)
public struct OpenAICompatibleProvider: ModelProvider {
    public init() {}

    private func normalizedURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.hasSuffix("/v1") && !base.contains("/v1/") && !base.hasSuffix("/chat/completions") {
            base += "/v1"
        }
        if !base.hasSuffix("/chat/completions") {
            base += "/chat/completions"
        }
        return URL(string: base)
    }

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        guard let url = normalizedURL(baseURL: settings.baseURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 4.0

        let systemPrompt = PromptBuilder.buildSystemPrompt(context: context)
        let userPrompt = PromptBuilder.buildUserPrompt(context: context)

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": settings.completionLength.maxTokens,
            "temperature": settings.temperature,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = DispatchTime.now()
        let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "OpenAIError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            let cleaned = PromptBuilder.cleanCompletionText(content, precedingText: context.precedingText, maxWords: context.maxWords)
            return (cleaned, latencyMs)
        }

        return ("", latencyMs)
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        guard let url = normalizedURL(baseURL: settings.baseURL) else {
            return (false, "Invalid endpoint URL: \(settings.baseURL)", 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 4.0

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": [
                ["role": "user", "content": "Hi"]
            ],
            "max_tokens": 5
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let errorText = String(data: data, encoding: .utf8) ?? "Error code \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return (false, "API returned error: \(errorText)", latencyMs)
            }

            return (true, "Connection successful! Latency: \(latencyMs)ms", latencyMs)
        } catch {
            return (false, "Connection failed: \(error.localizedDescription)", 0)
        }
    }
}

// MARK: - Anthropic Provider
public struct AnthropicProvider: ModelProvider {
    public init() {}

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 4.0

        let systemPrompt = PromptBuilder.buildSystemPrompt(context: context)
        let userPrompt = PromptBuilder.buildUserPrompt(context: context)

        let body: [String: Any] = [
            "model": settings.modelName.isEmpty ? "claude-3-5-haiku-20241022" : settings.modelName,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": settings.completionLength.maxTokens,
            "temperature": settings.temperature
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = DispatchTime.now()
        let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "AnthropicError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let contents = json["content"] as? [[String: Any]],
           let first = contents.first,
           let text = first["text"] as? String {
            let cleaned = PromptBuilder.cleanCompletionText(text, precedingText: context.precedingText, maxWords: context.maxWords)
            return (cleaned, latencyMs)
        }

        return ("", latencyMs)
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return (false, "Invalid Anthropic URL", 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.apiKey.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 4.0

        let body: [String: Any] = [
            "model": settings.modelName.isEmpty ? "claude-3-5-haiku-20241022" : settings.modelName,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 5
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let errorText = String(data: data, encoding: .utf8) ?? "Status \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return (false, "Anthropic API error: \(errorText)", latencyMs)
            }

            return (true, "Connected to Claude successfully! Latency: \(latencyMs)ms", latencyMs)
        } catch {
            return (false, "Failed to connect to Anthropic: \(error.localizedDescription)", 0)
        }
    }
}

// MARK: - Google Gemini Provider
public struct GeminiProvider: ModelProvider {
    public init() {}

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        let model = settings.modelName.isEmpty ? "gemini-2.0-flash" : settings.modelName
        let key = settings.apiKey.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4.0

        let systemPrompt = PromptBuilder.buildSystemPrompt(context: context)
        let userPrompt = PromptBuilder.buildUserPrompt(context: context)

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userPrompt]]
                ]
            ],
            "generationConfig": [
                "temperature": settings.temperature,
                "maxOutputTokens": settings.completionLength.maxTokens
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let endTime = DispatchTime.now()
        let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw NSError(domain: "GeminiError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let firstPart = parts.first,
           let text = firstPart["text"] as? String {
            let cleaned = PromptBuilder.cleanCompletionText(text, precedingText: context.precedingText, maxWords: context.maxWords)
            return (cleaned, latencyMs)
        }

        return ("", latencyMs)
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        let startTime = DispatchTime.now()
        let model = settings.modelName.isEmpty ? "gemini-2.0-flash" : settings.modelName
        let key = settings.apiKey.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)") else {
            return (false, "Invalid Gemini URL", 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4.0

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "Hi"]]]],
            "generationConfig": ["maxOutputTokens": 5]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let latencyMs = Int((endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let errorText = String(data: data, encoding: .utf8) ?? "Status \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return (false, "Gemini API error: \(errorText)", latencyMs)
            }

            return (true, "Connected to Gemini (\(model))! Latency: \(latencyMs)ms", latencyMs)
        } catch {
            return (false, "Failed to connect to Gemini: \(error.localizedDescription)", 0)
        }
    }
}

// MARK: - Smart Local Predictor Fallback
public struct MockProvider: ModelProvider {
    public init() {}

    public func complete(context: PromptContext, settings: AppSettings) async throws -> (text: String, latencyMs: Int) {
        try Task.checkCancellation()
        let text = OfflinePredictor().complete(context: context, tone: settings.effectiveTone(for: context.bundleIdentifier))
        return (PromptBuilder.cleanCompletionText(text, precedingText: context.precedingText, maxWords: context.maxWords), 3)
    }

    public func testConnection(settings: AppSettings) async throws -> (success: Bool, message: String, latencyMs: Int) {
        return (true, "Smart Local Predictor is ready", 0)
    }
}
