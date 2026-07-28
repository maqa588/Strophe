//
//  SettingsDetailView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/22.
//

import SwiftUI

struct SettingsDetailView: View {
    let route: SettingsRoute
    @ObservedObject var project: SubtitleProject

    var body: some View {
        Group {
            switch route {
            case .version:
                VersionDetailView()
            case .currentMediaInfo:
                CurrentMediaInfoView(project: project)
            case .cache:
                CacheSettingView()
            case .projectRecovery:
                ProjectRecoveryView(project: project)
            case .whisperConfig:
                ModelConfigView(type: .whisper)
            case .alignerConfig:
                ModelConfigView(type: .aligner)
            case .vadConfig:
                ModelConfigView(type: .vad)
            case .translationConfig:
                TranslationConfigView()
            }
        }
    }
}
