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
                        Text("Strophe")
                            .font(.system(.title2, design: .rounded))
                            .bold()
                            .foregroundStyle(Color.stropheText)

                        Text("智能音视频字幕同步工具")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("版本") {
                    Text("v\(appVersion) (\(buildNumber))")
                        .bold()
                        .foregroundStyle(Color.stropheText)
                }

                LabeledContent("技术架构") {
                    Text("SwiftUI / AVFoundation")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.stropheText)
                }

                LabeledContent("许可证") {
                    Text("Functional Source License")
                        .foregroundStyle(Color.stropheText)
                }
            }

            Section(footer:
                VStack(alignment: .leading, spacing: 16) {
                    Text("Strophe 致力于为视频创作者提供最流畅、最高效的打轴与字幕导入/导出流程。通过极其贴合创作者习惯的快捷键操作与精细的音频波形显示，我们正在重新定义字幕制作体验。")
                        .font(.footnote)
                        .lineSpacing(4)

                    Text("© 2026 Strophe. All rights reserved.")
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
        .navigationTitle("关于 Strophe")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
