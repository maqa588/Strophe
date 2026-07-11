//
//  SettingsDetailView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/22.
//

import SwiftUI

struct SettingsDetailView: View {
    let route: SettingsRoute

    var body: some View {
        Group {
            switch route {
            case .version:
                VersionDetailView()
            case .cache:
                CacheSettingView()
            case .whisperConfig:
                ModelConfigView(type: .whisper)
            case .alignerConfig:
                ModelConfigView(type: .aligner)
            case .vadConfig:
                ModelConfigView(type: .vad)
            }
        }
    }
}
