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
            }
        }
    }
}
