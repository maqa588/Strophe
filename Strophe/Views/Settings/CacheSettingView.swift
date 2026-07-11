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
                        Text("temporary_space_occupied")
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
                    Label("what_is_cached_data", systemImage: "questionmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Text("when_importing_video_or_audio")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("note_clearing_cache_is_completely")
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
                        Text(isClearing ? "cleaning_up" : "clear_cache_now")
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
        .navigationTitle("clear_cache")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("cleanup_completed", isPresented: $showSuccessAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("all_temporary_transcoding_data_and")
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
