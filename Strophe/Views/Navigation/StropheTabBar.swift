//
//  StropheTabBar.swift
//  Strophe
//
//  符合 Apple Liquid Glass 规范的自绘导航栏
//  - 外层容器采用统一的玻璃外壳 (Unified Glass Shell)
//  - 内层通过 matchedGeometryEffect 实现精致的非玻璃滑块滑动效果
//

import SwiftUI

struct StropheTabBar: View {
    @Binding var selectedTab: StropheTab
    var tabs: [StropheTab] = StropheTab.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.stropheAccent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    // 💡 按钮内部仅做上下留白，没有任何外框和背景，自然融入侧边栏底色中
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}