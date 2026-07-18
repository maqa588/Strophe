import Foundation
import Combine
import Security

enum TranslationAPIProtocol: String, Sendable {
    case ollama
    case openAI
    case anthropic
}

enum TranslationProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai
    case anthropic
    case google
    case grok
    case deepseek
    case nvidia
    case ollama
    case meta
    case kimi
    case minimax
    case volcengine
    case plamo
    case baidu
    case modal
    case tencent
    case openrouter
    case sakana
    case cloudflare
    case glm
    case qwen
    case openAICompatible
    case anthropicCompatible

    nonisolated var id: String { rawValue }

    nonisolated var apiProtocol: TranslationAPIProtocol {
        switch self {
        case .ollama:
            return .ollama
        case .anthropic, .anthropicCompatible:
            return .anthropic
        default:
            return .openAI
        }
    }

    nonisolated var logoName: String? {
        switch self {
        case .openai, .anthropic, .google, .grok, .deepseek, .nvidia, .ollama, .meta, .kimi, .minimax, .volcengine, .plamo, .baidu, .modal, .tencent, .openrouter, .sakana, .cloudflare, .glm, .qwen:
            return "provider_\(rawValue)"
        default:
            return nil
        }
    }

    nonisolated var allowsCustomEndpoint: Bool {
        self == .modal || self == .openAICompatible || self == .anthropicCompatible
    }

    nonisolated var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google AI Studio"
        case .grok: return "Grok / xAI"
        case .deepseek: return "DeepSeek"
        case .nvidia: return "NVIDIA NIM"
        case .ollama: return "Ollama"
        case .meta: return "Meta Llama"
        case .kimi: return "Kimi / Moonshot"
        case .minimax: return "MiniMax"
        case .volcengine: return "字节火山"
        case .plamo: return "PLaMo"
        case .baidu: return "百度千帆"
        case .modal: return "Modal"
        case .tencent: return "腾讯云 TokenHub"
        case .openrouter: return "OpenRouter"
        case .sakana: return "Sakana AI"
        case .cloudflare: return "Cloudflare Workers AI"
        case .glm: return "智谱 GLM"
        case .qwen: return "通义千问 Qwen"
        case .openAICompatible: return "GPT / OpenAI 兼容"
        case .anthropicCompatible: return "Anthropic 兼容"
        }
    }

    nonisolated var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .grok: return "https://api.x.ai/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .nvidia: return "https://integrate.api.nvidia.com/v1"
        case .ollama: return "http://127.0.0.1:11434"
        case .meta: return "https://api.llama.com/compat/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .minimax: return "https://api.minimaxi.com/v1"
        case .volcengine: return "https://ark.cn-beijing.volces.com/api/v3"
        case .plamo: return "https://api.platform.preferredai.jp/v1"
        case .baidu: return "https://qianfan.baidubce.com/v2"
        case .modal: return ""
        case .tencent: return "https://tokenhub.tencentmaas.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .sakana: return "https://api.sakana.ai/v1"
        case .cloudflare: return "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openAICompatible, .anthropicCompatible: return ""
        }
    }

    nonisolated var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.6-terra"
        case .anthropic: return "claude-sonnet-5"
        case .google: return "gemini-3.5-flash"
        case .grok: return "grok-4.5"
        case .deepseek: return "deepseek-v4-flash"
        case .nvidia: return "nvidia/nemotron-3-super-120b-a12b"
        case .ollama: return "qwen3.5:9b"
        case .meta: return "Llama-4-Maverick-17B-128E-Instruct-FP8"
        case .kimi: return "kimi-k3"
        case .minimax: return "MiniMax-M3"
        case .volcengine: return "doubao-seed-evolving"
        case .plamo: return "plamo-3.0-prime"
        case .baidu: return "ernie-5.1"
        case .modal: return "Qwen/Qwen3.5-4B"
        case .tencent: return "hy-mt2-pro"
        case .openrouter: return "~openai/gpt-latest"
        case .sakana: return "fugu"
        case .cloudflare: return "@cf/zai-org/glm-4.7-flash"
        case .glm: return "glm-5.2"
        case .qwen: return "qwen3.7-plus"
        case .openAICompatible, .anthropicCompatible: return ""
        }
    }

    nonisolated var modelOptions: [String] {
        switch self {
        case .openai:
            return ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.6-luna"]
        case .anthropic:
            return ["claude-sonnet-5", "claude-opus-4-8", "claude-fable-5", "claude-haiku-4-5"]
        case .google:
            return ["gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite"]
        case .grok:
            return ["grok-4.5", "grok-4.3", "grok-4.20-0309-non-reasoning", "grok-4.20-0309-reasoning"]
        case .deepseek:
            return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .nvidia:
            return ["nvidia/nemotron-3-super-120b-a12b", "qwen/qwen3.5-122b-a10b", "openai/gpt-oss-120b", "meta/llama-4-maverick-17b-128e-instruct"]
        case .ollama:
            return ["qwen3.5:0.8b", "qwen3.5:2b", "qwen3.5:4b", "qwen3.5:9b", "qwen3.5:27b"]
        case .meta:
            return ["Llama-4-Maverick-17B-128E-Instruct-FP8", "Llama-4-Scout-17B-16E-Instruct-FP8"]
        case .kimi:
            return ["kimi-k3", "kimi-k2.6", "kimi-k2.5"]
        case .minimax:
            return ["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed"]
        case .volcengine:
            return ["doubao-seed-evolving", "doubao-seed-2-1-pro", "doubao-seed-2-1-turbo"]
        case .plamo:
            return ["plamo-3.0-prime"]
        case .baidu:
            return ["ernie-5.1", "ernie-5.0", "ernie-5.0-thinking-latest", "ernie-4.5-turbo-128k-preview"]
        case .modal:
            return ["Qwen/Qwen3.5-4B", "Qwen/Qwen3.6-27B", "google/gemma-4-26B-A4B-it"]
        case .tencent:
            return ["hy-mt2-pro", "hy3", "deepseek-v4-flash", "glm-5.2", "kimi-k2.6", "minimax-m3", "qwen3.5-plus"]
        case .openrouter:
            return ["~openai/gpt-latest", "~anthropic/claude-sonnet-latest", "~google/gemini-flash-latest", "~google/gemini-pro-latest", "openrouter/auto"]
        case .sakana:
            return ["fugu", "fugu-ultra", "fugu-ultra-20260615"]
        case .cloudflare:
            return ["@cf/zai-org/glm-4.7-flash", "@cf/google/gemma-4-26b-a4b-it", "@cf/moonshotai/kimi-k2.6", "@cf/openai/gpt-oss-120b", "@cf/qwen/qwen3-30b-a3b-fp8"]
        case .glm:
            return ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo"]
        case .qwen:
            return ["qwen3.7-plus", "qwen3.7-max", "qwen3.6-flash"]
        case .openAICompatible, .anthropicCompatible:
            return []
        }
    }

    nonisolated var needsAPIKey: Bool { self != .ollama }
}

struct TranslationLLMConfiguration: Sendable {
    var provider: TranslationProvider
    var endpoint: String
    var model: String
    var apiKey: String
    var apiSecret: String
    var accountID: String
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
    @Published var apiSecret: String = ""
    @Published var accountID: String = ""

    private let defaults = UserDefaults.standard
    private var isLoading = false

    private enum Keys {
        static let provider = "translation.provider"
        static func endpoint(_ provider: TranslationProvider) -> String { "translation.\(provider.rawValue).endpoint" }
        static func model(_ provider: TranslationProvider) -> String { "translation.\(provider.rawValue).model" }
        static let cloudflareAccountID = "translation.cloudflare.accountID"
    }

    private init() {
        let storedProvider = defaults.string(forKey: Keys.provider) ?? ""
        provider = storedProvider == "doubao"
            ? .plamo
            : TranslationProvider(rawValue: storedProvider) ?? .ollama
        if storedProvider == "doubao" {
            defaults.set(provider.rawValue, forKey: Keys.provider)
        }
        loadProviderFields()
    }

    func save() {
        guard !isLoading else { return }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.allowsCustomEndpoint {
            defaults.set(trimmedEndpoint, forKey: Keys.endpoint(provider))
        }
        defaults.set(trimmedModel, forKey: Keys.model(provider))
        TranslationKeychain.save(apiKey, account: provider.rawValue)
        if provider == .modal {
            TranslationKeychain.save(apiSecret, account: "\(provider.rawValue).secret")
        }
        if provider == .cloudflare {
            defaults.set(accountID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cloudflareAccountID)
        }
    }

    var configuration: TranslationLLMConfiguration {
        TranslationLLMConfiguration(
            provider: provider,
            endpoint: resolvedEndpoint,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            apiSecret: apiSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var resolvedEndpoint: String {
        if provider == .cloudflare {
            return provider.defaultEndpoint.replacingOccurrences(
                of: "{account_id}",
                with: accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return provider.allowsCustomEndpoint
            ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            : provider.defaultEndpoint
    }

    private func loadProviderFields() {
        isLoading = true
        endpoint = provider.allowsCustomEndpoint
            ? defaults.string(forKey: Keys.endpoint(provider)) ?? provider.defaultEndpoint
            : provider.defaultEndpoint
        model = defaults.string(forKey: Keys.model(provider)) ?? provider.defaultModel
        apiKey = TranslationKeychain.load(account: provider.rawValue) ?? ""
        apiSecret = provider == .modal
            ? TranslationKeychain.load(account: "\(provider.rawValue).secret") ?? ""
            : ""
        accountID = provider == .cloudflare
            ? defaults.string(forKey: Keys.cloudflareAccountID) ?? ""
            : ""
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
