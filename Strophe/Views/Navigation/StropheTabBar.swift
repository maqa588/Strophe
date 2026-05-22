//
//  StropheTabBar.swift
//  Strophe
//
//  基于 Apple 官方规范的 iOS 26+ / macOS 26+ 原生 Liquid Glass 导航栏 (优化重构版)
//  - 外部采用 GlassEffectContainer 统一容器，支持多个玻璃形状的自动流体融合
//  - 使用 .glassEffect(.regular) 渲染系统级真实折射与反射毛玻璃
//  - 使用 .glassEffect(.regular.interactive()) 让选中的滑块在触下时呈现水滴波动反馈
//  - 通过内置拖拽手势 (DragGesture) 支持 0 延迟连续滑动切换
//
//  性能与平台自适应优化 (HIG 规范)：
//  - 去除内部 GeometryReader，使用 background 异步获取宽度，防止布局吞噬
//  - 添加 VoiceOver 支持，使用 tab.title 作为无障碍标签 (accessibilityLabel)
//  - 桌面端/大屏 (Mac/iPad) 自动限制最大宽度并调整边距，呈现悬浮中控台样式
//  - 交互式弹簧动画曲线优化，强化水滴流体感
//

import SwiftUI

struct StropheTabBar: View {
    @Binding var selectedTab: StropheTab
    var tabs: [StropheTab] = StropheTab.allCases

    @Namespace private var tabIndicatorAnimation
    @State private var activeIndex: Int = 0
    @State private var containerWidth: CGFloat = 0 // 动态捕获宽度用于拖拽

    // 平台检测：适配 iPadOS / macOS 的不同交互直觉
    #if os(macOS) || os(visionOS)
    let isDesktop = true
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var isDesktop: Bool { horizontalSizeClass == .regular }
    #endif

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            advancedLiquidGlassTabBar
        } else {
            ordinaryTabBar
        }
    }

    // ==========================================
    // 1. 🌟 Apple 原生 Liquid Glass 导航栏 (WWDC25)
    // ==========================================
    @available(iOS 26.0, macOS 26.0, *)
    private var advancedLiquidGlassTabBar: some View {
        // 使用 GlassEffectContainer 联合渲染
        // spacing: 12 是控制融合阈值（水滴吸附距离）的最佳实践
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    liquidGlassTabButton(for: tab, index: index)
                }
            }
            // 使用 background GeometryReader 仅无感获取宽度，不破坏整体布局
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { containerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in containerWidth = newWidth }
                }
            )
            .padding(4)
            // 外层：系统级常规毛玻璃
            .glassEffect(.regular, in: .capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleDrag(value) }
                    .onEnded { value in commitDrag(value) }
            )
        }
        // 桌面端约束最大宽度并调整位置，避免像 iOS 一样横跨整个大屏幕
        .frame(maxWidth: isDesktop ? 400 : .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, isDesktop ? 24 : 12) 
        .onAppear {
            activeIndex = tabs.firstIndex(of: selectedTab) ?? 0
        }
        .onChange(of: selectedTab) { _, newTab in
            if let idx = tabs.firstIndex(of: newTab) {
                // 使用带有阻尼的交互式弹簧，强化液体流动感
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.65)) {
                    activeIndex = idx
                }
            }
        }
    }

    // ==========================================
    // 2. 🌟 内部流体滑块组件
    // ==========================================
    @available(iOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private func liquidGlassTabButton(for tab: StropheTab, index: Int) -> some View {
        let isActive = (activeIndex == index)

        VStack(spacing: 0) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                // 🍎 规范强制要求：必须添加无障碍标签，确保屏幕朗读可用
                .accessibilityLabel(tab.title)
        }
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background {
            if isActive {
                Capsule()
                    .fill(Color.stropheAccent) // 采用 App 强调色
                    // 核心交互层：附加 interactive() 后，按下会有水滴波纹反馈
                    .glassEffect(.regular.interactive(), in: .capsule)
                    // MatchedGeometryEffect 负责位置转移，外层的 Container 自动计算路径上的流体融合形变
                    .matchedGeometryEffect(id: "activeTabIndicator", in: tabIndicatorAnimation)
                    .padding(.horizontal, 4)
            }
        }
        // 增加点击热区
        .contentShape(Rectangle()) 
        .onTapGesture {
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.6)) {
                activeIndex = index
                selectedTab = tab
            }
        }
    }

    // ==========================================
    // 3. 🛠️ 性能优化的拖拽手势逻辑
    // ==========================================
    private func handleDrag(_ value: DragGesture.Value) {
        guard containerWidth > 0 else { return }
        let tabWidth = containerWidth / CGFloat(tabs.count)
        let locationX = value.location.x
        let index = Int(locationX / tabWidth)
        let clampedIndex = max(0, min(tabs.count - 1, index))

        guard activeIndex != clampedIndex else { return }

        // 仅拖拽期间驱动 UI 层的 activeIndex 变化，避免高频触发全局 Binding 导致整个 App 重绘
        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.7)) {
            activeIndex = clampedIndex
        }
    }

    private func commitDrag(_ value: DragGesture.Value) {
        let targetTab = tabs[activeIndex]
        if selectedTab != targetTab {
            selectedTab = targetTab
        }
    }

    // ==========================================
    // 4. 🌟 较低系统版本的普通按钮导航栏
    // ==========================================
    private var ordinaryTabBar: some View {
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
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
