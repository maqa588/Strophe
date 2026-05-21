//
//  SettingsPlaceholderView.swift
//  Strophe
//

import SwiftUI

struct SettingsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("设置", systemImage: "gear")
        } description: {
            Text("功能开发中，敬请期待。")
        }
        .navigationTitle("设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack {
        SettingsPlaceholderView()
    }
}
