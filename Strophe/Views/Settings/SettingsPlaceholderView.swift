//
//  SettingsPlaceholderView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/22.
//

import SwiftUI

struct SettingsPlaceholderView: View {
    @Binding var settingsPath: [SettingsRoute]

    init(settingsPath: Binding<[SettingsRoute]> = .constant([])) {
        self._settingsPath = settingsPath
    }

    var body: some View {
        List {
            Section(header: Text("about")) {
                Button {
                    open(.version)
                } label: {
                    Label {
                        Text("关于 \(AppIdentity.displayName)")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
            }

            Section(header: Text("ai_engine_model_management")) {
                Button {
                    open(.whisperConfig)
                } label: {
                    Label {
                        Text("speech_transcription_settings")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
                Button {
                    open(.alignerConfig)
                } label: {
                    Label {
                        Text("forced_alignment_settings")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "timeline.selection")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
                Button {
                    open(.vadConfig)
                } label: {
                    Label {
                        Text("voice_activity_detection_settings")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "waveform.circle")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
            }

            Section(header: Text("storage_maintenance")) {
                Button {
                    open(.cache)
                } label: {
                    Label {
                        Text("clear_cache")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "trash.fill")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.automatic)
        #endif
        .venturaFixedListRowHeight(36)
    }

    private func open(_ route: SettingsRoute) {
        settingsPath = [route]
    }
}
