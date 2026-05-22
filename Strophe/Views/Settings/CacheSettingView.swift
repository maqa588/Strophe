//
//  CacheSettingView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/22.
//

import SwiftUI

struct CacheSettingView: View {
    @State private var cacheSizeInBytes: Int64 = 0
    @State private var isClearing = false
    @State private var showSuccessAlert = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.stropheSecondaryBackground)
                            .frame(width: 80, height: 80)

                        Image(systemName: "sdcard.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.stropheAccent)
                    }

                    VStack(spacing: 6) {
                        Text("临时占用空间")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(TempCleanupHelper.formatBytes(cacheSizeInBytes))
                            .font(.system(.title, design: .rounded))
                            .bold()
                            .foregroundStyle(Color.stropheText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("什么是缓存数据？", systemImage: "questionmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Text("Strophe 在导入视频 or 音频文件时，会生成临时音频转码文件与波形分析缓存。这些数据可以显著加速波形的渲染和音视频的高速跳转，但在使用完毕后，它们会占用您的设备存储空间。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("提示：清理缓存是完全安全的，它绝不会删除您的字幕文稿项目、已保存的工程文件或原始音视频源文件。")
            }

            Section {
                Button(role: .destructive) {
                    clearCache()
                } label: {
                    HStack {
                        Spacer()
                        if isClearing {
                            ProgressView()
                                .padding(.trailing, 6)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isClearing ? "正在清理中..." : "立即清理缓存")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(cacheSizeInBytes == 0 || isClearing)
            }
        }
        .formStyle(.grouped)
        .background(Color.stropheBackground)
        .onAppear {
            refreshCacheSize()
        }
        .navigationTitle("清理缓存")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("清理完成", isPresented: $showSuccessAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("所有的临时转码数据和波形缓存文件已被安全清除。")
        }
    }

    private func refreshCacheSize() {
        cacheSizeInBytes = TempCleanupHelper.getTempDirectorySize()
    }

    private func clearCache() {
        guard cacheSizeInBytes > 0 else { return }
        isClearing = true

        Task {
            TempCleanupHelper.cleanupTempDirectory()

            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif

            refreshCacheSize()
            isClearing = false
            showSuccessAlert = true
        }
    }
}
