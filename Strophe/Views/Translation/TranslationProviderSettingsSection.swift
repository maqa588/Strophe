import SwiftUI

struct TranslationProviderSettingsSection: View {
    @ObservedObject var settings = TranslationSettingsStore.shared

    var body: some View {
        Section("机器翻译服务") {
            Picker("接口模式", selection: $settings.provider) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            TextField("服务地址", text: $settings.endpoint)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
            TextField("模型", text: $settings.model)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            if settings.provider.needsAPIKey {
                SecureField("API 密钥（保存到系统钥匙串）", text: $settings.apiKey)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            } else {
                Text("Ollama 默认连接本机服务，不需要 API 密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
