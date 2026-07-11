import SwiftUI

struct TranslationProviderSettingsSection: View {
    @ObservedObject var settings = TranslationSettingsStore.shared

    var body: some View {
        Section("machine_translation_service") {
            Picker("api_mode", selection: $settings.provider) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            TextField("server_address", text: $settings.endpoint)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
            TextField("model", text: $settings.model)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            if settings.provider.needsAPIKey {
                SecureField("api_key_keychain", text: $settings.apiKey)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            } else {
                Text("ollama_connection_info")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
