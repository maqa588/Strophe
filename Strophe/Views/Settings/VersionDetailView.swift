//
//  VersionDetailView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/22.
//

import SwiftUI

struct VersionDetailView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)

                    VStack(spacing: 6) {
                        Text(AppIdentity.displayName)
                            .font(.system(.title2, design: .rounded))
                            .bold()
                            .foregroundStyle(Color.stropheText)

                        Text("smart_audiovideo_subtitle_sync_tool")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("version") {
                    Text("v\(appVersion) (\(buildNumber))")
                        .bold()
                        .foregroundStyle(Color.stropheText)
                }

                LabeledContent("technical_architecture") {
                    Text("engine_swiftui_avfoundation")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.stropheText)
                }

                NavigationLink {
                    LicensesListView()
                } label: {
                    LabeledContent("license") {
                        Text("click_to_view")
                            .foregroundStyle(Color.stropheText)
                    }
                }
                
                Link(destination: URL(string: "https://github.com/maqa588/Strophe")!) {
                    HStack {
                        Text("GitHub")
                            .foregroundStyle(Color.stropheText)
                        
                        Spacer()
                        
                        Text("maqa588/Strophe")
                            .foregroundStyle(.blue)
                            .underline()
                    }
                }
            }

            Section(footer:
                VStack(alignment: .leading, spacing: 16) {
                    Text("strophe_is_committed_to_providing")
                        .font(.footnote)
                        .lineSpacing(4)

                    Text("copyright_text")
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .foregroundStyle(.secondary)
            ) {
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .background(Color.stropheBackground)
        .navigationTitle("about_app_format \(AppIdentity.displayName)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct LicensesListView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    LicenseDocumentView(title: String(localized: "eula_label"), text: String(localized: "eula_body"))
                } label: {
                    LabeledContent("Strophe", value: String(localized: "eula_label"))
                }
                
                NavigationLink {
                    LicenseDocumentView(title: String(localized: "cloud_agreement_label"), text: String(localized: "cloud_agreement_body"))
                } label: {
                    LabeledContent("Strophe", value: String(localized: "cloud_agreement_label"))
                }
                
                NavigationLink {
                    LicenseDocumentView(title: "Strophe License (FSL 1.1)", text: LicenseTexts.fsl)
                } label: {
                    LabeledContent("Strophe", value: "FSL 1.1")
                }
                
                NavigationLink {
                    LicenseDocumentView(title: "FFmpeg (LGPL v2.1+)", text: LicenseTexts.ffmpeg)
                } label: {
                    LabeledContent("FFmpeg", value: "LGPL v2.1+")
                }
                
                NavigationLink {
                    LicenseDocumentView(title: "Qwen3-ASR (Apache 2.0)", text: LicenseTexts.apache)
                } label: {
                    LabeledContent("Qwen3-ASR", value: "Apache 2.0")
                }
                
                NavigationLink {
                    LicenseDocumentView(title: "Qwen3-ForcedAligner (Apache 2.0)", text: LicenseTexts.apache)
                } label: {
                    LabeledContent("Qwen3-ForcedAligner", value: "Apache 2.0")
                }
                
                NavigationLink {
                    LicenseDocumentView(title: "FireRedVAD (Apache 2.0)", text: LicenseTexts.apache)
                } label: {
                    LabeledContent("FireRedVAD", value: "Apache 2.0")
                }
                
                NavigationLink {
                    LicenseDocumentView(title: String(localized: "trademarks_label"), text: String(localized: "trademark_disclaimer"))
                } label: {
                    LabeledContent("trademarks_label") {
                        Text("disclaimer_label")
                            .foregroundStyle(Color.stropheText)
                    }
                }
            }
        }
        .background(Color.stropheBackground)
        .navigationTitle("license")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct LicenseDocumentView: View {
    let title: String
    let text: String
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .background(Color.stropheBackground)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
