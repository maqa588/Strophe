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
                        Text("关于 Strophe")
                            .foregroundStyle(Color.stropheText)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
            }

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
    }
}
