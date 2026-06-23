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
            Section(header: Text("关于")) {
                Button {
                    settingsPath.append(.version)
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

            #if !STROPHE_LITE
            Section(header: Text("AI 引擎与模型管理")) {
                Button {
                    settingsPath.append(.whisperConfig)
                } label: {
                    Label {
                        Text("语音转写设置")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }

                Button {
                    settingsPath.append(.alignerConfig)
                } label: {
                    Label {
                        Text("强制对齐设置")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "timeline.selection")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
                
                Button {
                    settingsPath.append(.speakerConfig)
                } label: {
                    Label {
                        Text("对话人识别设置")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "person.2.wave.2")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
                
                Button {
                    settingsPath.append(.ttsConfig)
                } label: {
                    Label {
                        Text("文本转语音设置")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }

                Button {
                    settingsPath.append(.otherConfig)
                } label: {
                    Label {
                        Text("智能降噪与辅助设置")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
            }
            #endif

            Section(header: Text("存储与维护")) {
                Button {
                    settingsPath.append(.cache)
                } label: {
                    Label {
                        Text("清理缓存")
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
}
