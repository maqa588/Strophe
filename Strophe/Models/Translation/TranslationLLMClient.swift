import Foundation

enum TranslationClientError: LocalizedError {
    case invalidEndpoint
    case missingModel
    case missingAPIKey
    case missingModalCredentials
    case missingCloudflareAccountID
    case invalidResponse
    case server(status: Int, message: String)
    case malformedTranslation

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "翻译服务地址无效。"
        case .missingModel: return "请填写模型名称。"
        case .missingAPIKey: return "请填写 API 密钥。"
        case .missingModalCredentials: return "请填写 Modal-Key 和 Modal-Secret。"
        case .missingCloudflareAccountID: return "请填写 Cloudflare Account ID。"
        case .invalidResponse: return "翻译服务返回了无法识别的响应。"
        case let .server(status, message): return "翻译服务请求失败（\(status)）：\(message)"
        case .malformedTranslation: return "模型没有按要求返回字幕翻译结果。"
        }
    }
}

actor TranslationLLMClient {
    static let shared = TranslationLLMClient()

    func translate(
        _ text: String,
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage,
        configuration: TranslationLLMConfiguration
    ) async throws -> String {
        let prompt = """
        Translate the subtitle below from \(sourceLanguage.title) to \(targetLanguage.title).
        Preserve meaning, tone, names, punctuation, and intentional line breaks. Keep it concise and natural for on-screen subtitles.
        Return only the translated subtitle, without explanation or quotation marks.

        \(text)
        """
        return try await request(prompt: prompt, configuration: configuration)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateBatch(
        _ items: [TranslationRequestItem],
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage,
        configuration: TranslationLLMConfiguration
    ) async throws -> [TranslationResponseItem] {
        guard !items.isEmpty else { return [] }
        let payload = try JSONEncoder().encode(items)
        let sourceJSON = String(data: payload, encoding: .utf8) ?? "[]"
        let prompt = """
        You are a professional subtitle translator. Translate every item from \(sourceLanguage.title) to \(targetLanguage.title).
        Preserve each UUID exactly. Preserve meaning, tone, names, punctuation, and intentional line breaks. Keep translations concise and natural for on-screen subtitles.
        Return ONLY a valid JSON array in this exact shape: [{"id":"UUID","translation":"translated text"}]. Do not use Markdown.

        Input JSON:
        \(sourceJSON)
        """

        let raw = try await request(prompt: prompt, configuration: configuration, isJSON: true)
        if let decoded = decodeBatch(raw), Set(decoded.map(\.id)) == Set(items.map(\.id)) {
            return decoded
        }

        // Compatibility fallback for models that do not reliably follow JSON output instructions.
        var fallback: [TranslationResponseItem] = []
        fallback.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            let translated = try await translate(
                item.text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                configuration: configuration
            )
            fallback.append(TranslationResponseItem(id: item.id, translation: translated))
        }
        return fallback
    }

    private func request(
        prompt: String,
        configuration: TranslationLLMConfiguration,
        isJSON: Bool = false
    ) async throws -> String {
        guard !configuration.model.isEmpty else { throw TranslationClientError.missingModel }
        if configuration.provider == .modal && (configuration.apiKey.isEmpty || configuration.apiSecret.isEmpty) {
            throw TranslationClientError.missingModalCredentials
        } else if configuration.provider == .cloudflare && configuration.accountID.isEmpty {
            throw TranslationClientError.missingCloudflareAccountID
        } else if configuration.provider.needsAPIKey && configuration.apiKey.isEmpty {
            throw TranslationClientError.missingAPIKey
        }
        guard let url = endpointURL(for: configuration) else { throw TranslationClientError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        switch configuration.provider.apiProtocol {
        case .ollama:
            var ollamaBody: [String: Any] = [
                "model": configuration.model,
                "stream": false,
                "think": false,
                "messages": [
                    ["role": "system", "content": "You translate subtitles precisely and return only the requested output."],
                    ["role": "user", "content": prompt]
                ],
                "options": ["temperature": 0.1]
            ]
            if isJSON {
                ollamaBody["format"] = "json"
            }
            body = ollamaBody
        case .openAI:
            if configuration.provider == .modal {
                request.setValue(configuration.apiKey, forHTTPHeaderField: "Modal-Key")
                request.setValue(configuration.apiSecret, forHTTPHeaderField: "Modal-Secret")
            } else {
                request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            }
            var openAIBody: [String: Any] = [
                "model": configuration.model,
                "messages": [
                    ["role": "system", "content": "You translate subtitles precisely and return only the requested output."],
                    ["role": "user", "content": prompt]
                ]
            ]
            let usesHeterogeneousModels = configuration.provider == .nvidia
                || configuration.provider == .modal
                || configuration.provider == .tencent
                || configuration.provider == .openrouter
                || configuration.provider == .cloudflare
            if !usesHeterogeneousModels {
                openAIBody["temperature"] = 0.1
            }
            if isJSON && !usesHeterogeneousModels {
                openAIBody["response_format"] = ["type": "json_object"]
            }
            body = openAIBody
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": configuration.model,
                "max_tokens": 8192,
                "temperature": 0.1,
                "system": "You translate subtitles precisely and return only the requested output.",
                "messages": [["role": "user", "content": prompt]]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = serverMessage(from: data)
            throw TranslationClientError.server(status: http.statusCode, message: message)
        }
        return try responseText(from: data, provider: configuration.provider)
    }

    private func endpointURL(for configuration: TranslationLLMConfiguration) -> URL? {
        let raw = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw), components.scheme != nil else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix: String
        switch configuration.provider.apiProtocol {
        case .ollama: suffix = "api/chat"
        case .openAI: suffix = "chat/completions"
        case .anthropic: suffix = "messages"
        }
        if !path.hasSuffix(suffix) {
            path = path.isEmpty ? suffix : "\(path)/\(suffix)"
        }
        components.path = "/\(path)"
        return components.url
    }

    private func responseText(from data: Data, provider: TranslationProvider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationClientError.invalidResponse
        }
        switch provider.apiProtocol {
        case .ollama:
            if let message = json["message"] as? [String: Any], let content = message["content"] as? String {
                return content
            }
        case .openAI:
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        case .anthropic:
            if let content = json["content"] as? [[String: Any]],
               let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                return text
            }
        }
        throw TranslationClientError.invalidResponse
    }

    private func serverMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
        }
        return String(data: data, encoding: .utf8)?.prefix(500).description ?? "未知错误"
    }

    private func decodeBatch(_ raw: String) -> [TranslationResponseItem]? {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start <= end else { return nil }
        let json = String(cleaned[start...end])
        return try? JSONDecoder().decode([TranslationResponseItem].self, from: Data(json.utf8))
    }
}
