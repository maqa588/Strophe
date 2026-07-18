//
//  TranslationConfigView.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/18.
//

import SwiftUI

struct TranslationConfigView: View {
    @ObservedObject var settings = TranslationSettingsStore.shared
    
    @State private var modelSelection: String
    @State private var customModel: String
    @State private var isCustomModelSelected: Bool

    init() {
        let store = TranslationSettingsStore.shared
        let initialModel = store.model
        let provider = store.provider
        
        if provider.modelOptions.contains(initialModel) {
            _modelSelection = State(initialValue: initialModel)
            _isCustomModelSelected = State(initialValue: false)
        } else if !provider.modelOptions.isEmpty {
            _modelSelection = State(initialValue: "custom")
            _isCustomModelSelected = State(initialValue: true)
        } else {
            _modelSelection = State(initialValue: "custom")
            _isCustomModelSelected = State(initialValue: false)
        }
        _customModel = State(initialValue: initialModel)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 75, maximum: 90), spacing: 8)
    ]

    var body: some View {
        Form {
            Section(header: Text("provider_presets")) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Button {
                            settings.save()
                            settings.provider = provider
                            initializeSelection()
                        } label: {
                            VStack(spacing: 6) {
                                if let logo = provider.logoName {
                                    Image(logo)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 38, height: 38)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .shadow(color: Color.black.opacity(0.1), radius: 1.5, x: 0, y: 1)
                                } else {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 16))
                                        .frame(width: 38, height: 38)
                                        .background(Color.stropheSecondaryBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                
                                Text(provider.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(settings.provider == provider ? Color.stropheText : .secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.provider == provider ? Color.stropheAccent.opacity(0.12) : Color.stropheSecondaryBackground.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(settings.provider == provider ? Color.stropheAccent : Color.stropheBorder.opacity(0.3), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            
            Section(header: Text("provider_settings")) {
                HStack(spacing: 12) {
                    if let logo = settings.provider.logoName {
                        Image(logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                    }
                    Text(settings.provider.title)
                        .font(.headline)
                }
                .padding(.vertical, 2)
                
                if settings.provider.allowsCustomEndpoint {
                    TextField("server_address", text: $settings.endpoint)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                        .stropheOnChange(of: settings.endpoint) { _ in
                            settings.save()
                        }
                } else {
                    LabeledContent("server_address") {
                        Text(settings.provider.defaultEndpoint)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if settings.provider == .cloudflare {
                    TextField("Cloudflare Account ID", text: $settings.accountID)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .stropheOnChange(of: settings.accountID) { _ in
                            settings.save()
                        }
                }
                
                if !settings.provider.modelOptions.isEmpty {
                    Picker("model", selection: $modelSelection) {
                        ForEach(settings.provider.modelOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                        Text("custom_model").tag("custom")
                    }
                    .stropheOnChange(of: modelSelection) { newSelection in
                        if newSelection == "custom" {
                            isCustomModelSelected = true
                            settings.model = customModel
                        } else {
                            isCustomModelSelected = false
                            settings.model = newSelection
                        }
                        settings.save()
                    }
                    
                    if isCustomModelSelected {
                        TextField("custom_model_name", text: $customModel)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .stropheOnChange(of: customModel) { newCustom in
                                if modelSelection == "custom" {
                                    settings.model = newCustom
                                    settings.save()
                                }
                            }
                    }
                } else {
                    TextField("custom_model_name", text: $settings.model)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .stropheOnChange(of: settings.model) { _ in
                            settings.save()
                        }
                }
                
                if settings.provider == .modal {
                    SecureField("Modal-Key", text: $settings.apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .stropheOnChange(of: settings.apiKey) { _ in
                            settings.save()
                        }
                    SecureField("Modal-Secret", text: $settings.apiSecret)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .stropheOnChange(of: settings.apiSecret) { _ in
                            settings.save()
                        }
                } else if settings.provider.needsAPIKey {
                    SecureField("api_key_keychain", text: $settings.apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .stropheOnChange(of: settings.apiKey) { _ in
                            settings.save()
                        }
                } else {
                    Text("ollama_connection_info")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .background(Color.stropheBackground)
        .navigationTitle("machine_translation_settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            initializeSelection()
        }
        .onDisappear {
            settings.save()
        }
    }
    
    private func initializeSelection() {
        if settings.provider.modelOptions.contains(settings.model) {
            modelSelection = settings.model
            isCustomModelSelected = false
        } else if !settings.provider.modelOptions.isEmpty {
            modelSelection = "custom"
            isCustomModelSelected = true
            customModel = settings.model
        } else {
            modelSelection = "custom"
            isCustomModelSelected = false
            customModel = settings.model
        }
    }
}
