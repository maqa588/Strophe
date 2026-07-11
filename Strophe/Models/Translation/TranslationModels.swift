import Foundation
import Combine
import Security

enum TranslationProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama
    case openAICompatible
    case anthropicCompatible

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAICompatible: return "GPT / OpenAI 兼容"
        case .anthropicCompatible: return "Anthropic 兼容"
        }
    }

    nonisolated var defaultEndpoint: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropicCompatible: return "https://api.anthropic.com/v1"
        }
    }

    nonisolated var defaultModel: String {
        switch self {
        case .ollama: return "qwen3:8b"
        case .openAICompatible: return "gpt-4.1-mini"
        case .anthropicCompatible: return "claude-sonnet-4-5"
        }
    }

    nonisolated var needsAPIKey: Bool { self != .ollama }
}

struct TranslationLLMConfiguration: Sendable {
    var provider: TranslationProvider
    var endpoint: String
    var model: String
    var apiKey: String
}

struct TranslationRequestItem: Identifiable, Codable, Sendable {
    var id: UUID
    var text: String
}

struct TranslationResponseItem: Identifiable, Codable, Sendable {
    var id: UUID
    var translation: String
}

enum SubtitleLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case thai = "th"
    case vietnamese = "vi"

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .auto: return "auto_detect"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁体中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .portuguese: return "葡萄牙语"
        case .italian: return "意大利语"
        case .russian: return "俄语"
        case .arabic: return "阿拉伯语"
        case .thai: return "泰语"
        case .vietnamese: return "越南语"
        }
    }
}

enum AutoWrapLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case words
    case continuous

    var id: String { rawValue }
    var title: String { self == .words ? "单词型" : "连续型" }
}

enum AutoWrapOutputMode: String, CaseIterable, Identifiable, Sendable {
    case insertLineBreaks
    case splitSubtitleBlocks

    var id: String { rawValue }
    var title: String { self == .insertLineBreaks ? "插入换行符" : "切分字幕块" }
}

@MainActor
final class TranslationSettingsStore: ObservableObject {
    static let shared = TranslationSettingsStore()

    @Published var provider: TranslationProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            loadProviderFields()
        }
    }
    @Published var endpoint: String = ""
    @Published var model: String = ""
    @Published var apiKey: String = ""

    private let defaults = UserDefaults.standard
    private var isLoading = false

    private enum Keys {
        static let provider = "translation.provider"
        static func endpoint(_ provider: TranslationProvider) -> String { "translation.\(provider.rawValue).endpoint" }
        static func model(_ provider: TranslationProvider) -> String { "translation.\(provider.rawValue).model" }
    }

    private init() {
        provider = TranslationProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .ollama
        loadProviderFields()
    }

    func save() {
        guard !isLoading else { return }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedEndpoint, forKey: Keys.endpoint(provider))
        defaults.set(trimmedModel, forKey: Keys.model(provider))
        TranslationKeychain.save(apiKey, account: provider.rawValue)
    }

    var configuration: TranslationLLMConfiguration {
        TranslationLLMConfiguration(
            provider: provider,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func loadProviderFields() {
        isLoading = true
        endpoint = defaults.string(forKey: Keys.endpoint(provider)) ?? provider.defaultEndpoint
        model = defaults.string(forKey: Keys.model(provider)) ?? provider.defaultModel
        apiKey = TranslationKeychain.load(account: provider.rawValue) ?? ""
        isLoading = false
    }
}

private enum TranslationKeychain {
    private static let service = "com.strophe.translation"

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var insert = query
        insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
