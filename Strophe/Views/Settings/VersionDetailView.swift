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

                LabeledContent("license") {
                    Text("license_fsl")
                        .foregroundStyle(Color.stropheText)
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
        .navigationTitle("关于 \(AppIdentity.displayName)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
